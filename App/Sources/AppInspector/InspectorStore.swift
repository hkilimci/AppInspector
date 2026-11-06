import Foundation
import Observation
import AppKit
import InspectorModel
import InspectorParsers
import InspectorPlatform
import InspectorSources

enum Selection: Hashable {
    case app(String)
    case unattributed(String)
    case group(String)
    case looseItems
}

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All", hasGrants = "Has grants", needsAttention = "Needs attention", hasUnknowns = "Has unknowns", new = "New since last scan"
    case notInstalled = "Not installed"
    var id: String { rawValue }
}

/// A reset the user asked for and still has to confirm.
struct PendingReset: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let requests: [TCCResetRequest]
}

/// What a reset did, checked against a fresh scan rather than tccutil's exit status alone.
struct ResetReport: Identifiable {
    let id = UUID()
    let title: String
    let lines: [String]
    /// Requests whose entries are still recorded after both passes.
    let remaining: [TCCResetRequest]
}

@Observable @MainActor
final class InspectorStore {
    var snapshot: Snapshot? { didSet { refreshStaleBundles() } }
    var isScanning = false
    var search = ""
    var showApple = false
    var filter: AppFilter = .all
    var selection: Selection?

    // MARK: scanning

    /// One orchestrator for the app's lifetime: its signing cache makes rescans fast.
    private let orchestrator = ScanOrchestrator()
    /// Items that appeared or changed since the previous scan (in memory only).
    var diff: SnapshotDiff = .empty
    /// Result of the `sfltool` fallback; used only while the database itself can't be read.
    var sfltoolBTM: BTMReport?
    /// Report from a file the user chose; fallback when a live read is unavailable.
    var importedBTM: BTMReport?
    var isReadingBTM = false
    var lastBTMError: String?
    private var monitor: RefreshMonitor?
    private var refreshPending = false

    /// Every scan reads the BTM database directly (Full Disk Access, no prompt), in parallel with the other sources.
    func rescan() async {
        guard !isScanning else { refreshPending = true; return }
        isScanning = true
        refreshPending = false
        let snap = await orchestrator.scan(btm: .liveRead, importedFallback: sfltoolBTM ?? importedBTM)
        publish(snap, computeDiff: true)
        isScanning = false
        if refreshPending { refreshPending = false; await rescan() }
    }

    private func publish(_ snap: Snapshot, computeDiff: Bool) {
        if computeDiff { diff = SnapshotDiff.between(snapshot, snap) }
        snapshot = snap
    }

    /// Fallback for when the database layout isn't recognized (e.g. a new macOS release): `sfltool dumpbtm`,
    /// which macOS guards with an administrator authorization dialog on every run. Only on explicit request.
    func readBTMWithSfltool() async {
        guard !isReadingBTM else { return }
        isReadingBTM = true
        defer { isReadingBTM = false }
        let result = await BTMCollector().collectLive(allowPrompt: true)
        guard let report = result.report else { lastBTMError = result.status.note; return }
        lastBTMError = nil
        sfltoolBTM = report
        let snap = await orchestrator.scan(btm: .liveRead, importedFallback: report)
        publish(snap, computeDiff: false)
    }

