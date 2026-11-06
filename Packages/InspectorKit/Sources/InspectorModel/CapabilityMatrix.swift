import Foundation

public enum Requirement: Sendable, Hashable { case none, fullDiskAccess, btmImport, accessibility }

/// A public API · B documented CLI · C CLI output not declared as API · D undocumented file/DB · E deprecated API.
public enum StabilityTier: Int, Sendable, Hashable, Comparable {
    case a = 1, b, c, d, e
    public static func < (l: StabilityTier, r: StabilityTier) -> Bool { l.rawValue < r.rawValue }
}

public enum ItemKind: Sendable, Hashable { case privacy, `extension`, startup, shortcut }

public enum Scope: Sendable, Hashable {
    case none, all, only(Set<String>)
    public func contains(_ key: String) -> Bool {
        switch self { case .none: false; case .all: true; case .only(let s): s.contains(key) }
    }
}

public struct Authority: Sendable, Hashable {
    /// Which services/items this source can confirm.
    public let confirms: Scope
    /// For which ones a missing entry means "no record" (vs. unknown).
    public let absenceMeaningful: Scope
    public init(confirms: Scope, absenceMeaningful: Scope) {
        self.confirms = confirms; self.absenceMeaningful = absenceMeaningful
    }
}

public struct SourceCapability: Sendable {
    public let id: SourceID
    public let requirement: Requirement
    public let tier: StabilityTier
    /// nil = not yet validated on any OS.
    public let validatedOS: ClosedRange<OSVersion>?
    public let authority: [ItemKind: Authority]
    public init(id: SourceID, requirement: Requirement, tier: StabilityTier,
                validatedOS: ClosedRange<OSVersion>?, authority: [ItemKind: Authority]) {
        self.id = id; self.requirement = requirement; self.tier = tier
        self.validatedOS = validatedOS; self.authority = authority
    }
    /// Tier C/D result outside the validated range gets an "unvalidated" flag.
    public func isUnvalidated(on os: OSVersion) -> Bool {
        guard tier >= .c else { return false }
        guard let r = validatedOS else { return true }
        return !r.contains(os)
    }
}

/// Proof that the capability matrix marks `source` authoritative for `item` on this OS.
/// Only `CapabilityMatrix` can mint one (internal init): negative states cannot be built without it.
public struct ConfirmedSource: Sendable {
    public let source: SourceID
    public let item: ItemKind
    public let key: String
    public let unvalidatedOS: Bool
    internal init(source: SourceID, item: ItemKind, key: String, unvalidatedOS: Bool) {
        self.source = source; self.item = item; self.key = key; self.unvalidatedOS = unvalidatedOS
    }
}

public struct CapabilityMatrix: Sendable {
    public let capabilities: [SourceID: SourceCapability]
    public init(_ caps: [SourceCapability]) {
        capabilities = Dictionary(uniqueKeysWithValues: caps.map { ($0.id, $0) })
    }

    /// nil when the source is not authoritative for this item: callers must emit `.unknown`.
    public func confirmedSource(for source: SourceID, item: ItemKind, key: String, os: OSVersion) -> ConfirmedSource? {
        guard let cap = capabilities[source], let auth = cap.authority[item], auth.confirms.contains(key) else { return nil }
        return ConfirmedSource(source: source, item: item, key: key, unvalidatedOS: cap.isUnvalidated(on: os))
    }

    /// True when a missing entry for `key` is meaningful ("no record") given the source was read OK.
    public func absenceMeaningful(source: SourceID, item: ItemKind, key: String) -> Bool {
        capabilities[source]?.authority[item]?.absenceMeaningful.contains(key) ?? false
    }

    public func capability(_ id: SourceID) -> SourceCapability? { capabilities[id] }

    /// Phase 1 defaults. Validated ranges are provisional until Phase 0 VM runs finish (only 26.x observed).
    public static let phase1 = CapabilityMatrix([
        SourceCapability(
            id: .tccUser, requirement: .fullDiskAccess, tier: .d,
            validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.privacy: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .tccSystem, requirement: .fullDiskAccess, tier: .d,
            validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.privacy: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .bundleInfo, requirement: .none, tier: .a, validatedOS: nil,
            authority: [:]),
        // Phase 2. Validated on the 26.x host only; 15 and 27 pending VM runs.
        // pluginkit elections: no mark means "no recorded choice", so absence is never meaningful.
        SourceCapability(
            id: .pluginkit, requirement: .none, tier: .c, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.extension: Authority(confirms: .all, absenceMeaningful: .none)]),
        SourceCapability(
            id: .systemExtensionsCtl, requirement: .none, tier: .c, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.extension: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .systemExtensionsDB, requirement: .none, tier: .d, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [:]),
        SourceCapability(
            id: .launchctlDomain, requirement: .none, tier: .c, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.startup: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .launchctlDisabled, requirement: .none, tier: .c, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.startup: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .launchdPlists, requirement: .none, tier: .a, validatedOS: nil,
            authority: [.startup: Authority(confirms: .all, absenceMeaningful: .none)]),
        // Phase 3: `sfltool dumpbtm` text. Undocumented format, validated on 26.5.1 only.
        // Absence is further gated at the call site (live read only, report not stale, item not newer than the report).
        SourceCapability(
            id: .btm, requirement: .btmImport, tier: .d, validatedOS: OSVersion(26, 0)...OSVersion(26, 99, 99),
            authority: [.startup: Authority(confirms: .all, absenceMeaningful: .all)]),
        SourceCapability(
            id: .bundledHelpers, requirement: .none, tier: .a, validatedOS: nil,
            authority: [.startup: Authority(confirms: .all, absenceMeaningful: .none)]),
    ])
}
