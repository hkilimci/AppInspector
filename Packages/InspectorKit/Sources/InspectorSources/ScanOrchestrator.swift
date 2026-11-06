import Foundation
import Synchronization
import InspectorModel
import InspectorAssociation
import InspectorParsers
import InspectorPlatform

/// Where the Background Task Management data for a scan comes from.
public enum BTMSource: Sendable {
    /// Read the BTM database file as part of the scan (needs Full Disk Access; fast, no prompt).
    case liveRead
    /// Do not read BTM now: approval stays Unknown. Lets the UI show a fast first result.
    case skip
    /// A report obtained earlier: live (trusted for absence) or imported from a file (never proves absence).
    case report(BTMReport)
}

public struct ScanOrchestrator: Sendable {
    public var inventory: AppInventoryCollector
    public var tcc: TCCCollector
    public var matrix: CapabilityMatrix
    public var fdaProbe: @Sendable () -> AccessLevel
    public var osInfo: @Sendable () -> OSInfo
    public var csreqChecker: @Sendable (Data, URL) -> Bool?
    public var collectorTimeout: Duration
    /// Phase 2 collectors (extensions, startup items). Off in hermetic tests.
    public var phase2Enabled: Bool
    public var extensionsFactory: @Sendable (OSInfo) -> ExtensionCollector
    public var startupFactory: @Sendable (OSInfo, [String]) -> StartupCollector
    public var teamOfPath: @Sendable (String) -> String?
    public var btm: BTMCollector?

    public init(inventory: AppInventoryCollector = .init(),
                tcc: TCCCollector = .init(),
                matrix: CapabilityMatrix = .phase1,
                fdaProbe: @escaping @Sendable () -> AccessLevel = { AccessProbe.fullDiskAccess() },
                osInfo: @escaping @Sendable () -> OSInfo = { SystemInfo.current() },
                csreqChecker: @escaping @Sendable (Data, URL) -> Bool? = { CodeSigning.csreqMatches($0, appURL: $1) },
                collectorTimeout: Duration = .seconds(30),
                phase2Enabled: Bool = true,
                extensionsFactory: @escaping @Sendable (OSInfo) -> ExtensionCollector = { ExtensionCollector(os: $0) },
                startupFactory: @escaping @Sendable (OSInfo, [String]) -> StartupCollector = { StartupCollector(os: $0, appPaths: $1) },
                teamOfPath: (@Sendable (String) -> String?)? = nil,
                btm: BTMCollector? = BTMCollector()) {
        self.btm = btm
        self.phase2Enabled = phase2Enabled; self.extensionsFactory = extensionsFactory
        self.startupFactory = startupFactory
        let cache = inventory.signing
        self.teamOfPath = teamOfPath ?? { cache.teamID(ofPath: $0) }
        self.inventory = inventory; self.tcc = tcc; self.matrix = matrix
        self.fdaProbe = fdaProbe; self.osInfo = osInfo; self.csreqChecker = csreqChecker
        self.collectorTimeout = collectorTimeout
    }

