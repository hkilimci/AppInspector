import Foundation

// MARK: - `launchctl print gui/<uid>` / `system` : services table

public struct LaunchdService: Sendable, Hashable {
    /// > 0 when running.
    public let pid: Int
    public let flags: String
    public let label: String
}

public enum LaunchctlParser {
    /// Parses the `services = { … }` block of `launchctl print <domain>`.
    /// Lines look like `  31318   (pe) \tcom.apple.syncdefaultsd`; pid 0 means loaded, not running.
    /// Strict: empty output, a missing/unclosed block, or any unparseable row throws. A partial list must
    /// never be mistaken for a complete one, because absence from it is later read as "not loaded".
    public static func parseServices(_ text: String) throws -> [LaunchdService] {
        var out: [LaunchdService] = []
        var inBlock = false, sawBlock = false, closed = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if t == "services = {" && !sawBlock { inBlock = true; sawBlock = true }
                continue
            }
            if t == "}" { inBlock = false; closed = true; continue }
            if t.isEmpty { continue }
            let parts = t.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3, let pid = Int(parts[0]) else {
                throw ParseError.unrecognized("launchctl print: unparseable service row")
            }
            out.append(LaunchdService(pid: pid, flags: parts[1], label: parts[2...].joined(separator: " ")))
        }
        guard sawBlock else { throw ParseError.unrecognized("launchctl print: no `services = {` block") }
        guard closed else { throw ParseError.unrecognized("launchctl print: `services` block not closed (output cut off?)") }
        return out
    }

    /// Parses `launchctl print-disabled <domain>`: label → disabled?
    /// Strict for the same reason: an unrecognized or dropped entry would read as "no override recorded".
    public static func parseDisabled(_ text: String) throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        var inBlock = false, sawBlock = false, closed = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if t.hasPrefix("disabled services") && !sawBlock { inBlock = true; sawBlock = true }
                continue
            }
            if t == "}" { inBlock = false; closed = true; continue }
            if t.isEmpty { continue }
            guard t.hasPrefix("\""), let r = t.range(of: "\" => ") else {
                throw ParseError.unrecognized("launchctl print-disabled: unparseable row")
            }
            let label = String(t[t.index(after: t.startIndex)..<r.lowerBound])
            switch t[r.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": out[label] = true
            case "enabled", "false": out[label] = false
            case let other: throw ParseError.unrecognized("launchctl print-disabled: unknown value \(other)")
            }
        }
        guard sawBlock else { throw ParseError.unrecognized("launchctl print-disabled: no `disabled services` block") }
        guard closed else { throw ParseError.unrecognized("launchctl print-disabled: block not closed (output cut off?)") }
        return out
    }
}

// MARK: - `launchctl print <domain>/<label>` : one job

public struct LaunchdJob: Sendable, Hashable {
    public let target: String
    /// Top-level `key = value` pairs (first occurrence wins).
    public let fields: [String: String]
    public let arguments: [String]
    public var path: String? { fields["path"] }
    public var type: String? { fields["type"] }
    public var state: String? { fields["state"] }
    public var program: String? { fields["program"] }
    public var parentBundleID: String? { fields["parent bundle identifier"] }
    public var managedBy: String? { fields["managed_by"] }
    public var pid: Int? { fields["pid"].flatMap(Int.init) }
    /// `launchctl print` shows a pseudo-path like `(submitted by smd.336)` for registered jobs.
    public var isSubmitted: Bool { type == "Submitted" }
}

public enum LaunchdJobParser {
    public static func parse(_ text: String) throws -> LaunchdJob {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              first.hasSuffix(" = {"), !first.hasPrefix("\t") else {
            throw ParseError.unrecognized("launchctl print <job>: missing `<target> = {` header")
        }
        let target = String(first.dropLast(4))
        var fields: [String: String] = [:]
        var args: [String] = []
        var depth = 0
        var inArgs = false
        for line in lines.drop(while: { $0 != first }).dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasSuffix("= {") {
                if depth == 0, t == "arguments = {" { inArgs = true }
                depth += 1; continue
            }
            if t == "}" {
                if depth == 0 { break }
                depth -= 1; if depth == 0 { inArgs = false }
                continue
            }
            if depth == 0, let r = t.range(of: " = ") {
                let k = String(t[..<r.lowerBound]), v = String(t[r.upperBound...])
                if fields[k] == nil { fields[k] = v }
            } else if depth == 1, inArgs { args.append(t) }
        }
        return LaunchdJob(target: target, fields: fields, arguments: args)
    }
}

// MARK: - Legacy launchd plists

public struct LegacyLaunchdJob: Sendable, Hashable {
    public let label: String
    public let program: String?
    public let runAtLoad: Bool?
    public let keepAlive: Bool?
    public let disabledKey: Bool?
    public let associatedBundleIDs: [String]
    /// ServiceManagement-style `BundleProgram` (relative to the app).
    public let bundleProgram: String?
}

public enum LaunchdPlistParser {
    public static func parse(_ data: Data) throws -> LegacyLaunchdJob {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let d = obj as? [String: Any], let label = d["Label"] as? String, !label.isEmpty
        else { throw ParseError.unrecognized("launchd plist: no Label") }
        let args = d["ProgramArguments"] as? [String]
        let keep: Bool?
        switch d["KeepAlive"] {
        case let b as Bool: keep = b
        case is [String: Any]: keep = true      // conditional KeepAlive: treat as "keeps alive under conditions"
        default: keep = nil
        }
        let assoc: [String]
        switch d["AssociatedBundleIdentifiers"] {
        case let s as String: assoc = [s]
        case let a as [String]: assoc = a
        default: assoc = []
        }
        return LegacyLaunchdJob(
            label: label, program: (d["Program"] as? String) ?? args?.first,
            runAtLoad: d["RunAtLoad"] as? Bool, keepAlive: keep, disabledKey: d["Disabled"] as? Bool,
            associatedBundleIDs: assoc, bundleProgram: d["BundleProgram"] as? String)
    }
}
