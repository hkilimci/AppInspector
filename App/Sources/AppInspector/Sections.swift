import SwiftUI
import AppKit
import InspectorModel
import InspectorPlatform
import InspectorSources

// MARK: - Chip specs for Phase 2 states

func unknownChip(_ r: UnknownReason) -> ChipSpec {
    .init(text: "Unknown", icon: r == .needsFullDiskAccess || r == .needsBTMImport ? "lock" : "questionmark", look: .dashed,
          a11y: "Unknown. \(r.message)")
}

func chipSpec(for d: Determination<ExtensionState>) -> ChipSpec {
    switch d {
    case .confirmed(let s, _):
        switch s.kind {
        case .elected: .init(text: "Use (user election)", icon: "checkmark.circle.fill", look: .solid(.green), a11y: "Confirmed: elected for use")
        case .systemDefault: .init(text: "System default", icon: "circle.dashed", look: .outline(.secondary), a11y: "Confirmed: no user election recorded")
        case .superseded: .init(text: "Superseded", icon: "arrow.triangle.swap", look: .outline(.secondary), a11y: "Confirmed: superseded by another version")
        case .ignored: .init(text: "Ignored (user election)", icon: "xmark.circle.fill", look: .solid(.orange), a11y: "Confirmed: election says ignore")
        case .activatedEnabled: .init(text: "Enabled", icon: "checkmark.circle.fill", look: .solid(.green), a11y: "Confirmed: activated and enabled")
        case .waitingForUser: .init(text: "Waiting for approval", icon: "hourglass", look: .outline(.orange), a11y: "Confirmed: activated, waiting for user approval")
        case .disabled: .init(text: "Disabled", icon: "xmark.circle.fill", look: .solid(.orange), a11y: "Confirmed: activated but disabled")
        case .pendingUninstall: .init(text: "Removing on restart", icon: "trash", look: .outline(.orange), a11y: "Confirmed: waiting to uninstall on reboot")
        }
    case .notRecorded: .init(text: "No record", icon: "circle", look: .outline(.secondary), a11y: "Confirmed: no record")
    case .recordedForDifferentSignature: .init(text: "Different signature", icon: "exclamationmark.triangle", look: .outline(.orange), a11y: "Recorded for a different signature")
    case .declared: .init(text: "Declared", icon: "doc.text", look: .outline(.blue), a11y: "Declared, not a state")
    case .inferred(_, _, let why): .init(text: "Probably", icon: "sparkles", look: .dotted(.secondary), a11y: "Inferred, not confirmed: \(why)")
    case .unknown(let r): unknownChip(r)
    }
}

func chipSpec(for d: Determination<StartupState>) -> ChipSpec {
    switch d {
    case .confirmed(let s, _):
        switch s.kind {
        case .running: .init(text: "Running", icon: "play.circle.fill", look: .solid(.green), a11y: "Confirmed: loaded and running")
        case .loaded: .init(text: "Loaded", icon: "checkmark.circle", look: .solid(.green), a11y: "Confirmed: loaded, not currently running")
        case .notLoaded: .init(text: "Not loaded", icon: "circle", look: .outline(.secondary), a11y: "Confirmed: not loaded in launchd")
        }
    case .unknown(let r): unknownChip(r)
    default: .init(text: "—", icon: "circle", look: .outline(.secondary), a11y: "No state")
    }
}

func approvalChip(_ d: Determination<BackgroundApproval>) -> ChipSpec? {
    switch d {
    case .confirmed(let a, _):
        if !a.allowed { return .init(text: "Not allowed", icon: "nosign", look: .solid(.orange), a11y: "Confirmed: background item not allowed by policy") }
        if !a.enabled { return .init(text: "Off in Login Items", icon: "xmark.circle.fill", look: .solid(.orange), a11y: "Confirmed: turned off in Login Items and Extensions") }
        return .init(text: "On in Login Items", icon: "checkmark.circle.fill", look: .solid(.green), a11y: "Confirmed: allowed in Login Items and Extensions")
    case .notRecorded: return .init(text: "No background-task record", icon: "circle", look: .outline(.secondary), a11y: "Confirmed: no background task record")
    case .unknown(let r): return unknownChip(r)
    default: return nil
    }
}

