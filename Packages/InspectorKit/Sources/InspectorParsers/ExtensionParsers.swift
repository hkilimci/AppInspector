import Foundation
import CryptoKit

public enum ParseError: Error, Sendable, Equatable {
    /// Non-empty input produced nothing recognizable: the format changed.
    case unrecognized(String)
}

// MARK: - pluginkit

public struct PluginkitEntry: Sendable, Hashable {
    /// Election mark: `+` use, `-` ignore, `=` superseded, `!` debugger. nil = no mark.
    public let mark: Character?
    public let identifier: String
    public let version: String
    public let fields: [String: String]
    public var path: String? { fields["Path"] }
    public var sdk: String? { fields["SDK"] }
    public var parentBundle: String? { fields["Parent Bundle"] }
    public var parentName: String? { fields["Parent Name"] }
    public var displayName: String? { fields["Display Name"] }
    public var platform: String? { fields["Platform"] }
}

public struct PluginkitParseResult: Sendable {
    public let entries: [PluginkitEntry]
    /// Field lines seen before any entry header, or headers that did not parse.
    public let skipped: Int
    /// Hash of the sorted set of field names: changes when Apple adds/renames fields.
    public let fieldFingerprint: String
}

public enum PluginkitParser {
    /// Parses `pluginkit -mAvvv`. Tolerant: unknown fields are kept, unparseable blocks are counted.
    public static func parse(_ text: String) throws -> PluginkitParseResult {
        var entries: [PluginkitEntry] = []
        var skipped = 0
        var fieldNames = Set<String>()

        var mark: Character?; var id: String?; var version = ""
        var fields: [String: String] = [:]
        var inEntry = false

        func flush() {
            if inEntry, let id { entries.append(PluginkitEntry(mark: mark, identifier: id, version: version, fields: fields)) }
            inEntry = false; id = nil; fields = [:]; mark = nil; version = ""
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { flush(); continue }
            // Footer: `(463 plug-ins)`.
            if stripped.hasPrefix("("), stripped.hasSuffix("plug-ins)") || stripped.hasSuffix("plug-in)") { flush(); continue }
            if line.hasPrefix("\t") || line.hasPrefix("  ") && line.contains(" = ") && inEntry {
                guard inEntry, let r = line.range(of: " = ") else { skipped += 1; continue }
                let key = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let val = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                fields[key] = val; fieldNames.insert(key)
                continue
            }
            // Header: optional mark, then `identifier(version)`.
            flush()
            var body = Substring(line)
            var m: Character?
            if let first = body.first, "+-=!".contains(first), body.dropFirst().first?.isWhitespace == true {
                m = first; body = body.dropFirst()
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(")"), let open = trimmed.firstIndex(of: "("), open > trimmed.startIndex else {
                skipped += 1; continue
            }
            id = String(trimmed[..<open])
            version = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            mark = m; inEntry = true
        }
        flush()

        if entries.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ParseError.unrecognized("no pluginkit entries recognized")
        }
        let digest = SHA256.hash(data: Data(fieldNames.sorted().joined(separator: ",").utf8))
        let fp = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return PluginkitParseResult(entries: entries, skipped: skipped, fieldFingerprint: fp)
    }
}

// MARK: - System extensions

public struct SystemExtensionRecord: Sendable, Hashable {
    public let identifier: String
    public let teamID: String?
    /// db.plist `state`, e.g. `activated_enabled`.
    public let dbState: String?
    public let categories: [String]
    public let containerBundlePath: String?
    public let originPath: String?
    public let appIdentifiers: [String]
    public let version: String?
}

public enum SystemExtensionParser {
    /// Parses `/Library/SystemExtensions/db.plist`. nil `teamID` when absent.
    public static func parseDB(_ data: Data) throws -> [SystemExtensionRecord] {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = obj as? [String: Any], let exts = root["extensions"] as? [[String: Any]]
        else { throw ParseError.unrecognized("db.plist: no extensions array") }
        return exts.compactMap { e in
            guard let id = e["identifier"] as? String else { return nil }
            let refs = (e["references"] as? [[String: Any]]) ?? []
            let team = (e["teamID"] as? String) ?? refs.compactMap { $0["teamID"] as? String }.first
            let ver = (e["bundleVersion"] as? [String: Any])?["CFBundleShortVersionString"] as? String
            return SystemExtensionRecord(
                identifier: id, teamID: team, dbState: e["state"] as? String,
                categories: (e["categories"] as? [String]) ?? [],
                containerBundlePath: (e["container"] as? [String: Any])?["bundlePath"] as? String,
                originPath: e["originPath"] as? String,
                appIdentifiers: refs.compactMap { $0["appIdentifier"] as? String }, version: ver)
        }
    }
}

public struct SystemExtensionCtlRow: Sendable, Hashable {
    public let category: String
    public let enabledMark: Bool
    public let activeMark: Bool
    public let teamID: String
    public let bundleID: String
    public let version: String
    public let name: String
    /// Text inside the trailing brackets, e.g. `activated enabled`.
    public let state: String
}

public enum SystemExtensionCtlParser {
    /// Parses `systemextensionsctl list`. A header line `--- <category> (…)` starts a section.
    /// Strict: any line that is not a count line, a section header, the column header, or a valid row throws,
    /// so malformed rows cannot parse as "no extensions".
    public static func parse(_ text: String) throws -> [SystemExtensionCtlRow] {
        var rows: [SystemExtensionCtlRow] = []
        var category = ""
        var declaredCount: Int?
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.unrecognized("systemextensionsctl list: empty output")
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("--- ") {
                category = String(line.dropFirst(4).prefix { $0 != " " })
                continue
            }
            if line.range(of: #"^\d+ extension\(s\)$"#, options: .regularExpression) != nil {
                declaredCount = Int(line.prefix { $0.isNumber }); continue
            }
            let cols = line.components(separatedBy: "\t")
            if cols.first == "enabled" && cols.count >= 6 { continue }          // column header
            guard cols.count >= 6, !category.isEmpty, let state = bracketed(cols[5]), let (bundle, ver) = bundleAndVersion(cols[3]) else {
                throw ParseError.unrecognized("systemextensionsctl list: unrecognized line")
            }
            rows.append(SystemExtensionCtlRow(
                category: category, enabledMark: cols[0] == "*", activeMark: cols[1] == "*",
                teamID: cols[2], bundleID: bundle, version: ver, name: cols[4], state: state))
        }
        guard let declared = declaredCount else { throw ParseError.unrecognized("systemextensionsctl list: no count line") }
        // The count line lets us detect a list cut at a row boundary.
        guard declared == rows.count else {
            throw ParseError.unrecognized("systemextensionsctl list: declared \(declared) extensions, parsed \(rows.count)")
        }
        return rows
    }

    private static func bracketed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        return String(t.dropFirst().dropLast())
    }
    private static func bundleAndVersion(_ s: String) -> (String, String)? {
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return nil }
        let bundle = s[..<open].trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty else { return nil }
        return (bundle, String(s[s.index(after: open)..<s.index(before: s.endIndex)]))
    }
}
