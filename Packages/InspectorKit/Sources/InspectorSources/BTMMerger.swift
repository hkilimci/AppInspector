import Foundation
import InspectorModel
import InspectorParsers

/// Matches Background Task Management records to startup items and turns them into `Determination`s.
/// Rules (fail to Unknown):
/// - a match gives a confirmed approval (evidence carries the report's own time and a stale flag);
/// - absence is "no record" only for a complete LIVE read, not older than the item itself;
/// - an imported file, an incomplete report or a stale report can never prove absence.
struct BTMMerger: Sendable {
    let report: BTMReport
    let matrix: CapabilityMatrix
    let os: OSInfo
    let now: Date
    let uid: Int
    let bootTime: Date?
    let pathExists: @Sendable (String) -> Bool
    let modifiedAt: @Sendable (String) -> Date?
    /// Symlink-resolved path per record (by UUID), computed once: resolving is a filesystem call.
    private let realPaths: [String: String]

    init(report: BTMReport, matrix: CapabilityMatrix, os: OSInfo, now: Date, uid: Int, bootTime: Date?,
         pathExists: @escaping @Sendable (String) -> Bool, modifiedAt: @escaping @Sendable (String) -> Date?) {
        self.report = report; self.matrix = matrix; self.os = os; self.now = now; self.uid = uid; self.bootTime = bootTime
        self.pathExists = pathExists; self.modifiedAt = modifiedAt
        var map: [String: String] = [:]
        let byIdentifier = Dictionary(report.records.map { ("\($0.uid)/\($0.identifier)", $0) }, uniquingKeysWith: { a, _ in a })
        for r in report.records {
            var p = r.absolutePath
            if p == nil, let rel = r.url, !rel.contains("://"), let pid = r.parentIdentifier,
               let base = byIdentifier["\(r.uid)/\(pid)"]?.absolutePath { p = base + "/" + rel }
            if let p { map[r.uuid] = PathResolver.real(p) }
        }
        self.realPaths = map
    }

    private static let startupKinds: Set<BTMKind> = [.loginItem, .agent, .daemon, .legacyAgent, .legacyDaemon]

    var isStale: Bool {
        if let boot = bootTime, report.importedAt < boot { return true }
        return !report.isLiveRead && now.timeIntervalSince(report.importedAt) > 24 * 3600
    }

    private func relevantUIDs(_ d: LaunchdDomain) -> Set<Int> { d == .gui ? [uid, -2] : [0, -2] }

    /// A GUI item can only be described by agent or login-item records; a system item only by daemon records.
    /// Without this a same-label daemon record would lend its approval to a GUI job.
    private func kinds(_ d: LaunchdDomain) -> Set<BTMKind> {
        d == .gui ? [.loginItem, .agent, .legacyAgent] : [.daemon, .legacyDaemon]
    }

    private func evidence(_ r: BTMRecord?, locator: String) -> Evidence {
        let src: SourceID = .btm
        let excerpt = r.map { "UID \($0.uid), type \($0.typeName) (0x\(String($0.typeCode, radix: 16))), identifier \($0.identifier)" }
        return Evidence(source: src, locator: locator, observedAt: report.importedAt, osBuild: os.build, excerpt: excerpt,
                        unvalidatedOS: matrix.capability(src)?.isUnvalidated(on: os.version) ?? true, staleSource: isStale)
    }

    /// Records that describe this item, filtered to the user, the launchd domain and the record kinds that can apply.
    /// A record whose own path is known and differs from the item's path never applies: BTM keeps records for removed
    /// items, and a lingering record for an old plist must not describe its replacement.
    func matches(for item: StartupItem) -> [BTMRecord] {
        let uids = relevantUIDs(item.domain), ks = kinds(item.domain)
        let pool = report.records.filter { ks.contains($0.kind) && uids.contains($0.uid) }
        let itemPath = (item.plistPath ?? item.signals.itemPath).map(PathResolver.real)
        /// nil = the record's path cannot be established; true/false = same/different path.
        func samePath(_ r: BTMRecord) -> Bool? {
            guard let rp = realPaths[r.uuid], let ip = itemPath else { return nil }
            return rp == ip
        }
        if itemPath != nil {
            let byPath = pool.filter { samePath($0) == true }
            if !byPath.isEmpty { return byPath }
        }
        return pool.filter { $0.label == item.label && samePath($0) != false }
    }

