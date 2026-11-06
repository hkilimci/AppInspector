import Testing
import InspectorModel
import InspectorPlatform
@testable import AppInspector

@Suite @MainActor struct ResetTests {
    private let ev = Evidence(source: .tccUser, locator: "test row", osBuild: "25F80")
    private let gone = "com.example.appinspector.tests.never-installed"

    /// Rows back confirmed and different-signature states unless `recordedIn` says otherwise.
    private func item(_ raw: String, _ state: Determination<PermissionState>, target: String? = nil,
                      recordedIn: Set<SourceID>? = nil) -> PermissionItem {
        let backed: Set<SourceID> = switch state {
        case .confirmed, .recordedForDifferentSignature: [.tccUser]
        default: []
        }
        return PermissionItem(service: ServiceCatalog.info(for: raw), state: state, indirectObject: target,
                              recordedIn: recordedIn ?? backed)
    }

    private func store(_ clients: [UnattributedClient]) -> InspectorStore {
        let s = InspectorStore()
        let app = AppRecord(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.x.foo", version: nil,
                            build: nil, signing: SigningSummary(kind: .unsigned))
        s.snapshot = Snapshot(apps: [app], unattributed: clients, sources: [],
                              os: OSInfo(version: OSVersion(26), build: "25F80"), fullDiskAccess: .granted)
        return s
    }

    @Test func notInstalledFilterShowsOnlyStaleBundleClients() {
        let allowed = item("kTCCServiceCamera", .confirmed(.allowed(managed: false, authReason: 2), ev))
        let s = store([
            UnattributedClient(kind: .unresolvedBundleID, client: gone, permissions: [allowed]),
            UnattributedClient(kind: .unresolvedBundleID, client: "com.apple.finder", permissions: [allowed]),
            UnattributedClient(kind: .commandLine, client: "/usr/local/bin/tool", permissions: [allowed]),
        ])
        s.showApple = true
        #expect(s.staleBundleIDs == [gone])          // Finder resolves through Launch Services
        s.filter = .notInstalled
        #expect(s.visibleApps.isEmpty)
        #expect(s.visibleUnattributed.map(\.client) == [gone])
        #expect(s.staleClients.map(\.client) == [gone])
    }

    @Test func requestsCoverRecordedServicesOnceAndSkipNonRows() {
        let c = UnattributedClient(kind: .unresolvedBundleID, client: gone, permissions: [
            item("kTCCServiceAppleEvents", .confirmed(.allowed(managed: false, authReason: 2), ev), target: "com.apple.finder"),
            item("kTCCServiceAppleEvents", .confirmed(.ask(authReason: 2), ev), target: "com.apple.mail"),
            item("kTCCServiceMicrophone", .recordedForDifferentSignature(ev)),
            item("kTCCServiceCamera", .notRecorded(ev)),
            item("kTCCServicePhotos", .unknown(.needsFullDiskAccess)),
        ])
        let s = store([c])
        #expect(s.resetRequests(for: c).map(\.tccutilService) == ["AppleEvents", "Microphone"])
        #expect(s.resetRequests(for: c, service: "kTCCServiceCamera").isEmpty)
        #expect(s.resetRequests(for: c, service: "kTCCServiceMicrophone").count == 1)
    }

    /// `auth_value 5` on `SystemPolicyAppData`: the value isn't decoded (Unknown), but the row exists and can be reset.
    @Test func undecodedRowsAreStillResettable() {
        let c = UnattributedClient(kind: .unresolvedBundleID, client: gone, permissions: [
            item("kTCCServiceSystemPolicyAppData", .unknown(.formatUnrecognized(.tccUser, "auth_value 5")), recordedIn: [.tccUser]),
            item("kTCCServicePhotos", .unknown(.formatUnrecognized(.tccUser, "2 unreadable rows; absence not trustworthy"))),
        ])
        let s = store([c])
        #expect(s.resetRequests(for: c).map(\.tccutilService) == ["SystemPolicyAppData"])
        #expect(s.staleClients.flatMap { s.resetRequests(for: $0) }.count == 1)
    }

    @Test func commandLineClientsAreNeverResettable() {
        let c = UnattributedClient(kind: .commandLine, client: "/usr/local/bin/tool", permissions: [
            item("kTCCServiceAccessibility", .confirmed(.allowed(managed: false, authReason: 2), ev))])
        let s = store([c])
        #expect(s.resetRequests(for: c).isEmpty)
        s.requestReset(of: c)
        #expect(s.pendingReset == nil)
    }

    @Test func resetAlwaysAsksFirst() {
        let c = UnattributedClient(kind: .unresolvedBundleID, client: gone, permissions: [
            item("kTCCServiceCamera", .confirmed(.allowed(managed: false, authReason: 2), ev))])
        let s = store([c])
        s.requestResetAllStale()
        #expect(s.pendingReset?.requests == [TCCResetRequest(service: "kTCCServiceCamera", bundleID: gone)])
        #expect(s.pendingReset?.message.contains("administrator rights") == true)
    }
}
