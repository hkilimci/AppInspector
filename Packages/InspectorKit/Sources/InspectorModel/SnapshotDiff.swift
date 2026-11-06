import Foundation

/// "New since the last scan", computed in memory only. The first scan has nothing to compare against, so nothing is new.
public struct SnapshotDiff: Sendable, Equatable {
    public var newIDs: Set<String> = []
    public var changedIDs: Set<String> = []
    public var removedCount = 0
    public var isEmpty: Bool { newIDs.isEmpty && changedIDs.isEmpty && removedCount == 0 }

    public static let empty = SnapshotDiff()

    public static func between(_ old: Snapshot?, _ new: Snapshot) -> SnapshotDiff {
        guard let old else { return .empty }
        let a = signatures(old), b = signatures(new)
        var d = SnapshotDiff()
        for (id, sig) in b {
            if let before = a[id] { if before != sig { d.changedIDs.insert(id) } } else { d.newIDs.insert(id) }
        }
        d.removedCount = a.keys.filter { b[$0] == nil }.count
        return d
    }

    // MARK: ids

    public static func appID(_ path: String) -> String { "app:\(path)" }
    /// `itemID` is `PermissionItem.id`, which includes the target of a scoped decision (e.g. Automation → Mail).
    public static func permissionID(owner: String, itemID: String) -> String { "perm:\(owner):\(itemID)" }
    public static func extensionID(_ id: String) -> String { "ext:\(id)" }
    public static func startupID(_ id: String) -> String { "start:\(id)" }

    /// Every item the UI can badge, with a signature of its determinations (evidence times excluded).
    static func signatures(_ s: Snapshot) -> [String: String] {
        var out: [String: String] = [:]
        func perms(_ items: [PermissionItem], owner: String) {
            for p in items { out[permissionID(owner: owner, itemID: p.id)] = sig(p.state) + "|" + (p.signatureMatch.map(sig) ?? "") }
        }
        func exts(_ items: [ExtensionItem]) { for e in items { out[extensionID(e.id)] = sig(e.state) } }
        func starts(_ items: [StartupItem]) {
            for i in items { out[startupID(i.id)] = [sig(i.loadState), sig(i.override), sig(i.approval)].joined(separator: "|") }
        }
        for a in s.apps {
            out[appID(a.path)] = "\(a.version ?? "")"
            perms(a.permissions, owner: a.path); exts(a.extensions); starts(a.startupItems)
        }
        for u in s.unattributed { perms(u.permissions, owner: u.id) }
        for g in s.developerGroups { exts(g.extensions); starts(g.startupItems) }
        exts(s.unattributedExtensions); starts(s.unattributedStartup)
        return out
    }

    static func sig<V>(_ d: Determination<V>) -> String {
        switch d {
        case .confirmed(let v, _): "confirmed:\(v)"
        case .notRecorded: "notRecorded"
        case .recordedForDifferentSignature: "differentSignature"
        case .declared: "declared"
        case .inferred(let v, _, _): "inferred:\(v)"
        case .unknown(let r): "unknown:\(r.message)"
        }
    }
}