    func approval(for item: StartupItem) -> Determination<BackgroundApproval> {
        let hits = matches(for: item)
        if !hits.isEmpty {
            guard let token = matrix.confirmedSource(for: .btm, item: .startup, key: item.label, os: os.version) else {
                return .unknown(.notInspectable("BTM is not authoritative for this item"))
            }
            let dispositions = Set(hits.map { $0.disposition.map { "\($0.enabled)/\($0.allowed)/\($0.notified)" } ?? "?" })
            guard dispositions.count == 1, let first = hits.first, let d = first.disposition else {
                return .unknown(dispositions.contains("?") ? .formatUnrecognized(.btm, "disposition not understood")
                                                           : .notInspectable("several BTM records disagree for \(item.label)"))
            }
            return .confirmed(BackgroundApproval.from(enabled: d.enabled, allowed: d.allowed, notified: d.notified, token: token),
                              evidence(first, locator: "sfltool dumpbtm: \(first.identifier)"))
        }
        // No record. Only a complete, live, non-stale read that is not older than the item may say so.
        guard report.isLiveRead else { return .unknown(.notInspectable("an imported report cannot prove that no record exists")) }
        guard report.isComplete else { return .unknown(.formatUnrecognized(.btm, "\(report.skippedItems) unreadable items")) }
        guard !isStale else { return .unknown(.notInspectable("the BTM report predates the last boot")) }
        // Freshness must be provable from a file the item owns; otherwise a cached report could not know the item is newer.
        let paths = [item.plistPath, item.signals.itemPath, item.program, item.signals.executablePath]
            .compactMap { $0 }.filter { $0.hasPrefix("/") }
        let dates = paths.compactMap(modifiedAt)
        guard !dates.isEmpty else { return .unknown(.notInspectable("cannot tell whether this item is newer than the BTM report")) }
        if dates.contains(where: { $0 > report.importedAt }) {
            return .unknown(.notInspectable("the item changed after the BTM report was read"))
        }
        guard matrix.absenceMeaningful(source: .btm, item: .startup, key: item.label) else {
            return .unknown(.notInspectable("absence in BTM is not meaningful"))
        }
        return .notRecorded(evidence(nil, locator: "sfltool dumpbtm: no record for \(item.label)"))
    }

    // MARK: BTM-only items

    func parent(of r: BTMRecord) -> BTMRecord? {
        guard let pid = r.parentIdentifier else { return nil }
        return report.records.first { $0.uid == r.uid && $0.identifier == pid }
    }

    func parentBundleID(_ r: BTMRecord) -> String? {
        guard let p = parent(of: r) else { return nil }
        return p.bundleIdentifier ?? p.label
    }

    /// Absolute path of the item: its own file URL, or a relative URL resolved against its parent app.
    func resolvedPath(_ r: BTMRecord) -> String? {
        if let p = r.absolutePath { return p }
        guard let rel = r.url, !rel.contains("://"), let base = parent(of: r)?.absolutePath else { return nil }
        return base + "/" + rel
    }

    /// Startup-kind records no existing item accounts for, and whose file still exists (removed items linger in BTM).
    func startupRecordsMissing(from known: Set<String>, items: [StartupItem]) -> [BTMRecord] {
        let paths = Set(items.compactMap(\.plistPath))
        return report.records.filter { r in
            guard Self.startupKinds.contains(r.kind), r.uid == uid || r.uid == -2 || r.uid == 0 else { return false }
            if r.kind == .loginItem || r.kind == .agent || r.kind == .daemon || r.kind == .legacyAgent || r.kind == .legacyDaemon {
                let d: LaunchdDomain = (r.kind == .daemon || r.kind == .legacyDaemon) ? .system : .gui
                if known.contains("\(d)/\(r.label)") { return false }
            }
            let path = resolvedPath(r)
            if let path, paths.contains(path) { return false }
            guard let path else { return false }          // cannot tell whether it still exists: do not list it
            return pathExists(path)
        }
    }
}
