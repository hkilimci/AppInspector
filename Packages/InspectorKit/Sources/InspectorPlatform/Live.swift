import Foundation
import CoreServices
import Synchronization
import InspectorModel

// MARK: - Signing cache

/// Caches code-signing summaries keyed by (path, inode, mtime, size) of the bundle's signature file, so a
/// rescan only re-evaluates apps that changed. In-memory only: nothing is written to disk.
public final class SigningCache: Sendable {
    struct Stamp: Hashable { let inode: UInt64; let mtimeNs: Int64; let size: Int64 }
    struct Key: Hashable { let path: String; let stamps: [Stamp] }
    private let store = Mutex<[Key: SigningSummary]>([:])
    private let counters = Mutex<(hits: Int, misses: Int)>((0, 0))
    public init() {}

    public var hits: Int { counters.withLock { $0.hits } }
    public var misses: Int { counters.withLock { $0.misses } }

    static func stamp(_ path: String) -> Stamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return Stamp(inode: UInt64(st.st_ino), mtimeNs: ns, size: Int64(st.st_size))
    }

    /// Files whose change can change the signing result: the sealed-resources list, Info.plist AND the main executable.
    /// An executable-only update can leave CodeResources untouched.
    static func fingerprintPaths(_ url: URL) -> [String] {
        var paths = [url.appendingPathComponent("Contents/_CodeSignature/CodeResources").path,
                     url.appendingPathComponent("Contents/Info.plist").path]
        if let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let exe = obj["CFBundleExecutable"] as? String, !exe.contains("/") {
            paths.append(url.appendingPathComponent("Contents/MacOS/\(exe)").path)
        }
        return paths
    }

    static func key(for url: URL) -> Key? {
        var stamps = fingerprintPaths(url).compactMap(stamp)
        if stamps.isEmpty, let s = stamp(url.path) { stamps = [s] }     // a bare executable
        return stamps.isEmpty ? nil : Key(path: url.path, stamps: stamps)
    }

    public func summary(of url: URL) -> SigningSummary {
        guard let key = Self.key(for: url) else { return CodeSigning.summary(of: url) }
        if let hit = store.withLock({ $0[key] }) { counters.withLock { $0.hits += 1 }; return hit }
        let s = CodeSigning.summary(of: url)
        store.withLock { $0[key] = s }
        counters.withLock { $0.misses += 1 }
        return s
    }

    public func teamID(ofPath path: String) -> String? { summary(of: URL(fileURLWithPath: path)).teamID }
}

// MARK: - Debounce

/// Trailing-edge debounce: only the last `trigger` within `interval` runs its action.
public final class Debouncer: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let interval: Duration
    public init(interval: Duration) { self.interval = interval }

    public func trigger(_ action: @escaping @Sendable () async -> Void) {
        let interval = self.interval
        task.withLock { current in
            current?.cancel()
            current = Task {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await action()
            }
        }
    }
    public func cancel() { task.withLock { $0?.cancel(); $0 = nil } }
}

// MARK: - FSEvents

/// Watches folders and yields once per batch of changes. Missing folders are skipped, never created.
public final class FileSystemWatcher: @unchecked Sendable {
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "inspector.fsevents")
    public private(set) var watchedPaths: [String] = []

    private final class Box { let yield: () -> Void; init(_ y: @escaping () -> Void) { yield = y } }
    private var box: Box?

    public init(paths: [String], latency: TimeInterval = 1.0) {
        var cont: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        watchedPaths = existing
        guard !existing.isEmpty else { return }

        let box = Box { [continuation] in continuation.yield() }
        self.box = box
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().yield()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
        continuation.finish()
    }

    deinit { stop() }
}

public enum WatchedPaths {
    /// Folders whose changes can alter the scan (plan §4.4). TCC databases are deliberately absent: they are re-read on refresh.
    public static func standard(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications", "/Library/LaunchAgents", "/Library/LaunchDaemons",
         home + "/Library/LaunchAgents", "/Library/SystemExtensions"]
    }
}
