import Foundation

/// Identifies where a fact came from.
public struct SourceID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let appInventory: SourceID = "app-inventory"
    public static let bundleInfo: SourceID = "bundle-info"
    public static let tccUser: SourceID = "tcc-user-db"
    public static let tccSystem: SourceID = "tcc-system-db"
    public static let accessProbe: SourceID = "access-probe"
    public static let pluginkit: SourceID = "pluginkit"
    public static let systemExtensionsDB: SourceID = "system-extensions-db"
    public static let systemExtensionsCtl: SourceID = "systemextensionsctl"
    public static let launchctlDomain: SourceID = "launchctl-domain"
    public static let launchctlDisabled: SourceID = "launchctl-print-disabled"
    public static let launchdPlists: SourceID = "launchd-plists"
    public static let bundledHelpers: SourceID = "bundled-helpers"
    public static let launchctlJobs: SourceID = "launchctl-job-lookups"
    public static let btm: SourceID = "btm-dump"
}

public struct OSVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }
    public static func < (a: OSVersion, b: OSVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct OSInfo: Hashable, Sendable {
    public let version: OSVersion
    public let build: String
    public init(version: OSVersion, build: String) { self.version = version; self.build = build }
}

/// Raw provenance attached to every displayed state.
public struct Evidence: Sendable, Hashable {
    public let source: SourceID
    /// File + row, command + label, API call.
    public let locator: String
    public let observedAt: Date
    public let osBuild: String
    public let excerpt: String?
    /// True when the OS is outside the source's validated range and the source is tier C/D.
    public let unvalidatedOS: Bool
    /// The source is an imported or cached snapshot that is older than the last boot or otherwise past its useful age.
    public let staleSource: Bool

    public init(source: SourceID, locator: String, observedAt: Date = Date(), osBuild: String,
                excerpt: String? = nil, unvalidatedOS: Bool = false, staleSource: Bool = false) {
        self.source = source; self.locator = locator; self.observedAt = observedAt
        self.osBuild = osBuild; self.excerpt = excerpt; self.unvalidatedOS = unvalidatedOS; self.staleSource = staleSource
    }
}

public enum UnknownReason: Sendable, Hashable {
    case needsFullDiskAccess
    case needsBTMImport
    case needsAccessibility
    case appNotRunning
    case notInspectable(String)
    case unsupportedOS(String)
    case formatUnrecognized(SourceID, String)
    case sourceFailed(SourceID, String)
    case timedOut(SourceID)

    public var message: String {
        switch self {
        case .needsFullDiskAccess: "Grant Full Disk Access to read this"
        case .needsBTMImport: "Import a Background Task Management report to read this"
        case .needsAccessibility: "Grant Accessibility access to read this"
        case .appNotRunning: "App is not running"
        case .notInspectable(let why): "Not inspectable: \(why)"
        case .unsupportedOS(let why): "Unsupported macOS: \(why)"
        case .formatUnrecognized(let s, let why): "Unrecognized \(s) format: \(why)"
        case .sourceFailed(let s, let why): "\(s) failed: \(why)"
        case .timedOut(let s): "\(s) timed out"
        }
    }
}

/// The hard rule: a value is shown as fact only when `confirmed` (or `notRecorded`);
/// anything we could not read is `unknown`, never a negative.
public enum Determination<Value: Sendable>: Sendable {
    /// Read from a source authoritative for this item on this OS.
    case confirmed(Value, Evidence)
    /// Authoritative source read OK and has no entry.
    case notRecorded(Evidence)
    /// A recorded decision whose code requirement does not match the installed copy.
    /// This says nothing about the installed copy's current authorization.
    case recordedForDifferentSignature(Evidence)
    /// App declares it may use this (Info.plist key, entitlement): a capability, not a state.
    case declared(Evidence)
    /// Heuristic. Never rendered as fact.
    case inferred(Value, Evidence, why: String)
    case unknown(UnknownReason)

    public var evidence: Evidence? {
        switch self {
        case .confirmed(_, let e), .notRecorded(let e), .recordedForDifferentSignature(let e),
             .declared(let e), .inferred(_, let e, _): e
        case .unknown: nil
        }
    }
    public var isUnknown: Bool { if case .unknown = self { true } else { false } }
}
