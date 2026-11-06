import SwiftUI
import AppKit
import InspectorModel
import InspectorPlatform

// MARK: - Chips (UI vocabulary from plan §4.5)

struct ChipSpec {
    enum Look { case solid(Color), outline(Color), dotted(Color), dashed }
    let text: String
    let icon: String
    let look: Look
    let a11y: String
}

func chipSpec(for d: Determination<PermissionState>) -> ChipSpec {
    switch d {
    case .confirmed(let s, _):
        let by = s.managed ? " by configuration profile" : ""
        switch s.kind {
        case .allowed:
            return s.managed ? .init(text: "Allowed by profile", icon: "person.badge.shield.checkmark", look: .solid(.purple), a11y: "Confirmed: allowed\(by)")
                             : .init(text: "Allowed", icon: "checkmark.circle.fill", look: .solid(.green), a11y: "Confirmed: allowed")
        case .limited:
            return .init(text: "Limited", icon: "checkmark.circle", look: .solid(s.managed ? .purple : .green), a11y: "Confirmed: limited access\(by)")
        case .ask:
            return .init(text: "Will ask", icon: "questionmark.bubble", look: .solid(.gray), a11y: "Confirmed: will ask on next use")
        case .denied:
            if s.managed {
                return .init(text: "Denied by profile", icon: "person.badge.shield.checkmark", look: .solid(.purple), a11y: "Confirmed: denied by configuration profile")
            }
            let text: String
            if s.authReason == 2 || s.authReason == 3 { text = "Denied by user" }
            else if let reason = s.reasonDescription { text = "Denied: \(reason)" }
            else { text = "Denied" }
            return .init(text: text, icon: "xmark.circle.fill", look: .solid(.orange), a11y: "Confirmed: \(text)")
        }
    case .notRecorded:
        return .init(text: "Not requested", icon: "circle", look: .outline(.secondary), a11y: "Confirmed: no record")
    case .recordedForDifferentSignature:
        return .init(text: "Different signature", icon: "signature", look: .outline(.secondary),
                     a11y: "Recorded for a different signature. Authorization of the installed copy is unknown")
    case .declared:
        return .init(text: "Declared", icon: "doc.text", look: .outline(.blue), a11y: "Declared by the app, not a granted state")
    case .inferred(_, _, let why):
        return .init(text: "Probably", icon: "sparkles", look: .dotted(.secondary), a11y: "Inferred, not confirmed: \(why)")
    case .unknown(let r):
        return .init(text: "Unknown", icon: r == .needsFullDiskAccess ? "lock" : "questionmark", look: .dashed,
                     a11y: "Unknown. \(r.message)")
    }
}

