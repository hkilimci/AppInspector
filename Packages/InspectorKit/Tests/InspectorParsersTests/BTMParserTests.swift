import Testing
import Foundation
@testable import InspectorParsers

enum BTMFixture {
    static var sample: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic/btm-sample.txt")
        return try! String(contentsOf: url, encoding: .utf8)
    }
    static func report(importedAt: Date = Date(), live: Bool = true) throws -> BTMReport {
        try BTMParser.parse(sample, importedAt: importedAt, isLiveRead: live)
    }
}

@Suite struct BTMParserTests {
    @Test func parsesRecordsAndSections() throws {
        let r = try BTMFixture.report()
        #expect(r.records.count == 6)
        #expect(r.skippedItems == 0 && r.isComplete)
        #expect(r.uids == [-2, 501])
        let d = try #require(r.records.first { $0.label == "com.vendor.daemon" })
        #expect(d.uid == -2 && d.kind == .legacyDaemon && d.typeCode == 0x10010)
        #expect(d.label == "com.vendor.daemon" && d.identifier == "16.com.vendor.daemon")
        #expect(d.absolutePath == "/Library/LaunchDaemons/d.plist")
        #expect(d.executablePath == "/Library/PrivilegedHelperTools/com.vendor.daemon")
        #expect(d.assocBundleIDs == ["com.vendor.foo", "com.vendor.bar"])
        #expect(d.teamID == "TEAMFOO111" && d.developerName == "Foo Inc." && d.flags == ["legacy", "curated"])
        #expect(d.disposition == BTMDisposition(enabled: true, allowed: true, notified: true))
    }

    @Test func relativeURLAndParentAndEmbedded() throws {
        let r = try BTMFixture.report()
        let h = try #require(r.records.first { $0.kind == .loginItem })
        #expect(h.url == "Contents/Library/LoginItems/FooHelper.app" && h.absolutePath == nil)
        #expect(h.parentIdentifier == "2.com.vendor.foo" && h.parentLabel == "com.vendor.foo")
        #expect(h.disposition?.enabled == false && h.disposition?.allowed == true)
        #expect(h.teamID == nil && h.developerName == nil)            // "(null)" and absent → nil
        let app = try #require(r.records.first { $0.kind == .app })
        #expect(app.embeddedIdentifiers == ["4.com.vendor.loginhelper"])
        #expect(app.bundleIdentifier == "com.vendor.foo")
        #expect(app.absolutePath == "/Applications/Foo.app")          // trailing slash dropped
    }

    @Test func disallowedIsParsed() throws {
        let b = try #require(try BTMFixture.report().records.first { $0.label == "com.vendor.blocked" })
        #expect(b.disposition == BTMDisposition(enabled: true, allowed: false, notified: true))
    }

    /// An unrecognized disposition token must make the disposition unknown, never a guessed value.
    @Test func unknownDispositionTokenGivesNilDisposition() throws {
        let f = try #require(try BTMFixture.report().records.first { $0.label == "com.vendor.future" })
        #expect(f.disposition == nil)
        #expect(f.kind == .agent)
    }

    @Test(arguments: [
        "[enabled, disabled, allowed, notified]",            // contradictory
        "[enabled, allowed]",                                // missing a half
        "enabled, allowed, notified",                        // no brackets
        "[enabled, allowed, notified",                       // unclosed
        "[]",
    ])
    func malformedDispositionIsNil(text: String) {
        #expect(BTMParser.parseDisposition(text) == nil)
    }

    @Test func itemMissingRequiredFieldIsSkippedAndCounted() throws {
        let text = BTMFixture.sample.replacingOccurrences(of: "           Identifier: 8.com.vendor.agent\n", with: "")
        let r = try BTMParser.parse(text, importedAt: Date(), isLiveRead: true)
        #expect(r.records.count == 5 && r.skippedItems == 1 && !r.isComplete)
        #expect(!r.records.contains { $0.label == "com.vendor.agent" })
    }

    @Test func noHeaderThrows() {
        #expect(throws: ParseError.self) { try BTMParser.parse("hello\nworld", importedAt: Date(), isLiveRead: false) }
        #expect(throws: ParseError.self) { try BTMParser.parse("", importedAt: Date(), isLiveRead: false) }
    }

    @Test func fingerprintTracksFieldNames() throws {
        let a = try BTMFixture.report().fieldFingerprint
        let b = try BTMParser.parse(BTMFixture.sample.replacingOccurrences(of: "Generation:", with: "Gen:"), importedAt: Date(), isLiveRead: true).fieldFingerprint
        #expect(a != b)
    }

    @Test func labelStripsOnlyNumericPrefix() {
        #expect(BTMRecord.stripPrefix("16.com.a.b") == "com.a.b")
        #expect(BTMRecord.stripPrefix("com.a.b") == "com.a.b")
        #expect(BTMRecord.stripPrefix("2x.com.a") == "2x.com.a")
        #expect(BTMRecord.stripPrefix(".hidden") == ".hidden")
    }
}
