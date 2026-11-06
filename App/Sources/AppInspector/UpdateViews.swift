import SwiftUI

/// App menu item. Hidden in builds that don't update themselves.
struct CheckForUpdatesButton: View {
    @ObservedObject var updates: UpdateManager
    var body: some View {
        if updates.isAvailable {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

/// Settings › Updates.
struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateManager
    var body: some View {
        Form {
            if updates.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticallyChecksForUpdates($0) }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updates.automaticallyDownloadsUpdates },
                    set: { updates.setAutomaticallyDownloadsUpdates($0) }))
                    .disabled(!updates.automaticallyChecksForUpdates)
                Text("App Inspector asks GitHub once a day whether a newer release exists. Updates install when you quit the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            } else if let error = updates.startupError {
                Text(error).foregroundStyle(.orange)
            } else {
                Text("This build doesn't update itself. Release builds from GitHub do.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