struct Chip: View {
    let spec: ChipSpec
    var body: some View {
        Label(spec.text, systemImage: spec.icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
            .overlay(stroke)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spec.a11y)
    }
    private var fg: Color {
        switch spec.look {
        case .solid: .white
        case .outline(let c), .dotted(let c): c
        case .dashed: .secondary
        }
    }
    private var bg: Color { if case .solid(let c) = spec.look { c } else { .clear } }
    @ViewBuilder private var stroke: some View {
        switch spec.look {
        case .solid: EmptyView()
        case .outline(let c): Capsule().strokeBorder(c, lineWidth: 1)
        case .dotted(let c): Capsule().strokeBorder(c, style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
        case .dashed: Capsule().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @Environment(InspectorStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                CoverageBanner()
                BTMBanner()
                if let sel = store.selection, let app = store.app(for: sel) {
                    AppDetail(app: app, sources: store.snapshot?.sources ?? [])
                } else if let sel = store.selection, let c = store.unattributed(for: sel) {
                    ClientDetail(client: c, sources: store.snapshot?.sources ?? [])
                } else if let sel = store.selection, let g = store.group(for: sel) {
                    GroupDetail(group: g, sources: store.snapshot?.sources ?? [])
                } else if store.selection == .looseItems {
                    LooseItemsDetail(extensions: store.looseExtensions, startup: store.looseStartup, sources: store.snapshot?.sources ?? [])
                } else {
                    ContentUnavailableView("Select an app", systemImage: "app.dashed",
                                           description: Text("Privacy permissions, with the source for every state."))
                }
            }
        }
        .searchable(text: $store.search, prompt: "Search apps")
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $store.filter) {
                    ForEach(AppFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            ToolbarItem {
                // The toolbar's glass capsule hugs its content; pad so the checkbox doesn't touch the edges.
                Toggle("Apple apps", isOn: $store.showApple).toggleStyle(.checkbox)
                    .fixedSize()
                    .padding(.horizontal, 10)
            }
            ToolbarItem {
                Menu {
                    Button("Export JSON, paths redacted…") { store.exportJSON(redaction: .paths) }
                    Button("Export JSON, full paths…") { store.exportJSON(redaction: .none) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(store.snapshot == nil)
            }
            ToolbarItem {
                let stale = store.staleClients
                let reqs = stale.flatMap { store.resetRequests(for: $0) }
                Menu {
                    Button("Show Apps That Are Not Installed (\(stale.count))") { store.filter = .notInstalled }
                    Divider()
                    Button("Reset All \(reqs.count) Leftover Permissions…", role: .destructive) { store.requestResetAllStale() }
                        .disabled(reqs.isEmpty || store.isResetting)
                } label: { Label("Leftover permissions", systemImage: "eraser") }
                .help("Privacy entries for apps that are no longer installed")
                .disabled(store.snapshot == nil)
            }
            ToolbarItem {
                Button { openWindow(id: "about-data") } label: { Label("About this data", systemImage: "info.circle") }
            }
            ToolbarItem {
                Button { openWindow(id: "diagnostics") } label: { Label("Diagnostics", systemImage: "stethoscope") }
            }
            ToolbarItem {
                Button { Task { await store.rescan() } } label: {
                    if store.isScanning { ProgressView().controlSize(.small) } else { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                .disabled(store.isScanning)
            }
        }
        .confirmationDialog(store.pendingReset?.title ?? "",
                            isPresented: Binding(get: { store.pendingReset != nil }, set: { if !$0 { store.pendingReset = nil } }),
                            titleVisibility: .visible, presenting: store.pendingReset) { p in
            Button("Reset", role: .destructive) { Task { await store.performReset(p.requests) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text(p.message) }
        .alert(store.resetReport?.title ?? "",
               isPresented: Binding(get: { store.resetReport != nil }, set: { if !$0 { store.resetReport = nil } }),
               presenting: store.resetReport) { _ in
            Button("OK", role: .cancel) {}
        } message: { r in
            let shown = r.lines.prefix(12).joined(separator: "\n")
            let more = r.lines.count > 12 ? "\n…and \(r.lines.count - 12) more" : ""
            Text(shown + more)
        }
    }
}

struct Sidebar: View {
    @Environment(InspectorStore.self) private var store
    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("Applications (\(store.visibleApps.count))") {
                ForEach(store.visibleApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                        Text(app.name).lineLimit(1)
                        if store.appHasNews(app) { NewBadge(changed: false) }
                        Spacer()
                        if !app.extensions.isEmpty { CountBadge(symbol: "puzzlepiece.extension", count: app.extensions.count, label: "extensions") }
                        if !app.startupItems.isEmpty { CountBadge(symbol: "bolt.horizontal.circle", count: app.startupItems.count, label: "startup items") }
                        SidebarBadges(items: app.permissions)
                    }
                    .tag(Selection.app(app.path))
                }
            }
            if !store.visibleUnattributed.isEmpty {
                Section("Unattributed items") {
                    ForEach(store.visibleUnattributed) { c in
                        let stale = store.isStale(c)
                        HStack {
                            Image(systemName: c.kind == .commandLine ? "terminal" : stale ? "xmark.app" : "questionmark.app").frame(width: 24)
                            Text(c.kind == .commandLine ? (c.client as NSString).lastPathComponent : c.client).lineLimit(1)
                            Spacer()
                            SidebarBadges(items: c.permissions)
                        }
                        .help(stale ? "\(c.client): not installed on this Mac" : c.client)
                        .tag(Selection.unattributed(c.id))
                    }
                }
            }
            if store.filter == .notInstalled && store.visibleUnattributed.isEmpty && store.snapshot != nil {
                Text("No privacy entries for apps that are not installed.").foregroundStyle(.secondary)
            }
            if store.filter != .notInstalled && !store.visibleGroups.isEmpty {
                Section("Developer groups") {
                    ForEach(store.visibleGroups) { g in
                        HStack {
                            Image(systemName: "building.2").frame(width: 24)
                            Text(g.teamID).font(.body.monospaced()).lineLimit(1)
                            Spacer()
                            CountBadge(symbol: "puzzlepiece.extension", count: g.extensions.count, label: "extensions")
                            CountBadge(symbol: "bolt.horizontal.circle", count: g.startupItems.count, label: "startup items")
                        }
                        .tag(Selection.group(g.teamID))
                    }
                }
            }
            if store.filter != .notInstalled && (!store.looseExtensions.isEmpty || !store.looseStartup.isEmpty) {
                Section("Other") {
                    HStack {
                        Image(systemName: "questionmark.folder").frame(width: 24)
                        Text("Unattributed extensions & startup")
                        Spacer()
                        CountBadge(symbol: "puzzlepiece.extension", count: store.looseExtensions.count, label: "extensions")
                        CountBadge(symbol: "bolt.horizontal.circle", count: store.looseStartup.count, label: "startup items")
                    }
                    .tag(Selection.looseItems)
                }
            }
        }
        .overlay {
            if store.snapshot == nil { ProgressView("Scanning…") }
        }
    }
}

struct CountBadge: View {
    let symbol: String, count: Int, label: String
    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: symbol).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon).accessibilityLabel("\(count) \(label)")
        }
    }
}

