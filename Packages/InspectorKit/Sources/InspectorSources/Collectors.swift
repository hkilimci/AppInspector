import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform

// MARK: - App inventory

public struct InventoryEntry: Sendable {
    public var app: AppRecord
    public let usage: [String: String]
}

public struct AppInventoryCollector: Sendable {
    public var roots: [URL]
    /// Shared across rescans: unchanged apps are not re-verified.
    public let signing: SigningCache
    public init(roots: [URL]? = nil, signing: SigningCache = SigningCache()) {
        self.signing = signing
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Finds `.app` bundles up to `maxDepth` folders deep (e.g. /Applications/Utilities/X.app).
    public func findApps(maxDepth: Int = 2) -> [URL] {
        var found: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard !Task.isCancelled, let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for u in items {
                guard !Task.isCancelled else { return }
                if u.pathExtension == "app" { found.append(u) }
                else if depth < maxDepth, (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walk(u, depth: depth + 1)
                }
            }
        }
        for r in roots { walk(r, depth: 0) }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }

    public func collect() async -> (entries: [InventoryEntry], status: SourceStatus) {
        let start = Date()
        let urls = findApps()
        let gathered: [InventoryEntry] = await withTaskGroup(of: InventoryEntry?.self) { group in
            for u in urls {
                guard !Task.isCancelled else { break }
                let cache = self.signing
                group.addTask {
                    guard !Task.isCancelled, let info = BundleReader.read(u) else { return nil }
                    let signing = cache.summary(of: u)
                    guard !Task.isCancelled else { return nil }
                    let rec = AppRecord(path: u.path, name: info.name, bundleID: info.bundleID,
                                        version: info.version, build: info.build, signing: signing)
                    return InventoryEntry(app: rec, usage: info.usageDescriptions)
                }
            }
            var out: [InventoryEntry] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }
        let entries = gathered.sorted { (a: InventoryEntry, b: InventoryEntry) in
            a.app.name.localizedCaseInsensitiveCompare(b.app.name) == .orderedAscending
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return (entries, SourceStatus(id: .appInventory, state: .ok, itemCount: entries.count, durationMs: ms))
    }
}

// MARK: - TCC

public enum DBOutcome: Sendable {
    case read(TCCParseResult)
    case unavailable(UnknownReason, SourceStatus.State)

    public var rows: [TCCRow]? { if case .read(let r) = self { r.rows } else { nil } }
}

public struct TCCCollectorOutput: Sendable {
    public let user: DBOutcome
    public let system: DBOutcome
    public let statuses: [SourceStatus]
    public init(user: DBOutcome, system: DBOutcome, statuses: [SourceStatus]) {
        self.user = user; self.system = system; self.statuses = statuses
    }
}

public struct TCCCollector: Sendable {
    public typealias TableReader = @Sendable (_ path: String) throws -> TCCTable
    public var userPath: String
    public var systemPath: String
    public var reader: TableReader

    public init(userPath: String = AccessProbe.userTCCPath(),
                systemPath: String = AccessProbe.systemTCCPath,
                reader: @escaping TableReader = { try SQLiteReader.readTable(at: $0, table: "access") }) {
        self.userPath = userPath; self.systemPath = systemPath; self.reader = reader
    }

    public func collect(fda: AccessLevel) async -> TCCCollectorOutput {
        let u = read(.tccUser, path: userPath, fda: fda)
        let s = read(.tccSystem, path: systemPath, fda: fda)
        return TCCCollectorOutput(user: u.0, system: s.0, statuses: [u.1, s.1])
    }

    private func read(_ id: SourceID, path: String, fda: AccessLevel) -> (DBOutcome, SourceStatus) {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        if Task.isCancelled {
            return (.unavailable(.timedOut(id), .timedOut),
                    SourceStatus(id: id, state: .timedOut, itemCount: 0, durationMs: ms()))
        }
        if fda == .notGranted {
            return (.unavailable(.needsFullDiskAccess, .needsFullDiskAccess),
                    SourceStatus(id: id, state: .needsFullDiskAccess, itemCount: 0, durationMs: ms()))
        }
        do {
            let table = try reader(path)
            try Task.checkCancellation()
            let parsed = try TCCParser.parse(table)
            let note = "schema \(parsed.schemaFingerprint)" + (parsed.skippedRows > 0 ? ", \(parsed.skippedRows) rows skipped" : "")
            // Rows we could not parse mean the table was only partly read: surface it in Diagnostics.
            let state: SourceStatus.State = parsed.skippedRows > 0 ? .formatUnrecognized("\(parsed.skippedRows) unreadable rows") : .ok
            return (.read(parsed), SourceStatus(id: id, state: state, itemCount: parsed.rows.count, durationMs: ms(), note: note))
        } catch is CancellationError {
            return (.unavailable(.timedOut(id), .timedOut),
                    SourceStatus(id: id, state: .timedOut, itemCount: 0, durationMs: ms()))
        } catch let e as TCCParseError {
            let why = "\(e)"
            return (.unavailable(.formatUnrecognized(id, why), .formatUnrecognized(why)),
                    SourceStatus(id: id, state: .formatUnrecognized(why), itemCount: 0, durationMs: ms()))
        } catch let e as SQLiteReadError {
            // Open failure without a confirmed FDA grant is most likely FDA; otherwise a real failure.
            if fda != .granted, case .openFailed = e {
                return (.unavailable(.needsFullDiskAccess, .needsFullDiskAccess),
                        SourceStatus(id: id, state: .needsFullDiskAccess, itemCount: 0, durationMs: ms(), note: "\(e)"))
            }
            return (.unavailable(.sourceFailed(id, "\(e)"), .failed("\(e)")),
                    SourceStatus(id: id, state: .failed("\(e)"), itemCount: 0, durationMs: ms()))
        } catch {
            return (.unavailable(.sourceFailed(id, "\(error)"), .failed("\(error)")),
                    SourceStatus(id: id, state: .failed("\(error)"), itemCount: 0, durationMs: ms()))
        }
    }
}