    public func scan(btm source: BTMSource = .liveRead, importedFallback: BTMReport? = nil) async -> Snapshot {
        let os = osInfo()
        let fda = fdaProbe()

        async let inv = withTimeout(collectorTimeout) { await inventory.collect() }
        async let tccOut = withTimeout(collectorTimeout) { await tcc.collect(fda: fda) }
        let extFactory = extensionsFactory, startFactory = startupFactory, timeout = collectorTimeout
        let p2 = phase2Enabled
        async let extResult = withTimeout(timeout) { p2 ? await extFactory(os).collect() : ExtensionCollection(items: [], statuses: []) }
        let btmCollector = btm
        let liveRead: Bool = { if case .liveRead = source { return true } else { return false } }()
        async let btmLive = withTimeout(.seconds(180)) { p2 && liveRead ? await btmCollector?.collectLive() : nil }
        let invResult = await inv
        let appPathList = (invResult?.entries ?? []).map(\.app.path)
        // Live BTM read wins; an imported file is the fallback. Neither → approval stays Unknown.
        let live = await btmLive ?? nil
        var given: BTMReport?
        if case .report(let r) = source { given = r }
        let btmReport: BTMReport? = live?.report ?? given ?? importedFallback
        let btmStatus: SourceStatus? = {
            guard p2 else { return nil }
            if let l = live, l.report != nil { return l.status }
            if let imp = given ?? importedFallback {
                let age = Int(Date().timeIntervalSince(imp.importedAt) / 3600)
                return SourceStatus(id: .btm, state: imp.isComplete ? .ok : .formatUnrecognized("\(imp.skippedItems) items unreadable"),
                                    itemCount: imp.records.count, lastRun: imp.importedAt,
                                    note: (imp.isLiveRead ? "live read" : "imported file") + ", \(age) h old")
            }
            if case .skip = source { return SourceStatus(id: .btm, state: .needsImport, itemCount: 0, note: "not read yet") }
            return live?.status ?? SourceStatus(id: .btm, state: .needsImport, itemCount: 0, note: "Background Task Management database not read")
        }()
        async let startResult = withTimeout(timeout) { () -> StartupCollection in
            guard p2 else { return StartupCollection(items: [], statuses: []) }
            var c = startFactory(os, appPathList); c.btm = btmReport
            return await c.collect()
        }
        let (tccResult, extOut, startOut) = await (tccOut, extResult, startResult)

        var statuses: [SourceStatus] = []
        var entries: [InventoryEntry] = []
        if let (e, st) = invResult { entries = e; statuses.append(st) }
        else { statuses.append(SourceStatus(id: .appInventory, state: .timedOut, itemCount: 0)) }

        let tccOutput: TCCCollectorOutput
        if let t = tccResult { tccOutput = t; statuses += t.statuses }
        else {
            let r = UnknownReason.timedOut(.tccUser)
            tccOutput = TCCCollectorOutput(user: .unavailable(r, .timedOut), system: .unavailable(.timedOut(.tccSystem), .timedOut), statuses: [])
            statuses += [SourceStatus(id: .tccUser, state: .timedOut, itemCount: 0), SourceStatus(id: .tccSystem, state: .timedOut, itemCount: 0)]
        }

        let builder = PermissionBuilder(matrix: matrix, os: os, csreqChecker: csreqChecker)
        var (apps, unattributed) = attribute(entries: entries, tcc: tccOutput, builder: builder)

        var groups: [DeveloperGroup] = []
        var looseExt: [ExtensionItem] = [], looseStart: [StartupItem] = []
        if p2 {
            if let b = btmStatus { statuses.append(b) }
            if let e = extOut { statuses += e.statuses } else {
                statuses += [.pluginkit, .systemExtensionsCtl].map { SourceStatus(id: $0, state: .timedOut, itemCount: 0) }
            }
            if let st = startOut { statuses += st.statuses } else {
                statuses += [.launchctlDomain, .launchctlDisabled, .launchdPlists].map { SourceStatus(id: $0, state: .timedOut, itemCount: 0) }
            }
            let engine = AssociationEngine(
                apps: entries.map { AppIndexEntry(path: $0.app.path, name: $0.app.name, bundleID: $0.app.bundleID, teamID: $0.app.signing.teamID) },
                teamOfPath: teamOfPath)
            var appIndex: [String: Int] = [:]
            for (i, a) in apps.enumerated() { appIndex[a.path] = i }
            var groupIndex: [String: Int] = [:]
            func group(_ team: String) -> Int {
                if let i = groupIndex[team] { return i }
                groups.append(DeveloperGroup(teamID: team)); groupIndex[team] = groups.count - 1
                return groups.count - 1
            }
            for var item in extOut?.items ?? [] {
                item.association = engine.associate(item.signals)
                switch item.association.target {
                case .app(let p): if let i = appIndex[p] { apps[i].extensions.append(item) } else { looseExt.append(item) }
                case .developerGroup(let t): groups[group(t)].extensions.append(item)
                case .unattributed: looseExt.append(item)
                }
            }
            for var item in startOut?.items ?? [] {
                item.association = engine.associate(item.signals)
                switch item.association.target {
                case .app(let p): if let i = appIndex[p] { apps[i].startupItems.append(item) } else { looseStart.append(item) }
                case .developerGroup(let t): groups[group(t)].startupItems.append(item)
                case .unattributed: looseStart.append(item)
                }
            }
            groups.sort { $0.teamID < $1.teamID }
        }
        return Snapshot(apps: apps, unattributed: unattributed, sources: statuses, os: os, fullDiskAccess: fda,
                        developerGroups: groups, unattributedExtensions: looseExt, unattributedStartup: looseStart)
    }