struct NewBadge: View {
    let changed: Bool
    var body: some View {
        Text(changed ? "Changed" : "New").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.white).background(.blue, in: Capsule()).accessibilityLabel(changed ? "Changed since last scan" : "New since last scan")
    }
}

func overrideChip(_ d: Determination<LaunchdOverride>) -> ChipSpec? {
    switch d {
    case .confirmed(let o, _) where o.isNegative:
        .init(text: "Disabled in launchctl", icon: "nosign", look: .solid(.orange), a11y: "Confirmed: disabled by launchctl override")
    case .unknown(let r): unknownChip(r)
    default: nil
    }
}

// MARK: - Generic evidence sheet

struct EvidencePayload: Identifiable {
    let id = UUID()
    let title: String
    let chip: ChipSpec
    let unknown: UnknownReason?
    let blocks: [(String, Evidence)]
}

struct PayloadEvidenceSheet: View {
    let payload: EvidencePayload
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence: \(payload.title)").font(.title3.weight(.semibold))
            Chip(spec: payload.chip)
            if let u = payload.unknown { Text(u.message).font(.callout) }
            ForEach(Array(payload.blocks.enumerated()), id: \.offset) { EvidenceBlock(title: $0.element.0, e: $0.element.1) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }
}

// MARK: - Association line

struct AssociationLine: View {
    let association: Association
    var body: some View {
        if let c = association.confidence, association.rank > 0 {
            Label {
                Text(prefix(c) + association.reason)
            } icon: {
                Image(systemName: c <= .probable ? "link.badge.plus" : "link")
            }
            .font(.caption).foregroundStyle(c <= .probable ? .secondary : .tertiary)
            .help("Association rank \(association.rank)")
        }
    }
    private func prefix(_ c: AssociationConfidence) -> String {
        switch c {
        case .suggestion: "Possibly related (not verified): "
        case .probable: "Probably linked: "
        default: "Linked: "
        }
    }
}

// MARK: - Source coverage note

private func problem(_ ids: [SourceID], in sources: [SourceStatus]) -> String? {
    let bad = sources.filter { ids.contains($0.id) && $0.state != .ok }
    guard !bad.isEmpty else { return nil }
    return bad.map { "\($0.id.rawValue): \(describe($0.state))" }.joined(separator: "; ")
}

private func describe(_ s: SourceStatus.State) -> String {
    switch s {
    case .ok: "OK"
    case .needsFullDiskAccess: "needs Full Disk Access"
    case .needsImport: "needs import"
    case .unsupportedOS(let w): "unsupported macOS (\(w))"
    case .formatUnrecognized(let w): "format not fully recognized (\(w))"
    case .failed(let w): "failed (\(w))"
    case .timedOut: "timed out"
    }
}

/// "None found" is a claim; it is made only when every source behind the list was read completely.
func emptyStateText(noun: String, problem: String?) -> String {
    problem == nil ? "No \(noun) found for this item." : "Unknown: \(noun) could not be read completely (\(problem ?? ""))."
}

struct CoverageNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
    }
}

// MARK: - Extensions section

struct ExtensionsSection: View {
    let items: [ExtensionItem]
    let sources: [SourceStatus]
    @State private var payload: EvidencePayload?

