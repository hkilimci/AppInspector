import Foundation
import AppKit
import InspectorPlatform

/// Triggers a rescan when watched folders change or apps launch/quit. Debounced so an install or update triggers one scan.
@MainActor
final class RefreshMonitor {
    private let watcher: FileSystemWatcher
    private let debouncer = Debouncer(interval: .seconds(2))
    nonisolated(unsafe) private var tasks: [Task<Void, Never>] = []
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(refresh: @escaping @MainActor () async -> Void, onActivate: @escaping @MainActor () async -> Void) {
        watcher = FileSystemWatcher(paths: WatchedPaths.standard(), latency: 1.0)
        let trigger: @Sendable () -> Void = { [debouncer] in
            debouncer.trigger { await refresh() }
        }
        tasks.append(Task { for await _ in watcher.events { trigger() } })

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in trigger() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await onActivate() }
        })
    }

    deinit {
        watcher.stop()
        debouncer.cancel()
        tasks.forEach { $0.cancel() }
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }
}
