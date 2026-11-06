import Testing
import Foundation
@testable import InspectorPlatform

@Suite struct TCCResetTests {
    @Test func serviceNamesDropThePrefix() {
        #expect(TCCReset.tccutilName("kTCCServiceSystemPolicyAllFiles") == "SystemPolicyAllFiles")
        #expect(TCCResetRequest(service: "kTCCServiceCamera", bundleID: "com.x").tccutilService == "Camera")
        #expect(TCCResetRequest(service: nil, bundleID: "com.x").tccutilService == "All")
    }

    @Test func bundleIDValidationRefusesShellAndOptionCharacters() {
        #expect(TCCReset.isValidBundleID("com.example.App-Helper_2"))
        for bad in ["", "-rf", ".hidden", "com.x; rm -rf ~", "com.x'y", "com.x$(id)", "com.x\ny", "com.é", "com x"] {
            #expect(!TCCReset.isValidBundleID(bad), "\(bad)")
        }
        #expect(!TCCReset.isValidService("Camera; id"))
    }

    @Test func scriptUsesStubOnlyForStaleBundles() {
        let reqs = [TCCResetRequest(service: "kTCCServiceCamera", bundleID: "com.gone.app"),
                    TCCResetRequest(service: nil, bundleID: "com.installed.app")]
        let s = TCCReset.privilegedScript(reqs, stale: ["com.gone.app"])
        #expect(s.contains("tcc_reset_stale() {"))
        #expect(s.contains("mktemp -d /Library/Caches/AppInspectorStub.XXXXXX"))   // root's stubs never land in a user folder
        #expect(s.contains("\ntcc_reset_stale Camera com.gone.app\n"))
        #expect(s.contains("\n/usr/bin/tccutil reset All com.installed.app\n"))
        #expect(!s.contains("sudo"))
        #expect(s.hasSuffix("\ntrue\n"))   // one failed reset doesn't abort the rest
    }

    @Test func scriptWithoutStaleBundlesHasNoStubFunction() {
        let s = TCCReset.privilegedScript([TCCResetRequest(service: nil, bundleID: "com.installed.app")], stale: [])
        #expect(!s.contains("tcc_reset_stale"))
        #expect(!s.contains("lsregister"))
    }

    @Test func scriptDropsInvalidRequests() {
        let s = TCCReset.privilegedScript([TCCResetRequest(service: nil, bundleID: "com.x; rm -rf ~")], stale: [])
        #expect(!s.contains("rm -rf ~"))
        #expect(!s.contains("tccutil reset"))
    }

    @Test func scriptParsesUnderSh() async throws {
        let s = TCCReset.privilegedScript([TCCResetRequest(service: "kTCCServiceCamera", bundleID: "com.gone.app"),
                                           TCCResetRequest(service: nil, bundleID: "com.here.app")], stale: ["com.gone.app"])
        let res = try await ProcessRunner.run("/bin/sh", ["-n", "-c", s])
        #expect(res.status == 0, "\(String(decoding: res.stderr, as: UTF8.self))")
    }

    @Test func appleScriptStringEscapesQuotesAndBackslashes() {
        #expect(TCCReset.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }

    @Test func invalidRequestsAreRefusedWithoutRunningAnything() async {
        let r = TCCResetRequest(service: nil, bundleID: "-bad")
        let out = await TCCReset.perform([r], stale: ["-bad"])
        guard case .refused? = out[r] else { Issue.record("expected refusal, got \(String(describing: out[r]))"); return }
    }

    /// Runs the real tccutil and lsregister on an ID that has no TCC rows, so nothing is cleared.
    /// Opt in: `APPINSPECTOR_LIVE_RESET=1 swift test --filter TCCResetTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPINSPECTOR_LIVE_RESET"] == "1"))
    func liveStubMakesTCCUtilAcceptAMissingBundle() async {
        let id = "com.example.appinspector.tests.live-\(UUID().uuidString.prefix(8))"
        let r = TCCResetRequest(service: "kTCCServiceCamera", bundleID: id)
        let without = await TCCReset.perform([r], stale: [])
        guard case .failed(let msg)? = without[r] else { Issue.record("plain tccutil accepted a missing bundle"); return }
        #expect(msg.contains("-10814"))
        #expect(await TCCReset.perform([r], stale: [id])[r] == .succeeded)
        #expect(!TCCReset.isResolvable(id))   // stub unregistered
        let left = (try? FileManager.default.contentsOfDirectory(atPath: TCCReset.stubRoot.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func madeUpBundleIDIsNotResolvable() {
        #expect(!TCCReset.isResolvable("com.example.appinspector.tests.never-installed"))
        #expect(TCCReset.isResolvable("com.apple.finder"))
    }
}
