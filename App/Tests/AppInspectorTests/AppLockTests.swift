import Testing
import Foundation
@testable import AppInspector

/// The lock's rules, driven with a made-up clock: nothing here waits or shows a dialog.
@Suite struct AppLockTests {
    private let t0 = ContinuousClock.now
    private func at(_ seconds: Int) -> ContinuousClock.Instant { t0.advanced(by: .seconds(seconds)) }

    private func unlocked(_ settings: AppLockSettings) -> LockState {
        var state = LockState(settings: settings, now: t0)
        state.handle(.authenticated, at: t0, settings: settings)
        return state
    }

    @Test func launchStartsLockedOnlyWhenEnabled() {
        #expect(LockState(settings: .init(isEnabled: true), now: t0).isLocked)
        #expect(!LockState(settings: .init(isEnabled: false), now: t0).isLocked)
    }

    @Test func onlyAuthenticationUnlocks() {
        let settings = AppLockSettings(isEnabled: true, delay: .oneMinute)
        var state = LockState(settings: settings, now: t0)
        for event in [LockEvent.userActivity, .appBecameActive, .idleCheck, .appResignedActive] {
            state.handle(event, at: at(1), settings: settings)
            #expect(state.isLocked, "\(event) must not unlock")
        }
        state.handle(.authenticated, at: at(2), settings: settings)
        #expect(!state.isLocked)
    }

    @Test func locksAfterIdleLimitAndActivityPostponesIt() {
        let settings = AppLockSettings(isEnabled: true, delay: .fiveMinutes)
        var state = unlocked(settings)
        state.handle(.idleCheck, at: at(299), settings: settings)
        #expect(!state.isLocked)
        state.handle(.userActivity, at: at(299), settings: settings)
        state.handle(.idleCheck, at: at(500), settings: settings)
        #expect(!state.isLocked)
        state.handle(.appBecameActive, at: at(599), settings: settings)
        #expect(state.isLocked)
    }

    @Test func switchingAwayLocksAtOnceOnlyForThatDelay() {
        let away = AppLockSettings(isEnabled: true, delay: .onSwitchAway)
        var state = unlocked(away)
        state.handle(.idleCheck, at: at(86_400), settings: away)
        #expect(!state.isLocked, "no idle limit while the app is in front")
        state.handle(.appResignedActive, at: at(86_401), settings: away)
        #expect(state.isLocked)

        // With a delay, leaving starts the clock instead.
        let delayed = AppLockSettings(isEnabled: true, delay: .oneMinute)
        state = unlocked(delayed)
        state.handle(.appResignedActive, at: at(100), settings: delayed)
        state.handle(.appBecameActive, at: at(159), settings: delayed)
        #expect(!state.isLocked)
        state.handle(.idleCheck, at: at(160), settings: delayed)
        #expect(state.isLocked)
    }

    @Test func systemLockLocksRegardlessOfDelay() {
        let settings = AppLockSettings(isEnabled: true, delay: .oneHour)
        var state = unlocked(settings)
        state.handle(.lockNow, at: at(1), settings: settings)
        #expect(state.isLocked)
    }

    @Test func disabledNeverLocks() {
        let settings = AppLockSettings(isEnabled: false, delay: .onSwitchAway)
        var state = LockState(settings: settings, now: t0)
        for event in [LockEvent.lockNow, .appResignedActive, .idleCheck] {
            state.handle(event, at: at(86_400), settings: settings)
        }
        #expect(!state.isLocked)
    }

    @Test func settingsRoundTripThroughDefaults() throws {
        let suite = "AppLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppLockSettings(defaults: defaults) == AppLockSettings(), "off with a five-minute delay by default")
        AppLockSettings(isEnabled: true, delay: .onSwitchAway).save(to: defaults)
        #expect(AppLockSettings(defaults: defaults) == AppLockSettings(isEnabled: true, delay: .onSwitchAway))

        defaults.set(42, forKey: AppLockSettings.delayKey)
        #expect(AppLockSettings(defaults: defaults).delay == .fiveMinutes, "an unknown delay falls back to the default")
    }
}
