import Foundation

// The app lock's rules, free of AppKit and LocalAuthentication so they can be tested with a made-up clock.
// AppLockController feeds them real events and time.

/// How long App Inspector stays unlocked without being used.
enum AutoLockDelay: Int, CaseIterable, Identifiable, Sendable {
    /// Locks as soon as another app becomes active.
    case onSwitchAway = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var id: Int { rawValue }

    /// Inactivity that locks the app; nil when only switching away does.
    var idleLimit: Duration? { self == .onSwitchAway ? nil : .seconds(rawValue) }

    var label: String {
        switch self {
        case .onSwitchAway: "When you switch to another app"
        case .oneMinute: "After 1 minute of inactivity"
        case .fiveMinutes: "After 5 minutes of inactivity"
        case .fifteenMinutes: "After 15 minutes of inactivity"
        case .oneHour: "After 1 hour of inactivity"
        }
    }
}

/// Settings › Security, kept in the app's user defaults.
struct AppLockSettings: Equatable, Sendable {
    var isEnabled = false
    var delay: AutoLockDelay = .fiveMinutes

    static let enabledKey = "AppLockEnabled"
    static let delayKey = "AppLockDelay"

    init(isEnabled: Bool = false, delay: AutoLockDelay = .fiveMinutes) {
        self.isEnabled = isEnabled
        self.delay = delay
    }

    init(defaults: UserDefaults) {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if defaults.object(forKey: Self.delayKey) != nil,
           let delay = AutoLockDelay(rawValue: defaults.integer(forKey: Self.delayKey)) {
            self.delay = delay
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(delay.rawValue, forKey: Self.delayKey)
    }
}

enum LockEvent: Sendable {
    /// A click, key press or scroll in one of the app's windows.
    case userActivity
    /// Another app became active.
    case appResignedActive
    /// The user came back to App Inspector.
    case appBecameActive
    /// Periodic check while the app sits unused.
    case idleCheck
    /// The Lock command, or the Mac sleeps, locks its screen, starts the screen saver or switches user.
    case lockNow
    /// Touch ID, Apple Watch or the password was accepted.
    case authenticated
}

/// Whether the windows may show scan data. A launch with the lock turned on starts locked.
struct LockState: Equatable, Sendable {
    private(set) var isLocked: Bool
    private(set) var lastActivity: ContinuousClock.Instant

    init(settings: AppLockSettings, now: ContinuousClock.Instant) {
        isLocked = settings.isEnabled
        lastActivity = now
    }

    mutating func handle(_ event: LockEvent, at now: ContinuousClock.Instant, settings: AppLockSettings) {
        guard settings.isEnabled else {
            isLocked = false
            lastActivity = now
            return
        }
        switch event {
        case .authenticated:
            isLocked = false
            lastActivity = now
        case _ where isLocked:
            break  // only authentication unlocks
        case .userActivity:
            lastActivity = now
        case .appResignedActive:
            // Leaving counts as the last use, so a delay runs from the switch.
            if settings.delay.idleLimit == nil { isLocked = true } else { lastActivity = now }
        case .appBecameActive, .idleCheck:
            if let limit = settings.delay.idleLimit, lastActivity.duration(to: now) >= limit { isLocked = true }
        case .lockNow:
            isLocked = true
        }
    }
}
