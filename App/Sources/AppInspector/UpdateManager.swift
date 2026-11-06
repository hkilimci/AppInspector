import AppKit
import Combine
import Sparkle

/// Sparkle updates for release builds. Settings and the feed live in Info.plist, written by
/// Tools/make-app-bundle.sh; Tools/release.sh marks the bundle as a release (`AppInspectorDistribution`).
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    static let releaseMarker = "AppInspectorDistribution"
    static let bundleID = "dev.appinspector.AppInspector"

    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var startupError: String?

    private var controller: SPUStandardUpdaterController?

    /// Only a release build may replace itself: `swift run`, dev bundles and test copies never start the updater.
    static func shouldStart(bundle: Bundle) -> Bool {
        bundle.bundleIdentifier == bundleID
            && bundle.object(forInfoDictionaryKey: releaseMarker) as? String == "release"
            && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        #if DEBUG
        return
        #else
        guard controller == nil, Self.shouldStart(bundle: .main) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            startupError = "Updates could not start. \(error.localizedDescription)"
            return
        }
        self.controller = controller
        isAvailable = true
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}
