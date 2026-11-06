import Foundation
import InspectorModel

/// An installed app the engine can attribute items to.
public struct AppIndexEntry: Sendable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let teamID: String?
    public init(path: String, name: String, bundleID: String?, teamID: String?) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.teamID = teamID
    }
}

/// Attributes extensions, startup items and TCC clients to parent apps, with reason and confidence (plan §4.7).
/// Pure and deterministic given the injected lookups.
public struct AssociationEngine: Sendable {
    private let apps: [AppIndexEntry]
    private let realByPath: [String: AppIndexEntry]          // symlink-resolved path → app
    private let sortedRealPaths: [String]                    // longest first: nested helpers win
    /// Apps per bundle ID. Two installed copies of one ID make an ID-based match ambiguous.
    private let byBundleID: [String: [AppIndexEntry]]
    private let teamOf: @Sendable (String) -> String?        // executable/bundle path → Team ID

    /// - Parameter teamOfPath: Team ID for a path (code signing). Called only when signals lack a team.
    public init(apps: [AppIndexEntry], teamOfPath: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.apps = apps
        var real: [String: AppIndexEntry] = [:]
        var ids: [String: [AppIndexEntry]] = [:]
        for a in apps {
            real[Self.real(a.path)] = a
            if let b = a.bundleID { ids[b, default: []].append(a) }
        }
        self.realByPath = real
        self.sortedRealPaths = real.keys.sorted { $0.count > $1.count }
        self.byBundleID = ids
        self.teamOf = teamOfPath
    }

    static func real(_ p: String) -> String { PathResolver.real(p) }

    private func appContaining(_ path: String) -> AppIndexEntry? {
        let r = Self.real(path)
        guard let hit = sortedRealPaths.first(where: { r == $0 || r.hasPrefix($0 + "/") }) else { return nil }
        return realByPath[hit]
    }

    private func app(_ e: AppIndexEntry, rank: Int, _ c: AssociationConfidence, _ why: String) -> Association {
        Association(target: .app(path: e.path), rank: rank, confidence: c, reason: why)
    }

    private func unique(_ bundleID: String) -> AppIndexEntry? {
        guard let list = byBundleID[bundleID], list.count == 1 else { return nil }
        return list[0]
    }

    public func associate(_ s: AssociationSignals) -> Association {
        // 1. Containment: the item lives inside X.app.
        if let p = s.itemPath, let a = appContaining(p), Self.real(p) != Self.real(a.path) {
            return app(a, rank: 1, .definitive, "Located inside \(a.name).app")
        }
        // 2. Explicit parent metadata.
        if let p = s.parentBundlePath, let a = appContaining(p) {
            return app(a, rank: 2, .strong, "Parent bundle reported by the system: \(a.name).app")
        }
        // Bundle-ID matches count only when exactly one installed app has that ID. With copies, defer to the
        // path-based signals below (executable location) rather than pick one arbitrarily.
        if let id = s.parentBundleID, let a = unique(id) {
            return app(a, rank: 2, .strong, "Parent bundle identifier reported by launchd: \(id)")
        }
        for id in s.associatedBundleIDs {
            if let a = unique(id) { return app(a, rank: 2, .strong, "Associated bundle identifier declared: \(id)") }
        }
        // 3. Executable resolves into a bundle.
        if let p = s.executablePath, let a = appContaining(p) {
            return app(a, rank: 3, .strong, "Runs an executable inside \(a.name).app")
        }
        // 4/5. Code signing.
        let team = s.teamID ?? (s.executablePath ?? s.itemPath).flatMap(teamOf)
        if let team, let id = s.identifier {
            let candidates = apps.filter { a in
                guard a.teamID == team, let b = a.bundleID else { return false }
                return id == b || id.hasPrefix(b + ".")
            }
            // Longest matching bundle ID wins, but only when it is unambiguous (one app, not several copies).
            let longest = candidates.map { $0.bundleID?.count ?? 0 }.max() ?? 0
            let best = candidates.filter { ($0.bundleID?.count ?? 0) == longest }
            if best.count == 1, let best = best.first {
                return app(best, rank: 4, .probable,
                           "Same Team ID (\(team)) and identifier starts with \(best.bundleID ?? "")")
            }
        }
        if let team {
            return Association(target: .developerGroup(teamID: team), rank: 5, confidence: .developerGroup,
                               reason: "Same developer (Team ID \(team)); no specific app identified")
        }
        // 6. Heuristic: first three reverse-DNS components match exactly one installed app. Suggestion only.
        if let id = s.identifier, let key = Self.vendorProduct(id) {
            let matches = apps.filter { $0.bundleID.flatMap(Self.vendorProduct) == key }
            if matches.count == 1, let a = matches.first {
                return app(a, rank: 6, .suggestion, "Identifier looks related to \(a.name) (\(key)); not verified")
            }
        }
        return .none
    }

    /// `com.vendor.product.x.y` → `com.vendor.product` (needs ≥ 3 components).
    static func vendorProduct(_ id: String) -> String? {
        let c = id.split(separator: ".")
        guard c.count >= 3 else { return nil }
        return c.prefix(3).joined(separator: ".").lowercased()
    }
}
