import SwiftUI
import AppKit
import InspectorSources
import InspectorModel

@main
struct AppInspectorApp: App {
    @State private var store = InspectorStore()

    init() {
        if CommandLine.arguments.contains("--dump") { Self.dumpAndExit() }
        if CommandLine.arguments.contains("--bench") { Self.benchAndExit() }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-btm"), CommandLine.arguments.indices.contains(i + 1) {
            BTMProbe.run(output: CommandLine.arguments[i + 1])
        }
        // Allows `swift run` (no bundle) to show a window with focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// `AppInspector --bench`: cold and warm scan time (BTM skipped: its read time is separate and variable).
    private static func benchAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let o = ScanOrchestrator()
            for label in ["cold", "warm", "warm"] {
                let t = Date()
                let snap = await o.scan(btm: .skip)
                print(String(format: "%@ scan: %.2f s, %d apps, signing cache hits=%d misses=%d", label, Date().timeIntervalSince(t),
                             snap.apps.count, o.inventory.signing.hits, o.inventory.signing.misses))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// Headless self-check: `AppInspector --dump` prints a scan summary and exits.
    private static func dumpAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let snap = await ScanOrchestrator().scan()
            print("macOS \(snap.os.version) (\(snap.os.build)) FDA=\(snap.fullDiskAccess)")
            for s in snap.sources { print("source \(s.id) \(s.state) items=\(s.itemCount) \(s.durationMs)ms \(s.note ?? "")") }
            var kinds: [String: Int] = [:]
            for p in snap.apps.flatMap(\.permissions) {
                let k: String = switch p.state {
                case .confirmed(let st, _): "confirmed-\(st.kind)"
                case .notRecorded: "notRecorded"
                case .recordedForDifferentSignature: "differentSignature"
                case .declared: "declared"
                case .inferred: "inferred"
                case .unknown: "unknown"
                }
                kinds[k, default: 0] += 1
            }
            var ext: [String: Int] = [:], start: [String: Int] = [:], rank: [Int: Int] = [:]
            let allExt = snap.apps.flatMap(\.extensions) + snap.unattributedExtensions + snap.developerGroups.flatMap(\.extensions)
            let allStart = snap.apps.flatMap(\.startupItems) + snap.unattributedStartup + snap.developerGroups.flatMap(\.startupItems)
            for e in allExt {
                let k: String = switch e.state {
                case .confirmed(let st, _): "\(st.kind)"
                case .unknown: "unknown"
                default: "other"
                }
                ext[k, default: 0] += 1; rank[e.association.rank, default: 0] += 1
            }
            for i in allStart {
                let k: String = switch i.loadState {
                case .confirmed(let st, _): "\(st.kind)".prefix { $0 != "(" }.description
                case .unknown: "unknown"
                default: "other"
                }
                start[k, default: 0] += 1; rank[i.association.rank, default: 0] += 1
            }
            var appr: [String: Int] = [:]
            for i in allStart {
                let k: String = switch i.approval {
                case .confirmed(let a, let e): (a.isNegative ? "negative" : "enabled") + (e.staleSource ? "-stale" : "")
                case .notRecorded: "notRecorded"
                case .unknown(let r): "unknown(\(r.message.prefix(40)))"
                default: "other"
                }
                appr[k, default: 0] += 1
            }
            print("btm approval=\(appr.sorted { $0.key < $1.key }) btmOnly=\(allStart.filter { $0.id.hasPrefix("btm:") }.count)")
            if CommandLine.arguments.contains("--verbose") {
                for i in allStart { print("  start \(i.label) kind=\(i.kind) approval=\(i.approval)".prefix(220)) }
            }
            print("extensions=\(allExt.count) \(ext.sorted { $0.key < $1.key }) startup=\(allStart.count) \(start.sorted { $0.key < $1.key })")
            if CommandLine.arguments.contains("--verbose") {
                for e in allExt where e.association.rank >= 4 { print("  ext rank\(e.association.rank) \(e.identifier) → \(e.association.target) [\(e.association.reason)]") }
                for i in allStart { print("  start rank\(i.association.rank) \(i.label) (\(i.kind)) → \(i.association.target)") }
            }
            print("association ranks (0=none)=\(rank.sorted { $0.key < $1.key }) groups=\(snap.developerGroups.count) looseExt=\(snap.unattributedExtensions.count) looseStart=\(snap.unattributedStartup.count)")
            print("apps=\(snap.apps.count) unattributed=\(snap.unattributed.count) states=\(kinds.sorted { $0.key < $1.key })")
            done.signal()
        }
        done.wait()
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 520)
                .task { UpdateManager.shared.start(); store.startLiveRefresh(); await store.rescan() }
        }
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updates: UpdateManager.shared) }
            CommandGroup(after: .newItem) {
                Button("Rescan") { Task { await store.rescan() } }.keyboardShortcut("r")
            }
        }
        Settings {
            UpdateSettingsView(updates: UpdateManager.shared)
        }
        Window("About this data", id: "about-data") {
            AboutDataView().environment(store).frame(minWidth: 640, minHeight: 420)
        }
        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView().environment(store).frame(minWidth: 560, minHeight: 280)
        }
    }
}