    private var groups: [(String, [ExtensionItem])] {
        Dictionary(grouping: items) { i in
            switch i.kind { case .app(let p): p; case .system(let c): c }
        }.sorted { $0.key < $1.key }.map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Extensions", systemImage: "puzzlepiece.extension").font(.headline)
            if let p = problem([.pluginkit, .systemExtensionsCtl, .systemExtensionsDB], in: sources) { CoverageNote(text: "Partly unavailable: \(p)") }
            if items.isEmpty {
                Text(emptyStateText(noun: "extensions", problem: problem([.pluginkit, .systemExtensionsCtl], in: sources)))
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.0) { point, list in
                Text(point).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(list) { item in
                    ExtensionRow(item: item) { payload = makePayload(item) }
                    Divider()
                }
            }
        }
        .sheet(item: $payload) { PayloadEvidenceSheet(payload: $0) }
    }

    private func makePayload(_ i: ExtensionItem) -> EvidencePayload {
        var blocks: [(String, Evidence)] = []
        if let e = i.state.evidence { blocks.append(("State", e)) }
        var unknown: UnknownReason?
        if case .unknown(let r) = i.state { unknown = r }
        return EvidencePayload(title: i.name, chip: chipSpec(for: i.state), unknown: unknown, blocks: blocks)
    }
}