    func importBTM(from url: URL) async {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let r = BTMCollector.importReport(text: text, modified: modified)
            guard let report = r.report else { lastBTMError = "That file is not a `sfltool dumpbtm` report (\(r.status.state))."; return }
            lastBTMError = nil
            importedBTM = report
            let snap = await orchestrator.scan(btm: .liveRead, importedFallback: sfltoolBTM ?? report)
            publish(snap, computeDiff: false)
        } catch {
            lastBTMError = "Could not read the file: \(error.localizedDescription)"
        }
    }

    // MARK: live refresh

    /// FSEvents on the folders that change the scan, plus app launch/quit; debounced, and only while the app is active.
    func startLiveRefresh() {
        guard monitor == nil else { return }
        monitor = RefreshMonitor { [weak self] in
            guard let self else { return }
            if NSApp.isActive { await self.rescan() } else { self.refreshPending = true }
        } onActivate: { [weak self] in
            guard let self, self.refreshPending else { return }
            await self.rescan()
        }
    }

    // MARK: "new since last scan"

    func isNew(_ id: String) -> Bool { diff.newIDs.contains(id) }
    func isChanged(_ id: String) -> Bool { diff.changedIDs.contains(id) }

    func appHasNews(_ app: AppRecord) -> Bool {
        if diff.isEmpty { return false }
        if diff.newIDs.contains(SnapshotDiff.appID(app.path)) { return true }
        let ids = app.permissions.map { SnapshotDiff.permissionID(owner: app.path, itemID: $0.id) }
            + app.extensions.map { SnapshotDiff.extensionID($0.id) } + app.startupItems.map { SnapshotDiff.startupID($0.id) }
        return ids.contains { diff.newIDs.contains($0) || diff.changedIDs.contains($0) }
    }

    // MARK: export

    func exportJSON(redaction: ExportRedaction) {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "app-inspector-\(redaction == .paths ? "redacted" : "full").json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SnapshotExporter.json(snapshot, redaction: redaction).write(to: url, options: .atomic) }
        catch { lastBTMError = "Export failed: \(error.localizedDescription)" }
    }

    var visibleApps: [AppRecord] {
        guard let s = snapshot, filter != .notInstalled else { return [] }
        return s.apps.filter { app in
            (showApple || !app.isApple)
            && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
                || (app.bundleID?.localizedCaseInsensitiveContains(search) ?? false))
            && matches(app.permissions)
            && (filter != .new || appHasNews(app))
        }
    }

    var visibleUnattributed: [UnattributedClient] {
        guard let s = snapshot else { return [] }
        return s.unattributed.filter { c in
            (showApple || !c.client.hasPrefix("com.apple."))
            && (search.isEmpty || c.client.localizedCaseInsensitiveContains(search))
            && matches(c.permissions)
            && (filter != .notInstalled || isStale(c))
        }
    }

    private func matches(_ items: [PermissionItem]) -> Bool {
        switch filter {
        case .all: true
        case .hasGrants: items.contains { if case .confirmed(let s, _) = $0.state { s.kind == .allowed || s.kind == .limited } else { false } }
        case .needsAttention: items.contains {
            if case .confirmed(let s, _) = $0.state, s.kind == .denied { return true }
            if case .confirmed(false, _)? = $0.signatureMatch { return true }
            return false
        }
        case .hasUnknowns: items.contains { $0.state.isUnknown }
        case .new: true      // applied per app in visibleApps
        case .notInstalled: true  // applied per client in visibleUnattributed
        }
    }

    private func isApple(_ id: String) -> Bool { id.hasPrefix("com.apple.") }

    var visibleGroups: [DeveloperGroup] {
        guard let s = snapshot else { return [] }
        return s.developerGroups.filter {
            search.isEmpty || $0.teamID.localizedCaseInsensitiveContains(search)
                || $0.extensions.contains { $0.name.localizedCaseInsensitiveContains(search) }
                || $0.startupItems.contains { $0.label.localizedCaseInsensitiveContains(search) }
        }
    }
    /// Unattributed extensions and startup items; Apple's are hidden unless "Apple apps" is on.
    var looseExtensions: [ExtensionItem] {
        (snapshot?.unattributedExtensions ?? []).filter { (showApple || !isApple($0.identifier)) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search)) }
    }
    var looseStartup: [StartupItem] {
        (snapshot?.unattributedStartup ?? []).filter { (showApple || !isApple($0.label)) && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)) }
    }
    func group(for sel: Selection) -> DeveloperGroup? {
        guard case .group(let t) = sel else { return nil }
        return snapshot?.developerGroups.first { $0.teamID == t }
    }

    func app(for sel: Selection) -> AppRecord? {
        guard case .app(let p) = sel else { return nil }
        return snapshot?.apps.first { $0.path == p }
    }
    func unattributed(for sel: Selection) -> UnattributedClient? {
        guard case .unattributed(let id) = sel else { return nil }
        return snapshot?.unattributed.first { $0.id == id }
    }

    // MARK: privacy reset (the one mutation, plan §1)

    /// Bundle IDs with TCC entries that Launch Services cannot find on this Mac. System Settings hides these rows.
    private(set) var staleBundleIDs: Set<String> = []
    var pendingReset: PendingReset?
    var resetReport: ResetReport?
    var isResetting = false

    /// Looked up once per snapshot: Launch Services queries are too slow to repeat on every redraw.
    private func refreshStaleBundles() {
        let ids = (snapshot?.unattributed ?? []).filter { $0.kind == .unresolvedBundleID }.map(\.client)
        staleBundleIDs = Set(ids.filter { !TCCReset.isResolvable($0) })
    }

    func isStale(_ c: UnattributedClient) -> Bool { c.kind == .unresolvedBundleID && staleBundleIDs.contains(c.client) }

    /// Stale clients a bulk reset may touch. Apple's are left out: an unresolvable `com.apple.*` ID is usually
    /// a system component, not a leftover.
    var staleClients: [UnattributedClient] {
        (snapshot?.unattributed ?? []).filter { isStale($0) && !isApple($0.client) && TCCReset.isValidBundleID($0.client) }
    }

    /// One request per recorded service; a client with no TCC rows yields nothing.
    func resetRequests(for c: UnattributedClient, service: String? = nil) -> [TCCResetRequest] {
        guard c.kind == .unresolvedBundleID, TCCReset.isValidBundleID(c.client) else { return [] }
        let services = Set(c.permissions.filter(hasTCCRow).map(\.service.raw))
        if let service { return services.contains(service) ? [TCCResetRequest(service: service, bundleID: c.client)] : [] }
        return services.sorted().map { TCCResetRequest(service: $0, bundleID: c.client) }
    }

    func requestReset(of c: UnattributedClient, service: String? = nil) {
        let reqs = resetRequests(for: c, service: service)
        guard !reqs.isEmpty else { return }
        let what = service.map { "the \(ServiceCatalog.info(for: $0).displayName) decision" } ?? "all \(reqs.count) privacy decisions"
        pendingReset = PendingReset(title: "Reset \(what) for \(c.client)?", message: resetMessage(for: reqs), requests: reqs)
    }

    func requestResetAllStale() {
        let reqs = staleClients.flatMap { resetRequests(for: $0) }
        guard !reqs.isEmpty else { return }
        let bundles = Set(reqs.map(\.bundleID)).count
        pendingReset = PendingReset(title: "Reset \(reqs.count) privacy decisions for \(bundles) apps that are not installed?",
                                    message: resetMessage(for: reqs), requests: reqs)
    }

    private func resetMessage(for reqs: [TCCResetRequest]) -> String {
        "If the app is installed again, it will ask for these permissions again. Entries stored in the system database "
            + "need administrator rights; macOS will ask for your password only if there are any."
    }

    private var tccVerifiable: Bool {
        [SourceID.tccUser, .tccSystem].allSatisfy { id in snapshot?.sources.contains { $0.id == id && $0.state == .ok } ?? false }
    }

    /// Resets as the user first. Whatever survives (system-database entries) is retried as root behind the
    /// standard administrator dialog. Every outcome is checked against a fresh scan.
    func performReset(_ reqs: [TCCResetRequest]) async {
        guard !isResetting, !reqs.isEmpty else { return }
        isResetting = true
        defer { isResetting = false }
        let stale = staleBundleIDs
        let outcomes = await TCCReset.perform(reqs, stale: stale)
        await scanForResult()

        let runnable = reqs.filter { if case .refused? = outcomes[$0] { false } else { true } }
        let survivors = tccVerifiable
            ? runnable.filter { stillRecorded($0) != nil }
            : runnable.filter { if case .failed? = outcomes[$0] { true } else { false } }
        var adminProblem: String?
        var adminRan = false
        if !survivors.isEmpty {
            switch await TCCReset.performAsAdministrator(survivors, stale: stale) {
            case .ran: adminRan = true; await scanForResult()
            case .cancelled: adminProblem = "administrator authorization cancelled"
            case .failed(let why): adminProblem = why
            }
        }

        let verifiable = tccVerifiable
        var lines: [String] = []
        var remaining: [TCCResetRequest] = []
        for r in reqs.sorted(by: { ($0.bundleID, $0.tccutilService) < ($1.bundleID, $1.tccutilService) }) {
            let name = "\(r.bundleID): \(r.service.map { ServiceCatalog.info(for: $0).displayName } ?? "All")"
            if case .refused(let why)? = outcomes[r] { lines.append("\(name): not run (\(why))"); continue }
            if verifiable {
                if let db = stillRecorded(r) {
                    remaining.append(r)
                    lines.append("\(name): still in the \(db) database" + (adminProblem.map { " (\($0))" } ?? ""))
                } else { lines.append("\(name): cleared") }
            } else if case .failed(let why)? = outcomes[r], !adminRan {
                remaining.append(r)
                lines.append("\(name): failed (\(adminProblem ?? why))")
            } else {
                lines.append("\(name): reset; not checked, because the privacy databases are unreadable")
            }
        }
        let cleared = lines.filter { $0.hasSuffix(": cleared") }.count
        let title = remaining.isEmpty
            ? (verifiable ? "Cleared \(cleared) of \(reqs.count) permissions" : "Reset finished")
            : "\(remaining.count) of \(reqs.count) permissions could not be cleared"
        resetReport = ResetReport(title: title, lines: lines, remaining: remaining)
    }

    /// "system" / "user" when a TCC row for the request survives in the fresh snapshot.
    private func stillRecorded(_ r: TCCResetRequest) -> String? {
        let items = (snapshot?.unattributed.filter { $0.kind == .unresolvedBundleID && $0.client == r.bundleID }.flatMap(\.permissions) ?? [])
            + (snapshot?.apps.filter { $0.bundleID == r.bundleID }.flatMap(\.permissions) ?? [])
        let hit = items.first { hasTCCRow($0) && (r.service == nil || $0.service.raw == r.service) }
        return hit.map { $0.recordedIn.contains(.tccSystem) ? "system" : "user" }
    }

    /// A TCC row exists, even one whose value App Inspector can't decode (shown as Unknown): it can still be reset.
    private func hasTCCRow(_ item: PermissionItem) -> Bool {
        item.recordedIn.contains(.tccUser) || item.recordedIn.contains(.tccSystem)
    }

    /// A scan the caller waits on: never coalesced into a running one.
    private func scanForResult() async {
        while isScanning { try? await Task.sleep(for: .milliseconds(150)) }
        isScanning = true
        let snap = await orchestrator.scan(btm: .liveRead, importedFallback: sfltoolBTM ?? importedBTM)
        publish(snap, computeDiff: true)
        isScanning = false
    }
}
