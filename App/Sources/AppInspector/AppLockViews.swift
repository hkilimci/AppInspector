import SwiftUI

extension View {
    /// Replaces a window's content with the lock screen while the app is locked. The data views leave the
    /// hierarchy with their toolbar and search field, rather than sitting under a cover.
    func lockGate(_ lock: AppLockController) -> some View { LockGate(lock: lock, content: self) }
}

private struct LockGate<Content: View>: View {
    let lock: AppLockController
    let content: Content
    var body: some View {
        if lock.isLocked { LockScreen(lock: lock) } else { content }
    }
}

private struct LockScreen: View {
    let lock: AppLockController
    var body: some View {
        ContentUnavailableView {
            Label("App Inspector Is Locked", systemImage: "lock.fill")
        } description: {
            Text("Unlock with \(Authenticator.method).")
            if let failure = lock.failure { Text(failure).foregroundStyle(.orange) }
        } actions: {
            Button("Unlock") { Task { await lock.unlock() } }
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// App menu item. Shown only while the lock is turned on.
struct LockNowButton: View {
    let lock: AppLockController
    var body: some View {
        if lock.settings.isEnabled {
            Button("Lock App Inspector") { lock.lockNow() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(lock.isLocked)
        }
    }
}

/// Settings › Security.
struct AppLockSettingsView: View {
    let lock: AppLockController
    var body: some View {
        Form {
            // The toggle shows the saved setting; it only changes once authentication succeeds.
            Toggle("Require \(Authenticator.method) to open App Inspector", isOn: Binding(
                get: { lock.settings.isEnabled },
                set: { enabled in Task { await lock.setEnabled(enabled) } }))
                .disabled(lock.isAuthenticating)
            Picker("Lock", selection: Binding(get: { lock.settings.delay }, set: { lock.setDelay($0) })) {
                ForEach(AutoLockDelay.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!lock.settings.isEnabled)
            Text("Inactivity means no click, key press or scroll in App Inspector's windows. It also locks when your Mac sleeps or locks its screen. Locking hides the windows; it doesn't stop scans or encrypt anything.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure = lock.failure { Text(failure).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
