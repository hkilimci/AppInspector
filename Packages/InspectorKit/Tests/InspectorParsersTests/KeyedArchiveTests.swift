import Testing
import Foundation
@testable import InspectorParsers

/// Stands in for a private archived class such as BTM's `ItemRecord`.
@objc(FakeItemRecord) private final class FakeItemRecord: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let name: String, type: Int, uuid: UUID, url: URL, tags: [String], when: Date
    var parent: FakeItemRecord?
    init(name: String, type: Int, parent: FakeItemRecord? = nil) {
        self.name = name; self.type = type; self.uuid = UUID(); self.parent = parent
        self.url = URL(fileURLWithPath: "/Library/LaunchDaemons/\(name).plist"); self.tags = ["a", "b"]
        self.when = Date(timeIntervalSinceReferenceDate: 1000)
    }
    func encode(with c: NSCoder) {
        c.encode(name, forKey: "name"); c.encode(type, forKey: "type"); c.encode(uuid, forKey: "uuid")
        c.encode(url, forKey: "url"); c.encode(tags, forKey: "tags"); c.encode(when, forKey: "when")
        c.encode(parent, forKey: "parent")
    }
    required init?(coder: NSCoder) { nil }
}

@Suite struct KeyedArchiveTests {
    private func archive(_ root: Any) throws -> Data {
        let a = NSKeyedArchiver(requiringSecureCoding: false)
        a.encode(root, forKey: "root")
        a.finishEncoding()
        return a.encodedData
    }

    @Test func decodesPrivateClassesAsFieldsWithoutInstantiatingThem() throws {
        let parent = FakeItemRecord(name: "com.x.parent", type: 2)
        let child = FakeItemRecord(name: "com.x.helper", type: 16, parent: parent)
        let v = try KeyedArchive.decode(try archive(["501": [child, parent]] as NSDictionary))
        let items = try #require(v["501"]?.array)
        #expect(items.count == 2)
        #expect(items[0].className == "FakeItemRecord")
        #expect(items[0]["name"]?.string == "com.x.helper")
        #expect(items[0]["type"]?.int == 16)
        #expect(items[0]["uuid"]?.string == child.uuid.uuidString)
        #expect(items[0]["url"]?.string == "file:///Library/LaunchDaemons/com.x.helper.plist")
        #expect(items[0]["tags"]?.array == [.string("a"), .string("b")])
        #expect(items[0]["when"] == .date(Date(timeIntervalSinceReferenceDate: 1000)))
        #expect(items[0]["parent"]?["name"]?.string == "com.x.parent")   // shared reference decoded in place
        #expect(items[1]["parent"] == .null)
    }

    @Test func cyclesTerminate() throws {
        let a = FakeItemRecord(name: "a", type: 1)
        a.parent = a
        let v = try KeyedArchive.decode(try archive(a))
        #expect(v["name"]?.string == "a")
        #expect(v["parent"] == .null)
    }

    @Test func rejectsNonArchives() throws {
        #expect(throws: KeyedArchiveError.notAPropertyList) { try KeyedArchive.decode(Data("nope".utf8)) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        #expect(throws: KeyedArchiveError.notAKeyedArchive) { try KeyedArchive.decode(plist) }
    }

    @Test func truncatedArchivesThrowOrDecodeButNeverCrash() throws {
        let data = try archive(FakeItemRecord(name: "x", type: 1, parent: FakeItemRecord(name: "y", type: 2)))
        for cut in stride(from: 0, to: data.count, by: 7) { _ = try? KeyedArchive.decode(data.prefix(cut)) }
    }
}