    /// Phase 1 association: containment (path inside X.app) and bundle-ID match only.
    func attribute(entries: [InventoryEntry], tcc: TCCCollectorOutput, builder: PermissionBuilder)
        -> ([AppRecord], [UnattributedClient])
    {
        typealias Rows = [String: [(TCCRow, SourceID)]]
        var byApp: [String: Rows] = [:]          // app path → service → rows
        var loose: [String: (UnattributedClient.Kind, Rows)] = [:]

        var pathsByBundleID: [String: [String]] = [:]
        for e in entries { if let b = e.app.bundleID { pathsByBundleID[b, default: []].append(e.app.path) } }
        // Compare symlink-resolved paths (e.g. /var → /private/var); longest first so nested helpers win.
        func real(_ p: String) -> String { PathResolver.real(p) }
        var originalByReal: [String: String] = [:]
        for e in entries { originalByReal[real(e.app.path)] = e.app.path }
        let appPaths = originalByReal.keys.sorted { $0.count > $1.count }

        func add(_ row: TCCRow, _ src: SourceID) {
            if row.clientType == 0 {
                if let paths = pathsByBundleID[row.client] {
                    for p in paths { byApp[p, default: [:]][row.service, default: []].append((row, src)) }
                }
                else { loose["b:" + row.client, default: (.unresolvedBundleID, [:])].1[row.service, default: []].append((row, src)) }
            } else {
                let client = real(row.client)
                if let r = appPaths.first(where: { client.hasPrefix($0 + "/") || client == $0 }), let p = originalByReal[r] {
                    byApp[p, default: [:]][row.service, default: []].append((row, src))
                } else {
                    loose["p:" + row.client, default: (.commandLine, [:])].1[row.service, default: []].append((row, src))
                }
            }
        }
        for r in tcc.user.rows ?? [] { add(r, .tccUser) }
        for r in tcc.system.rows ?? [] { add(r, .tccSystem) }

        let apps: [AppRecord] = entries.map { e in
            var a = e.app
            a.permissions = builder.items(rowsByService: byApp[a.path] ?? [:], usage: e.usage,
                                          appURL: URL(fileURLWithPath: a.path), tcc: tcc)
            return a
        }
        let un: [UnattributedClient] = loose.map { key, v in
            UnattributedClient(kind: v.0, client: String(key.dropFirst(2)),
                               permissions: builder.items(rowsByService: v.1, usage: [:], appURL: nil, tcc: tcc))
        }.sorted { $0.client < $1.client }
        return (apps, un)
    }
}

/// Exactly one of completion, deadline, or caller cancellation resumes the waiter.
private final class TimeoutRace<T: Sendable>: Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<T?, Never>?
        var tasks: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let active = state.withLock { s in
            guard !s.finished else { return false }
            s.continuation = continuation
            return true
        }
        if !active { continuation.resume(returning: nil) }
        return active
    }

    func register(_ task: Task<Void, Never>) {
        let cancel = state.withLock { s in
            guard !s.finished else { return true }
            s.tasks.append(task)
            return false
        }
        if cancel { task.cancel() }
    }

    func finish(_ result: T?) {
        let pending = state.withLock { s -> (CheckedContinuation<T?, Never>?, [Task<Void, Never>])? in
            guard !s.finished else { return nil }
            s.finished = true
            let pending = (s.continuation, s.tasks)
            s.continuation = nil
            s.tasks = []
            return pending
        }
        guard let (continuation, tasks) = pending else { return }
        for task in tasks { task.cancel() }
        continuation?.resume(returning: result)
    }
}

/// Returns nil at the deadline or on caller cancellation, even if a collector is blocked in synchronous I/O.
/// The losing work is canceled; an in-flight OS call may finish later, but its result is discarded.
func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    let race = TimeoutRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard race.install(continuation) else { return }
            race.register(Task.detached {
                guard !Task.isCancelled else { return }
                race.finish(await body())
            })
            race.register(Task.detached {
                do { try await Task.sleep(for: limit) } catch { return }
                race.finish(nil)
            })
        }
    } onCancel: {
        race.finish(nil)
    }
}
