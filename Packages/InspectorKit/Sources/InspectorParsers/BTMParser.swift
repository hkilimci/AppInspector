import Foundation
import CryptoKit

/// `enabled`/`disabled`, `allowed`/`disallowed`, `notified`/`not notified` from a BTM disposition.
public struct BTMDisposition: Sendable, Hashable {
    public let enabled: Bool
    public let allowed: Bool
    public let notified: Bool
}

public enum BTMKind: Sendable, Hashable {
    case app, loginItem, agent, daemon, legacyAgent, legacyDaemon, developer, quickLook, spotlight, dockTile, other
}

/// One item from `sfltool dumpbtm`.
public struct BTMRecord: Sendable, Hashable {
    public let uid: Int
    public let uuid: String
    public let name: String
    public let developerName: String?
    public let teamID: String?
    public let typeCode: Int
    public let typeName: String
    public let flags: [String]
    /// nil when the disposition text was not understood: callers must treat the approval as Unknown.
    public let disposition: BTMDisposition?
    /// Full identifier, e.g. `16.com.vendor.helper`.
    public let identifier: String
    public let url: String?
    public let executablePath: String?
    public let bundleIdentifier: String?
    public let parentIdentifier: String?
    public let assocBundleIDs: [String]
    public let embeddedIdentifiers: [String]

    /// Identifier without the leading type prefix (`16.` / `8.` / `2.`): the launchd label or bundle ID.
    public var label: String { Self.stripPrefix(identifier) }
    public var parentLabel: String? { parentIdentifier.map(Self.stripPrefix) }

    public var kind: BTMKind {
        if typeCode & 0x10000 != 0 {
            if typeCode & 0x8 != 0 { return .legacyAgent }
            if typeCode & 0x10 != 0 { return .legacyDaemon }
        }
        if typeCode & 0x2 != 0 { return .app }
        if typeCode & 0x4 != 0 { return .loginItem }
        if typeCode & 0x8 != 0 { return .agent }
        if typeCode & 0x10 != 0 { return .daemon }
        if typeCode & 0x20 != 0 { return .developer }
        if typeCode & 0x40 != 0 { return .spotlight }
        if typeCode & 0x80 != 0 { return .dockTile }
        if typeCode & 0x800 != 0 { return .quickLook }
        return .other
    }

    /// File path from an absolute `file://` URL; nil for relative URLs (login items) or other schemes.
    public var absolutePath: String? {
        guard let url, url.hasPrefix("file://") else { return nil }
        let path = String(url.dropFirst("file://".count))
        let decoded = path.removingPercentEncoding ?? path
        return decoded.count > 1 && decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }

    static func stripPrefix(_ id: String) -> String {
        guard let dot = id.firstIndex(of: "."), id[..<dot].allSatisfy(\.isNumber), dot != id.startIndex else { return id }
        return String(id[id.index(after: dot)...])
    }
}

public struct BTMReport: Sendable {
    public let records: [BTMRecord]
    /// Items dropped because a required field was missing. > 0 means the report is incomplete.
    public let skippedItems: Int
    public let uids: [Int]
    /// Hash of the set of field names seen: changes when Apple adds or renames fields.
    public let fieldFingerprint: String
    public let importedAt: Date
    /// True when read directly by the app (process exited 0, output not truncated); false for a user-supplied file.
    public let isLiveRead: Bool

    public init(records: [BTMRecord], skippedItems: Int, uids: [Int], fieldFingerprint: String, importedAt: Date, isLiveRead: Bool) {
        self.records = records; self.skippedItems = skippedItems; self.uids = uids
        self.fieldFingerprint = fieldFingerprint; self.importedAt = importedAt; self.isLiveRead = isLiveRead
    }
    public var isComplete: Bool { skippedItems == 0 }
}

public enum BTMParser {
    public static let requiredFields = ["UUID", "Type", "Disposition", "Identifier"]