struct SidebarBadges: View {
    let items: [PermissionItem]
    var body: some View {
        let allowed = items.filter { if case .confirmed(let s, _) = $0.state { s.kind == .allowed || s.kind == .limited } else { false } }.count
        let unknown = items.contains { $0.state.isUnknown }
        HStack(spacing: 4) {
            if allowed > 0 {
                Text("\(allowed)").font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1).foregroundStyle(.white)
                    .background(.green, in: Capsule())
                    .accessibilityLabel("\(allowed) allowed permissions")
            }
            if unknown {
                Text("?").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .overlay(Capsule().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .accessibilityLabel("Some permissions unknown")
            }
        }
    }
}

// MARK: - Coverage banner

struct CoverageBanner: View {
    @Environment(InspectorStore.self) private var store
    var body: some View {
        if let s = store.snapshot, s.fullDiskAccess != .granted {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.fullDiskAccess == .notGranted ? "Privacy data unavailable: grant Full Disk Access" : "Full Disk Access could not be confirmed")
                        .font(.callout.weight(.semibold))
                    Text("Granted, denied and revoked states stay Unknown until Full Disk Access lets this app read the privacy database. Nothing is changed or sent anywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                    if case .indeterminate(let why) = s.fullDiskAccess { Text(why).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Open Settings") { SystemSettingsLinker.openFullDiskAccess() }
                Button("Re-scan") { Task { await store.rescan() } }
            }
            .padding(10)
            .background(.yellow.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

// MARK: - Detail

struct AppDetail: View {
    let app: AppRecord
    let sources: [SourceStatus]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(app.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                        SigningLine(signing: app.signing)
                    }
                }
                PrivacySection(items: app.permissions, sources: sources)
                Divider()
                ExtensionsSection(items: app.extensions, sources: sources)
                Divider()
                StartupSection(items: app.startupItems, sources: sources)
            }
            .padding(20)
        }
    }
}

struct ClientDetail: View {
    @Environment(InspectorStore.self) private var store
    let client: UnattributedClient
    let sources: [SourceStatus]
    var body: some View {
        let all = store.resetRequests(for: client)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title3.weight(.semibold))
                Text(client.client).font(.callout.monospaced()).textSelection(.enabled)
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !all.isEmpty {
                    HStack {
                        Button("Reset All Permissions…", role: .destructive) { store.requestReset(of: client) }
                            .disabled(store.isResetting)
                        if store.isResetting { ProgressView().controlSize(.small) }
                    }
                }
                PrivacySection(items: client.permissions, sources: sources) { item in
                    guard !store.resetRequests(for: client, service: item.service.raw).isEmpty else { return nil }
                    return { store.requestReset(of: client, service: item.service.raw) }
                }
            }.padding(20)
        }
    }

    private var title: String {
        switch client.kind {
        case .commandLine: "Command-line tool"
        case .unresolvedBundleID: store.isStale(client) ? "Bundle not found on this Mac" : "Not in the app list"
        }
    }

    private var note: String {
        switch client.kind {
        case .commandLine:
            return "macOS can only reset entries recorded by bundle ID, so this entry for a command-line tool can't be reset here."
        case .unresolvedBundleID where store.isStale(client):
            return "macOS can't find an app with this bundle ID, so System Settings doesn't list these entries and they can't be removed there. App Inspector can reset them."
        case .unresolvedBundleID:
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client.client)?.path ?? "an unscanned location"
            return "macOS finds this bundle at \(path), outside the scanned app folders."
        }
    }
}


struct SigningLine: View {
    let signing: SigningSummary
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "signature")
            Text(label)
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var label: String {
        let kind: String = switch signing.kind {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: "Developer ID"
        case .adHoc: "Ad hoc signed"
        case .unsigned: "Unsigned"
        case .unknown(let why): "Signature: \(why)"
        }
        return [kind, signing.teamID.map { "Team \($0)" }, signing.hardenedRuntime == true ? "Hardened runtime" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct PrivacySection: View {
    let items: [PermissionItem]
    let sources: [SourceStatus]
    /// Reset action for a row; nil hides the button.
    var rowReset: (PermissionItem) -> (() -> Void)? = { _ in nil }
    @State private var evidence: EvidenceSheetItem?

    var emptyMessage: String {
        let complete = [SourceID.tccUser, .tccSystem].allSatisfy { id in
            sources.contains { $0.id == id && $0.state == .ok }
        }
        return complete ? "No privacy permissions recorded or declared for this item."
                        : "Privacy permissions are Unknown because the privacy databases could not be read completely."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privacy & Security", systemImage: "hand.raised").font(.headline)
            if items.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                PermissionRow(item: item, reset: rowReset(item)) { evidence = EvidenceSheetItem(item: item) }
                Divider()
            }
        }
        .sheet(item: $evidence) { EvidenceSheet(item: $0.item) }
    }
}

