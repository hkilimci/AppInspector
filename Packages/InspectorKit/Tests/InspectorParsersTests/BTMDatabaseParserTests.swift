import Testing
import Foundation
@testable import InspectorParsers

/// Archived under BTM's real class names so the archive matches what the parser sees in `BackgroundItems-v16.btm`.
@objc(ItemRecord) private final class FakeRecord: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    var fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }
    func encode(with c: NSCoder) { for (k, v) in fields { c.encode(v, forKey: k) } }
    required init?(coder: NSCoder) { nil }
}

@objc(Storage) private final class FakeStorage: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let byUser: NSDictionary
    init(_ byUser: NSDictionary) { self.byUser = byUser }
    func encode(with c: NSCoder) {
        c.encode(byUser, forKey: "itemsByUserIdentifier")
        c.encode(NSDictionary(), forKey: "userSettingsByUserIdentifier")
    }
    required init?(coder: NSCoder) { nil }
}

@Suite struct BTMDatabaseParserTests {
    private func record(_ id: String, type: Int, disposition: Int, items: [String] = [], extra: [String: Any] = [:]) -> FakeRecord {
        var f: [String: Any] = ["identifier": id, "type": type, "disposition": disposition, "uuid": UUID().uuidString,
                                "name": id, "flags": 0x1, "items": items, "generation": 1]
        f.merge(extra) { $1 }
        return FakeRecord(f)
    }

    private func decode(_ byUser: NSDictionary) throws -> ArchiveValue {
        let a = NSKeyedArchiver(requiringSecureCoding: false)
        a.encode(FakeStorage(byUser), forKey: "store")
        a.encode(16, forKey: "version")
        a.finishEncoding()
        return try KeyedArchive.decode(a.encodedData)
    }

    @Test func mapsRecordsLikeSfltool() throws {
        let app = record("2.com.vendor.app", type: 0x2, disposition: 0xb, items: ["16.com.vendor.agent"],
                         extra: ["teamIdentifier": "ABCDE12345", "developerName": "Vendor", "bundleIdentifier": "com.vendor.app",
                                 "url": NSURL(fileURLWithPath: "/Applications/Vendor.app"), "associatedBundleIdentifiers": ["com.vendor.app"]])
        let agent = record("16.com.vendor.agent", type: 0x10008, disposition: 0x2,
                           extra: ["url": NSURL(fileURLWithPath: "/Library/LaunchAgents/com.vendor.agent.plist"),
                                   "executablePath": "/Applications/Vendor.app/Contents/MacOS/agent"])
        let root = try decode(["501": [app, agent]])
        let r = try BTMDatabaseParser.parse(root, uidForUserKey: { Int($0) }, importedAt: Date(timeIntervalSince1970: 0))
        #expect(r.isComplete && r.isLiveRead && r.uids == [501])
        let a = try #require(r.records.first { $0.identifier == "2.com.vendor.app" })
        #expect(a.kind == .app && a.typeName == "app" && a.teamID == "ABCDE12345" && a.developerName == "Vendor")
        #expect(a.disposition == BTMDisposition(enabled: true, allowed: true, notified: true))
        #expect(a.embeddedIdentifiers == ["16.com.vendor.agent"] && a.assocBundleIDs == ["com.vendor.app"])
        #expect(a.flags == ["legacy"])
        let g = try #require(r.records.first { $0.identifier == "16.com.vendor.agent" })
        #expect(g.kind == .legacyAgent && g.typeName == "legacy agent")
        #expect(g.disposition == BTMDisposition(enabled: false, allowed: true, notified: false))
        #expect(g.parentIdentifier == "2.com.vendor.app")
        #expect(g.absolutePath == "/Library/LaunchAgents/com.vendor.agent.plist")
        #expect(g.label == "com.vendor.agent")
    }

    @Test func unknownDispositionBitsAreUnknownNotGuessed() {
        #expect(BTMDatabaseParser.disposition(0x9) == BTMDisposition(enabled: true, allowed: false, notified: true))
        #expect(BTMDatabaseParser.disposition(0xf) != nil)
        #expect(BTMDatabaseParser.disposition(0x13) == nil)
        #expect(BTMDatabaseParser.disposition(-1) == nil)
    }

    @Test func incompleteRecordsAndUnknownUsersAreCountedNotDropped() throws {
        let bad = FakeRecord(["identifier": "16.x", "type": 8])           // no disposition / uuid
        let ok = record("16.y", type: 8, disposition: 3)
        let root = try decode(["501": [bad, ok], "not-a-user": [ok]])
        let r = try BTMDatabaseParser.parse(root, uidForUserKey: { Int($0) }, importedAt: Date())
        #expect(r.records.map(\.identifier) == ["16.y"])
        #expect(r.skippedItems == 2)
        #expect(!r.isComplete)
    }

    @Test func missingStoreThrows() throws {
        #expect(throws: BTMDatabaseParser.ParseError.self) {
            try BTMDatabaseParser.parse(.dict(["version": .int(16)]), uidForUserKey: { _ in 0 }, importedAt: Date())
        }
    }

    @Test func picksHighestVersionFile() {
        let names = ["BackgroundItems-v9.btm", "BackgroundItems-v16.btm", "BackgroundItems-v13.btm", "other.plist"]
        #expect(BTMDatabaseParser.currentFile(in: names)?.name == "BackgroundItems-v16.btm")
        #expect(BTMDatabaseParser.currentFile(in: ["x"]) == nil)
    }
}
