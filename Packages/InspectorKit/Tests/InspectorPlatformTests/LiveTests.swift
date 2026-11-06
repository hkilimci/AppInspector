import Testing
import Foundation
@testable import InspectorPlatform

@Suite struct LiveTests {
    @Test func signingCacheHitsOnSecondLookupAndMissesOnChange() throws {
        let cache = SigningCache()
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let a = cache.summary(of: calc), b = cache.summary(of: calc)
        #expect(a == b && cache.misses == 1 && cache.hits == 1)

        // A changed fingerprint file invalidates the entry.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)/Foo.app/Contents")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().deletingLastPathComponent()) }
        let plist = tmp.appendingPathComponent("Info.plist")
        try Data("a".utf8).write(to: plist)
        let app = tmp.deletingLastPathComponent()
        _ = cache.summary(of: app); _ = cache.summary(of: app)
        #expect(cache.misses == 2 && cache.hits == 2)
        try Data("changed".utf8).write(to: plist)
        _ = cache.summary(of: app)
        #expect(cache.misses == 3)
    }

    /// An executable-only update can leave CodeResources and Info.plist untouched.
    @Test func executableOnlyChangeInvalidatesTheCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sx-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try (["CFBundleExecutable": "Foo", "CFBundleIdentifier": "x.foo"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        try Data("seal".utf8).write(to: app.appendingPathComponent("_CodeSignature/CodeResources"))
        let exe = app.appendingPathComponent("MacOS/Foo")
        try Data("v1".utf8).write(to: exe)
        let bundle = app.deletingLastPathComponent()

        let cache = SigningCache()
        _ = cache.summary(of: bundle); _ = cache.summary(of: bundle)
        #expect(cache.misses == 1 && cache.hits == 1)
        try Data("v2 longer".utf8).write(to: exe)                    // only the executable changes
        _ = cache.summary(of: bundle)
        #expect(cache.misses == 2, "executable change must be a cache miss")
    }

    @Test func debouncerRunsOnlyTheLastTrigger() async throws {
        let d = Debouncer(interval: .milliseconds(150))
        let box = Counter()
        for _ in 0..<5 { d.trigger { box.bump() }; try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(box.value == 1)
        d.trigger { box.bump() }; d.cancel()
        try await Task.sleep(for: .milliseconds(400))
        #expect(box.value == 1)
    }

    @Test func fileSystemWatcherReportsChangesAndSkipsMissingFolders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fsw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = FileSystemWatcher(paths: [dir.path, "/definitely/not/here"], latency: 0.1)
        #expect(w.watchedPaths == [dir.path])

        let got = await withTaskGroup(of: Bool.self) { g in
            g.addTask { for await _ in w.events { return true }; return false }
            g.addTask {
                try? await Task.sleep(for: .milliseconds(600))
                try? Data("x".utf8).write(to: dir.appendingPathComponent("new.plist"))
                try? await Task.sleep(for: .seconds(6))
                return false
            }
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        w.stop()
        #expect(got)
    }

    @Test func watcherWithNoExistingPathsIsInert() {
        let w = FileSystemWatcher(paths: ["/definitely/not/here"])
        #expect(w.watchedPaths.isEmpty)
        w.stop()
    }

    @Test func standardWatchedPathsExcludeTCC() {
        let p = WatchedPaths.standard(home: "/Users/x")
        #expect(p.contains("/Library/LaunchAgents") && p.contains("/Users/x/Library/LaunchAgents"))
        #expect(!p.contains { $0.contains("TCC") })
    }

    @Test func bootTimeIsInThePast() {
        let b = SystemInfo.bootTime()
        #expect(b != nil && b! < Date())
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