    /// Tolerant per item, strict per report: unknown extra fields are kept out of the way, an item that lacks a
    /// required field is dropped and counted, and text without any `Records for UID` header throws.
    public static func parse(_ text: String, importedAt: Date, isLiveRead: Bool) throws -> BTMReport {
        var uid: Int?
        var sawHeader = false
        var records: [BTMRecord] = []
        var uids: [Int] = []
        var skipped = 0
        var fieldNames = Set<String>()

        var fields: [String: String] = [:]
        var embedded: [String] = []
        var inItem = false
        var inEmbedded = false

        func flush() {
            defer { fields = [:]; embedded = []; inItem = false; inEmbedded = false }
            guard inItem else { return }
            guard let u = uid, requiredFields.allSatisfy({ fields[$0] != nil }),
                  let typeText = fields["Type"], let code = hexCode(typeText) else { skipped += 1; return }
            let dispositionText = fields["Disposition"] ?? ""
            records.append(BTMRecord(
                uid: u, uuid: fields["UUID"] ?? "", name: fields["Name"] ?? "", developerName: nonNull(fields["Developer Name"]),
                teamID: nonNull(fields["Team Identifier"]), typeCode: code,
                typeName: typeText.components(separatedBy: " (0x").first ?? typeText,
                flags: bracketList(fields["Flags"] ?? ""), disposition: parseDisposition(dispositionText),
                identifier: fields["Identifier"] ?? "", url: nonNull(fields["URL"]), executablePath: nonNull(fields["Executable Path"]),
                bundleIdentifier: nonNull(fields["Bundle Identifier"]), parentIdentifier: nonNull(fields["Parent Identifier"]),
                assocBundleIDs: bracketList(fields["Assoc. Bundle IDs"] ?? ""), embeddedIdentifiers: embedded))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)

            if let r = t.range(of: #"^Records for UID (-?\d+) : "#, options: .regularExpression) {
                flush()
                let digits = t[r].dropFirst("Records for UID ".count).prefix { $0 != " " }
                uid = Int(digits); sawHeader = true
                if let u = uid, !uids.contains(u) { uids.append(u) }
                continue
            }
            if t.range(of: #"^#\d+:$"#, options: .regularExpression) != nil {       // item header (nested embedded entries carry text after the colon)
                flush(); inItem = true; continue
            }
            guard inItem else { continue }
            if t == "Embedded Item Identifiers:" { inEmbedded = true; fieldNames.insert("Embedded Item Identifiers"); continue }
            if inEmbedded {
                if let r = t.range(of: #"^#\d+: "#, options: .regularExpression) { embedded.append(String(t[r.upperBound...])); continue }
                inEmbedded = false
            }
            guard let colon = t.firstIndex(of: ":"), colon != t.startIndex else { continue }
            let key = String(t[..<colon])
            guard key.range(of: #"^[A-Za-z][A-Za-z. ]*$"#, options: .regularExpression) != nil else { continue }
            var value = String(t[t.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            if fields[key] == nil { fields[key] = value }
            fieldNames.insert(key)
        }
        flush()

        guard sawHeader else { throw ParseError.unrecognized("sfltool dumpbtm: no `Records for UID` header") }
        let digest = SHA256.hash(data: Data(fieldNames.sorted().joined(separator: ",").utf8))
        let fp = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return BTMReport(records: records, skippedItems: skipped, uids: uids, fieldFingerprint: fp,
                         importedAt: importedAt, isLiveRead: isLiveRead)
    }

    // MARK: helpers

    static func hexCode(_ typeText: String) -> Int? {
        guard let r = typeText.range(of: #"\(0x([0-9a-fA-F]+)\)"#, options: .regularExpression) else { return nil }
        let hex = typeText[r].dropFirst(3).dropLast()
        return Int(hex, radix: 16)
    }

    /// `[enabled, allowed, notified] (0xb)` → flags. Any token outside the known set makes the disposition unknown.
    static func parseDisposition(_ text: String) -> BTMDisposition? {
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]"), open < close else { return nil }
        let tokens = text[text.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var enabled: Bool?, allowed: Bool?, notified: Bool?
        for tok in tokens {
            switch tok {
            case "enabled": guard enabled == nil else { return nil }; enabled = true
            case "disabled": guard enabled == nil else { return nil }; enabled = false
            case "allowed": guard allowed == nil else { return nil }; allowed = true
            case "disallowed": guard allowed == nil else { return nil }; allowed = false
            case "notified": guard notified == nil else { return nil }; notified = true
            case "not notified": guard notified == nil else { return nil }; notified = false
            default: return nil
            }
        }
        guard let e = enabled, let a = allowed, let n = notified else { return nil }
        return BTMDisposition(enabled: e, allowed: a, notified: n)
    }

    static func bracketList(_ text: String) -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]"), open < close else { return [] }
        return text[text.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func nonNull(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "(null)" else { return nil }
        return s
    }
}
