import AppKit
import LocalAuthentication
import Observation

/// Settings › Security: requires Touch ID or the login password to show App Inspector's windows,
/// and locks again after the chosen inactivity or when the Mac sleeps or locks.
/// One instance lives as long as the app; its system observers hold it weakly.
@Observable @MainActor
final class AppLockController {
    /// How often an unused app checks whether it should lock.
    static let tick: Duration = .seconds(10)

    private(set) var settings: AppLockSettings
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Why the last authentication failed. Cleared by success or a cancel.
    private(set) var failure: String?

    // Activity is recorded on every click and key press; keeping the state out of observation
    // means only a change of `isLocked` redraws the windows.
    @ObservationIgnored private var state: LockState
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var eventMonitor: Any?
    /// Ask for Touch ID by itself once per lock, when the user comes back; after that they click Unlock.
    /// Prompting on every activation could loop if the dialog itself deactivates the app.
    @ObservationIgnored private var promptOnReturn: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let settings = AppLockSettings(defaults: defaults)
        let state = LockState(settings: settings, now: .now)
        self.defaults = defaults
        self.settings = settings
        self.state = state
        isLocked = state.isLocked
        promptOnReturn = state.isLocked
        observeSystem()
        updateTicker()
    }

    func unlock() async {
        guard isLocked, await authenticate("unlock App Inspector") else { return }
        handle(.authenticated)
    }

    func lockNow() { handle(.lockNow) }

    /// Turning the lock on or off asks for authentication, so someone at an unlocked window can't remove it.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.isEnabled,
              await authenticate(enabled ? "turn on the app lock" : "turn off the app lock") else { return }
        settings.isEnabled = enabled
        settings.save(to: defaults)
        handle(.authenticated)
        updateTicker()
    }

    func setDelay(_ delay: AutoLockDelay) {
        settings.delay = delay
        settings.save(to: defaults)
        handle(.userActivity)
        updateTicker()
    }

    // MARK: events

    private func receive(_ event: LockEvent) {
        // The authentication dialog can deactivate the app while it's up; that isn't the user leaving.
        if isAuthenticating, event == .appResignedActive || event == .appBecameActive { return }
        handle(event)
        if event == .appBecameActive, isLocked, promptOnReturn {
            promptOnReturn = false
            Task { await unlock() }
        }
    }

    private func handle(_ event: LockEvent) {
        let wasLocked = state.isLocked
        state.handle(event, at: .now, settings: settings)
        guard state.isLocked != isLocked else { return }
        isLocked = state.isLocked
        if isLocked, !wasLocked {
            promptOnReturn = true
            failure = nil
        }
    }

    private func observeSystem() {
        // Every source below delivers on the main thread.
        let deliver: @Sendable (LockEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.receive(event)
            }
        }
        let sources: [(NotificationCenter, Notification.Name, LockEvent)] = [
            (NotificationCenter.default, NSApplication.didResignActiveNotification, .appResignedActive),
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification, .appBecameActive),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, .lockNow),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification, .lockNow),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, .lockNow),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .lockNow),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstart"), .lockNow),
        ]
        observers = sources.map { center, name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in deliver(event) }
        }
        // Local events only: input to App Inspector's own windows, never to other apps.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event in
            deliver(.userActivity)
            return event
        }
    }

    private func updateTicker() {
        ticker?.cancel()
        ticker = nil
        guard settings.isEnabled, settings.delay.idleLimit != nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AppLockController.tick)
                guard let self, !Task.isCancelled else { return }
                self.handle(.idleCheck)
            }
        }
    }

    private func authenticate(_ reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        switch await Authenticator.authenticate(reason: reason) {
        case .success: failure = nil; return true
        case .cancelled: failure = nil; return false
        case .failed(let message): failure = message; return false
        }
    }
}

/// LocalAuthentication's owner check: Touch ID, Apple Watch or the login password, whichever the Mac offers.
/// macOS runs the dialog; App Inspector never sees the fingerprint or the password.
enum Authenticator {
    enum Outcome: Sendable { case success, cancelled, failed(String) }

    /// How the user unlocks, for labels: "Touch ID or your password" on Macs with a Touch ID sensor.
    static let method: String = {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID or your password" : "your password"
    }()

    /// macOS words the dialog as "App Inspector is trying to <reason>."
    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .failed(error?.localizedDescription ?? "This Mac can't verify your identity.")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed("Authentication failed.")
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
