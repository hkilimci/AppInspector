import Testing
import InspectorModel
@testable import AppInspector

@Suite @MainActor struct PermissionPresentationTests {
    private let evidence = Evidence(source: .tccUser, locator: "test row", osBuild: "25F80")

    @Test func signatureMismatchHasNeutralChipAndIsExcludedFromGrants() {
        let state: Determination<PermissionState> = .recordedForDifferentSignature(evidence)
        let chip = chipSpec(for: state)
        #expect(chip.text == "Different signature")
        #expect(chip.a11y.contains("unknown"))
        guard case .outline = chip.look else { Issue.record("Mismatch presented as a confirmed decision"); return }

        let item = PermissionItem(service: ServiceCatalog.info(for: "kTCCServiceCamera"), state: state,
                                  signatureMatch: .confirmed(false, evidence))
        let app = AppRecord(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.x.foo", version: nil,
                            build: nil, signing: SigningSummary(kind: .unsigned), permissions: [item])
        let store = InspectorStore()
        store.snapshot = Snapshot(apps: [app], unattributed: [], sources: [],
                                  os: OSInfo(version: OSVersion(26), build: "25F80"), fullDiskAccess: .granted)
        store.filter = .hasGrants
        #expect(store.visibleApps.isEmpty)
        store.filter = .needsAttention
        #expect(store.visibleApps.map(\.name) == ["Foo"])
    }

    @Test(arguments: [2, 3, 4, 5, 8, 9, 13, 99])
    func denialChipPreservesActualReason(reason: Int) throws {
        let token = try #require(CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy,
                                                                       key: "kTCCServiceCamera", os: OSVersion(26)))
        let state = PermissionState.denied(authReason: reason, token: token)
        let chip = chipSpec(for: .confirmed(state, evidence))
        let expected = [2: "Denied by user", 3: "Denied by user", 4: "Denied: System policy",
                        5: "Denied: Service policy", 8: "Denied: Missing usage string", 9: "Denied: Prompt timed out",
                        13: "Denied: Prompt cancelled", 99: "Denied: Unknown authorization reason 99"]
        #expect(chip.text == expected[reason])
        #expect(chip.a11y.contains(try #require(expected[reason])))
    }

    @Test func denialWithoutReasonDoesNotBlameUser() throws {
        let token = try #require(CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy,
                                                                       key: "kTCCServiceCamera", os: OSVersion(26)))
        #expect(chipSpec(for: .confirmed(.denied(token: token), evidence)).text == "Denied")
        #expect(chipSpec(for: .confirmed(.denied(managed: true, authReason: 6, token: token), evidence)).text == "Denied by profile")
    }

    @Test(arguments: [SourceStatus.State.needsFullDiskAccess, .failed("read error"), .timedOut,
                      .formatUnrecognized("unreadable rows"), .unsupportedOS("27")])
    func emptyPrivacySectionDoesNotClaimAbsenceWhenEitherDatabaseIsUnreadable(state: SourceStatus.State) {
        for unreadable in [SourceID.tccUser, .tccSystem] {
            let sources = [SourceID.tccUser, .tccSystem].map {
                SourceStatus(id: $0, state: $0 == unreadable ? state : .ok, itemCount: 0)
            }
            let section = PrivacySection(items: [], sources: sources)
            #expect(section.emptyMessage.contains("Unknown"))
            #expect(!section.emptyMessage.contains("No privacy permissions recorded"))
        }
    }

    @Test func emptyPrivacySectionRequiresBothSourcesBeforeClaimingAbsence() {
        let user = SourceStatus(id: .tccUser, state: .ok, itemCount: 0)
        let system = SourceStatus(id: .tccSystem, state: .ok, itemCount: 0)
        for sources in [[], [user], [system]] {
            #expect(PrivacySection(items: [], sources: sources).emptyMessage.contains("Unknown"))
        }
        #expect(PrivacySection(items: [], sources: [user, system]).emptyMessage == "No privacy permissions recorded or declared for this item.")
    }
}

@Suite struct EmptyStateTests {
    @Test func noneFoundOnlyWhenSourcesWereRead() {
        #expect(emptyStateText(noun: "extensions", problem: nil) == "No extensions found for this item.")
        let t = emptyStateText(noun: "extensions", problem: "pluginkit: failed (exit 1)")
        #expect(t.hasPrefix("Unknown:") && t.contains("pluginkit"))
        #expect(!t.contains("No extensions found"))
    }
}

@Suite struct ApprovalChipTests {
    private let matrix = CapabilityMatrix.phase1
    private func approval(enabled: Bool, allowed: Bool) -> Determination<BackgroundApproval> {
        let tok = matrix.confirmedSource(for: .btm, item: .startup, key: "k", os: OSVersion(26, 5))!
        return .confirmed(BackgroundApproval.from(enabled: enabled, allowed: allowed, notified: true, token: tok),
                          Evidence(source: .btm, locator: "t", osBuild: "x"))
    }

    @Test func eachDispositionHasItsOwnWording() {
        #expect(approvalChip(approval(enabled: true, allowed: true))?.text == "On in Login Items")
        #expect(approvalChip(approval(enabled: false, allowed: true))?.text == "Off in Login Items")
        #expect(approvalChip(approval(enabled: true, allowed: false))?.text == "Not allowed")
        #expect(approvalChip(approval(enabled: false, allowed: false))?.text == "Not allowed")   // policy outranks the toggle
    }

    @Test func unknownAndNoRecordNeverLookLikeOnOrOff() {
        let u = approvalChip(.unknown(.needsBTMImport))
        #expect(u?.text == "Unknown" && u?.a11y.contains("Unknown") == true)
        #expect(approvalChip(.notRecorded(Evidence(source: .btm, locator: "t", osBuild: "x")))?.text == "No background-task record")
    }

    @Test func diffBadgeWordingDistinguishesNewFromChanged() {
        #expect(SnapshotDiff.startupID("a") == "start:a" && SnapshotDiff.extensionID("a") == "ext:a")
    }
}
