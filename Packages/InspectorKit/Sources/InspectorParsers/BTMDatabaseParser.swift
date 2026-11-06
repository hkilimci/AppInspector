import Foundation
import CryptoKit

/// Reads the Background Task Management database (`BackgroundItems-v*.btm`, an `NSKeyedArchiver` file) into the
/// same `BTMReport` that `sfltool dumpbtm` text produces. Needs Full Disk Access to read the file; no root and
/// no authorization prompt. Layout calibrated on macOS 26.5.1 (v16): `Storage.itemsByUserIdentifier` maps a
/// user key to `[ItemRecord]`.
public enum BTMDatabaseParser {
    public static let directory = "/private/var/db/com.apple.backgroundtaskmanagement"
    /// Item fields that must be present for a record to be used; anything else missing is optional.
    public static let requiredFields = ["uuid", "type", "disposition", "identifier"]
    /// Versions whose layout has been checked against `sfltool dumpbtm`.
    public static let validatedVersions: Set<Int> = [16]

    public enum ParseError: Error, Sendable, Equatable {
        case unrecognized(String)
    }

    /// `BackgroundItems-v16.btm` → 16. Older versions stay on disk after OS upgrades; the highest is current.
    public static func version(ofFileNamed name: String) -> Int? {
        guard name.hasPrefix("BackgroundItems-v"), name.hasSuffix(".btm") else { return nil }
        return Int(name.dropFirst("BackgroundItems-v".count).dropLast(".btm".count))
    }

    public static func currentFile(in names: [String]) -> (name: String, version: Int)? {
        names.compactMap { n in version(ofFileNamed: n).map { (n, $0) } }.max { $0.1 < $1.1 }
    }

    /// `uidForUserKey` maps a key of `itemsByUserIdentifier` (a user UUID) to a numeric UID; nil skips that user.
    public static func parse(_ root: ArchiveValue, uidForUserKey: (String) -> Int?, importedAt: Date) throws -> BTMReport {
        guard let store = root["store"], let byUser = store["itemsByUserIdentifier"]?.fields else {
            throw ParseError.unrecognized("BTM database: no store.itemsByUserIdentifier")
        }
        var records: [BTMRecord] = []
        var skipped = 0
        var uids: [Int] = []
        var fieldNames: Set<String> = []
        for (key, list) in byUser.sorted(by: { $0.key < $1.key }) {
            guard let items = list.array else { skipped += 1; continue }
            guard let uid = uidForUserKey(key) else { skipped += items.count; continue }
            if !uids.contains(uid) { uids.append(uid) }
            // sfltool derives "Parent Identifier" the same way: the record whose `items` lists this one.
            var parentOf: [String: String] = [:]
            for item in items {
                guard let id = item["identifier"]?.string else { continue }
                for child in item["items"]?.array ?? [] { if let c = child.string, parentOf[c] == nil { parentOf[c] = id } }
            }
            for item in items {
                guard let fields = item.fields, item.className == "ItemRecord" else { skipped += 1; continue }
                fieldNames.formUnion(fields.keys)
                guard requiredFields.allSatisfy({ fields[$0] != nil && fields[$0] != .null }),
                      let identifier = fields["identifier"]?.string,
                      let type = fields["type"]?.int, let disp = fields["disposition"]?.int
                else { skipped += 1; continue }
                let code = Int(type)
                records.append(BTMRecord(
                    uid: uid, uuid: fields["uuid"]?.string ?? "", name: fields["name"]?.string ?? "",
                    developerName: fields["developerName"]?.string, teamID: fields["teamIdentifier"]?.string,
                    typeCode: code, typeName: typeName(code), flags: flagNames(Int(fields["flags"]?.int ?? 0)),
                    disposition: disposition(Int(disp)), identifier: identifier,
                    url: fields["url"]?.string, executablePath: fields["executablePath"]?.string,
                    bundleIdentifier: fields["bundleIdentifier"]?.string, parentIdentifier: parentOf[identifier],
                    assocBundleIDs: (fields["associatedBundleIdentifiers"]?.array ?? []).compactMap(\.string),
                    embeddedIdentifiers: (fields["items"]?.array ?? []).compactMap(\.string)))
            }
        }
        let digest = SHA256.hash(data: Data(fieldNames.sorted().joined(separator: ",").utf8))
        return BTMReport(records: records, skippedItems: skipped, uids: uids,
                         fieldFingerprint: digest.prefix(8).map { String(format: "%02x", $0) }.joined(),
                         importedAt: importedAt, isLiveRead: true)
    }

    /// Bits as `sfltool dumpbtm` prints them: 0x1 enabled, 0x2 allowed, 0x4 visible/hidden marker, 0x8 notified.
    /// Any other bit means a layout we have not seen: the disposition becomes unknown rather than guessed.
    static func disposition(_ v: Int) -> BTMDisposition? {
        guard v >= 0, v & ~0xF == 0 else { return nil }
        return BTMDisposition(enabled: v & 0x1 != 0, allowed: v & 0x2 != 0, notified: v & 0x8 != 0)
    }

    static func flagNames(_ v: Int) -> [String] {
        let known: [(Int, String)] = [(0x1, "legacy"), (0x4, "curated"), (0x40, "sandboxed")]
        var names = known.filter { v & $0.0 != 0 }.map(\.1)
        let rest = v & ~known.reduce(0) { $0 | $1.0 }
        if rest != 0 { names.append(String(format: "0x%x", rest)) }
        return names
    }

    static func typeName(_ code: Int) -> String {
        let legacy = code & 0x10000 != 0 ? "legacy " : ""
        if code & 0x2 != 0 { return "app" }
        if code & 0x4 != 0 { return "login item" }
        if code & 0x8 != 0 { return legacy + "agent" }
        if code & 0x10 != 0 { return legacy + "daemon" }
        if code & 0x20 != 0 { return "developer" }
        if code & 0x40 != 0 { return "spotlight" }
        if code & 0x80 != 0 { return "dock tile" }
        if code & 0x800 != 0 { return "quicklook" }
        return String(format: "0x%x", code)
    }
}