struct EvidenceSheetItem: Identifiable { let id = UUID(); let item: PermissionItem }

struct PermissionRow: View {
    let item: PermissionItem
    var reset: (() -> Void)? = nil
    let showEvidence: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.body.weight(.medium))
                if let d = item.declared {
                    Label(d.excerpt.map { "Declares use: “\($0)”" } ?? "Declares use (Info.plist)", systemImage: "doc.text")
                        .font(.caption).foregroundStyle(.blue)
                }
                if case .unknown(let r) = item.state { Text(r.message).font(.caption).foregroundStyle(.secondary) }
                if let t = item.lastModified {
                    Text("Changed \(t.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
                if case .confirmed(false, _)? = item.signatureMatch {
                    Label("Recorded for a different signature (stale grant or another copy)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if item.state.evidence?.unvalidatedOS == true {
                    Text("Unvalidated on this macOS build").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action: showEvidence) { Chip(spec: chipSpec(for: item.state)) }
                .buttonStyle(.plain).help("Show evidence")
            Button { SystemSettingsLinker.openPrivacy(anchor: item.service.settingsAnchor) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless).help("Open in System Settings")
            .accessibilityLabel("Open \(item.displayName) in System Settings")
            if let reset {
                Button(action: reset) { Image(systemName: "arrow.counterclockwise.circle") }
                    .buttonStyle(.borderless)
                    .help(item.indirectObject == nil ? "Reset this permission"
                          : "Reset \(item.service.displayName) for every target app")
                    .accessibilityLabel("Reset \(item.displayName)")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Evidence sheet

struct EvidenceSheet: View {
    let item: PermissionItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence: \(item.displayName)").font(.title3.weight(.semibold))
            Chip(spec: chipSpec(for: item.state))
            Group {
                switch item.state {
                case .unknown(let r): Text(r.message)
                case .inferred(_, _, let why): Text("Inferred (not a fact): \(why)")
                default: EmptyView()
                }
            }.font(.callout)
            if let e = item.state.evidence { EvidenceBlock(title: "State", e: e) }
            if let e = item.declared { EvidenceBlock(title: "Declared usage", e: e) }
            if let m = item.signatureMatch {
                switch m {
                case .confirmed(let ok, let e): EvidenceBlock(title: ok ? "Signature matches installed copy" : "Signature differs from installed copy", e: e)
                case .unknown(let r): Text("Signature check: \(r.message)").font(.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }
}

struct EvidenceBlock: View {
    let title: String
    let e: Evidence
    var body: some View {
        GroupBox(title) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Source", e.source.rawValue)
                row("Locator", e.locator)
                row("Observed", e.observedAt.formatted(date: .abbreviated, time: .standard))
                row("macOS build", e.osBuild + (e.unvalidatedOS ? " (unvalidated)" : ""))
                if let x = e.excerpt { row("Excerpt", x) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @Environment(InspectorStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = store.snapshot {
                Text("macOS \(s.os.version) (\(s.os.build)) · scanned \(s.createdAt.formatted(date: .omitted, time: .standard))")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Full Disk Access: \(fdaText(s.fullDiskAccess))").font(.callout)
                Table(s.sources) {
                    TableColumn("Source") { Text($0.id.rawValue).monospaced() }
                    TableColumn("State") { Text(stateText($0.state)) }
                    TableColumn("Items") { Text("\($0.itemCount)").monospacedDigit() }
                    TableColumn("Time") { Text("\($0.durationMs) ms").monospacedDigit() }
                    TableColumn("Note") { Text($0.note ?? "").foregroundStyle(.secondary) }
                }
            } else {
                ProgressView()
            }
        }.padding(16)
    }
    private func fdaText(_ a: AccessLevel) -> String {
        switch a { case .granted: "granted"; case .notGranted: "not granted"; case .indeterminate(let w): "unconfirmed (\(w))" }
    }
    private func stateText(_ s: SourceStatus.State) -> String {
        switch s {
        case .ok: "OK"
        case .needsFullDiskAccess: "Needs Full Disk Access"
        case .needsImport: "Needs import"
        case .unsupportedOS(let w): "Unsupported macOS: \(w)"
        case .formatUnrecognized(let w): "Format unrecognized: \(w)"
        case .failed(let w): "Failed: \(w)"
        case .timedOut: "Timed out"
        }
    }
}