struct ExtensionRow: View {
    @Environment(InspectorStore.self) private var store
    let item: ExtensionItem
    let showEvidence: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium))
                    if store.isNew(SnapshotDiff.extensionID(item.id)) { NewBadge(changed: false) }
                    else if store.isChanged(SnapshotDiff.extensionID(item.id)) { NewBadge(changed: true) }
                }
                Text(item.identifier + (item.version.map { " (\($0))" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let p = item.path { Text(p).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(p) }
                AssociationLine(association: item.association)
                if case .unknown(let r) = item.state { Text(r.message).font(.caption).foregroundStyle(.secondary) }
                if item.state.evidence?.unvalidatedOS == true { Text("Unvalidated on this macOS build").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            Button(action: showEvidence) { Chip(spec: chipSpec(for: item.state)) }.buttonStyle(.plain).help("Show evidence")
            if case .system = item.kind {
                Button { NSWorkspace.shared.open(URL(string: SystemSettingsLinker.loginItems)!) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open Login Items & Extensions")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Startup section

struct StartupSection: View {
    let items: [StartupItem]
    let sources: [SourceStatus]
    @State private var payload: EvidencePayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Startup & Background", systemImage: "bolt.horizontal.circle").font(.headline)
                Spacer()
                Button("Open Login Items & Extensions") { NSWorkspace.shared.open(URL(string: SystemSettingsLinker.loginItems)!) }
                    .buttonStyle(.link).font(.caption)
            }
            let startupProblem = problem([.launchctlDomain, .launchctlDisabled, .launchdPlists, .bundledHelpers, .launchctlJobs], in: sources)
            if let p = startupProblem { CoverageNote(text: "Partly unavailable: \(p)") }
            if items.isEmpty { Text(emptyStateText(noun: "startup or background items", problem: startupProblem)).foregroundStyle(.secondary) }
            ForEach(items.sorted { $0.label < $1.label }) { item in
                StartupRow(item: item) { payload = makePayload(item) }
                Divider()
            }
        }
        .sheet(item: $payload) { PayloadEvidenceSheet(payload: $0) }
    }

    private func makePayload(_ i: StartupItem) -> EvidencePayload {
        var blocks: [(String, Evidence)] = []
        if let e = i.loadState.evidence { blocks.append(("Load state", e)) }
        if let e = i.override.evidence { blocks.append(("launchctl override", e)) }
        if let e = i.approval.evidence { blocks.append(("Background approval (BTM)", e)) }
        var unknown: UnknownReason?
        if case .unknown(let r) = i.loadState { unknown = r }
        return EvidencePayload(title: i.label, chip: chipSpec(for: i.loadState), unknown: unknown, blocks: blocks)
    }
}

struct StartupRow: View {
    @Environment(InspectorStore.self) private var store
    let item: StartupItem
    let showEvidence: () -> Void

    private var kindText: String {
        switch item.kind {
        case .launchAgent: "Launch agent"
        case .launchDaemon: "Launch daemon"
        case .loginItemHelper: "Login item helper"
        case .serviceManagement: "Registered background item (reported by launchd)"
        case .bundledLaunchPlist: "Bundled launch plist (declared in the app, not proof of registration)"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label).font(.body.weight(.medium)).textSelection(.enabled)
                    if store.isNew(SnapshotDiff.startupID(item.id)) { NewBadge(changed: false) }
                    else if store.isChanged(SnapshotDiff.startupID(item.id)) { NewBadge(changed: true) }
                }
                Text([kindText, item.runAtLoad == true ? "Runs at load" : nil, item.keepAlive == true ? "Keeps alive" : nil]
                    .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let p = item.plistPath ?? item.program {
                    Text(p).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(p)
                }
                AssociationLine(association: item.association)
                if case .unknown(let r) = item.approval {
                    Label("Background approval unknown: \(r.message)", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
                }
                if item.approval.evidence?.staleSource == true {
                    Label("Approval is from a report older than the last boot or a day", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if case .unknown(let r) = item.loadState { Text(r.message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button(action: showEvidence) { Chip(spec: chipSpec(for: item.loadState)) }.buttonStyle(.plain).help("Show evidence")
                if let o = overrideChip(item.override) { Chip(spec: o) }
                if case .unknown = item.approval {} else if let a = approvalChip(item.approval) { Chip(spec: a) }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Developer groups and loose items

struct GroupDetail: View {
    let group: DeveloperGroup
    let sources: [SourceStatus]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer group").font(.title2.weight(.semibold))
                    Text("Team ID \(group.teamID)").font(.callout.monospaced()).textSelection(.enabled)
                    Text("Items signed by this developer that could not be tied to a specific installed app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ExtensionsSection(items: group.extensions, sources: sources)
                StartupSection(items: group.startupItems, sources: sources)
            }.padding(20)
        }
    }
}

struct LooseItemsDetail: View {
    let extensions: [ExtensionItem]
    let startup: [StartupItem]
    let sources: [SourceStatus]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unattributed items").font(.title2.weight(.semibold))
                    Text("No signal links these to an installed app. They are listed, never guessed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ExtensionsSection(items: extensions, sources: sources)
                StartupSection(items: startup, sources: sources)
            }.padding(20)
        }
    }
}

// MARK: - Background Task Management banner

/// Shown only when background approvals can't be read. With Full Disk Access they are read from the
/// Background Task Management database on every scan, silently.
struct BTMBanner: View {
    @Environment(InspectorStore.self) private var store

    var body: some View {
        if let status = store.snapshot?.sources.first(where: { $0.id == .btm }), status.state != .ok || store.lastBTMError != nil {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(status)).font(.callout.weight(.semibold))
                    if let e = store.lastBTMError { Text(e).font(.caption).foregroundStyle(.orange) }
                    else if let n = status.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if store.isReadingBTM { ProgressView().controlSize(.small) }
                if status.state == .needsFullDiskAccess {
                    Button("Open Settings") { SystemSettingsLinker.openFullDiskAccess() }
                } else {
                    // The database exists but its layout isn't recognized (e.g. a new macOS release).
                    Button("Read with sfltool…") { Task { await store.readBTMWithSfltool() } }
                        .disabled(store.isReadingBTM)
                        .help("macOS asks for an administrator password each time sfltool runs")
                }
            }
            .padding(10)
            .background(.blue.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func headline(_ status: SourceStatus) -> String {
        if store.isReadingBTM { return "Reading Background Task Management data…" }
        switch status.state {
        case .needsFullDiskAccess: return "Background approvals need Full Disk Access"
        case .formatUnrecognized(let w): return "Background data only partly readable: \(w)"
        default: return "Background approvals unavailable"
        }
    }
}

// MARK: - About this data

struct AboutDataView: View {
    @Environment(InspectorStore.self) private var store
    var body: some View {
        List(SourceCatalog.all) { info in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(info.title).font(.headline)
                    Spacer()
                    if let st = store.snapshot?.sources.first(where: { $0.id == info.id }) {
                        Text(String(describing: st.state)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Group {
                    row("Reads", info.reads); row("Needs", info.requirement); row("Stability", info.tier)
                    row("Trusted for", info.trustedFor); row("Limits", info.limits)
                }.font(.callout)
            }.padding(.vertical, 6)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(v).textSelection(.enabled)
        }
    }
}
