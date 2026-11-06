import Testing
import Foundation
import InspectorModel
@testable import InspectorPlatform

@Suite struct PlatformTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func runnerCapturesOutput() async throws {
        let r = try await ProcessRunner.run("/bin/echo", ["hello"])
        #expect(r.status == 0)
        #expect(r.stdoutString == "hello\n")
        #expect(!r.timedOut)
    }

    @Test func runnerRejectsRelativePath() async {
        await #expect(throws: ProcessRunnerError.self) { try await ProcessRunner.run("echo", ["x"]) }
    }

    @Test func runnerTimesOut() async throws {
        let r = try await ProcessRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(200))
        #expect(r.timedOut)
    }

    @Test func runnerCapsOutput() async throws {
        let r = try await ProcessRunner.run("/usr/bin/yes", [], timeout: .milliseconds(300), maxBytes: 1000)
        #expect(r.truncated)
        #expect(r.stdout.count <= 1000)
    }

    @Test func sqliteReadOnlyAndSchema() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let db = d.appendingPathComponent("t.db").path
        let r = try await ProcessRunner.run("/usr/bin/sqlite3", [db,
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER, csreq BLOB, last_modified INTEGER);" +
            "INSERT INTO access VALUES ('kTCCServiceCamera','com.x',0,2,3,X'0102',1700000000);"])
        #expect(r.status == 0)
        let t = try SQLiteReader.readTable(at: db, table: "access")
        #expect(t.columns.contains("auth_value"))
        #expect(t.rows.count == 1)
        #expect(t.rows[0]["csreq"]?.blobValue == Data([1, 2]))
        #expect(t.rows[0]["service"]?.textValue == "kTCCServiceCamera")
    }

    @Test func sqliteMissingFileFailsOpen() {
        #expect(throws: SQLiteReadError.self) {
            try SQLiteReader.readTable(at: "/nonexistent/dir/x.db", table: "access")
        }
    }

    @Test func accessProbe() throws {
        #expect(AccessProbe.fullDiskAccess(probePath: "/nonexistent/x") != .granted)
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("f"); try Data("x".utf8).write(to: f)
        #expect(AccessProbe.fullDiskAccess(probePath: f.path) == .granted)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path)
        #expect(AccessProbe.fullDiskAccess(probePath: f.path) == .notGranted)
    }

    @Test func bundleReaderParsesUsageKeys() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let app = d.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.x.foo", "CFBundleName": "Foo",
                                    "CFBundleShortVersionString": "1.2", "NSCameraUsageDescription": "scan",
                                    "SomethingElse": "no"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let info = try #require(BundleReader.read(app))
        #expect(info.bundleID == "com.x.foo")
        #expect(info.usageDescriptions == ["NSCameraUsageDescription": "scan"])
        #expect(BundleReader.read(d) == nil)
    }

    @Test func signingClassification() {
        // Calculator ships with macOS on every supported version.
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(CodeSigning.summary(of: calc).kind == .apple)
        let unsigned = URL(fileURLWithPath: "/nonexistent.app")
        if case .unknown = CodeSigning.summary(of: unsigned).kind {} else { Issue.record("expected .unknown") }
    }

    @Test func settingsLinks() {
        let urls = SystemSettingsLinker.privacyURLs(anchor: "Privacy_Camera")
        #expect(urls.count == 2)
        #expect(urls[0].absoluteString.hasSuffix("?Privacy_Camera"))
        #expect(SystemSettingsLinker.privacyURLs(anchor: nil).count == 1)
    }

    @Test func osInfoLooksSane() {
        let i = SystemInfo.current()
        #expect(i.version.major >= 15)
        #expect(!i.build.isEmpty && i.build != "unknown")
    }
}
