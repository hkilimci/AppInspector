import Testing
import Foundation
@testable import InspectorModel

@Suite struct ModelTests {
    let os = OSVersion(26, 5, 1)

    @Test func tokenOnlyForAuthoritativeSource() {
        let m = CapabilityMatrix.phase1
        #expect(m.confirmedSource(for: .tccUser, item: .privacy, key: "kTCCServiceCamera", os: os) != nil)
        // Not authoritative for extensions, unknown source, or bundle-info source.
        #expect(m.confirmedSource(for: .tccUser, item: .extension, key: "x", os: os) == nil)
        #expect(m.confirmedSource(for: "nope", item: .privacy, key: "x", os: os) == nil)
        #expect(m.confirmedSource(for: .bundleInfo, item: .privacy, key: "x", os: os) == nil)
    }

    @Test func unvalidatedOSFlag() {
        let m = CapabilityMatrix.phase1
        let ok = m.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: OSVersion(26, 5))
        let future = m.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: OSVersion(27, 0))
        let old = m.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: OSVersion(15, 4))
        #expect(ok?.unvalidatedOS == false)
        #expect(future?.unvalidatedOS == true)
        #expect(old?.unvalidatedOS == true)
    }

    @Test func deniedRequiresToken() throws {
        let t = try #require(CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: os))
        #expect(PermissionState.denied(token: t).isNegative)
        #expect(!PermissionState.allowed().isNegative)
        #expect(!PermissionState.ask().isNegative)
    }

    @Test func osVersionOrdering() {
        #expect(OSVersion(15, 7) < OSVersion(26, 0))
        #expect(OSVersion(26, 5, 1) > OSVersion(26, 5))
    }

    @Test func catalogLookupFallsBackForUnknownService() {
        let i = ServiceCatalog.info(for: "kTCCServiceFutureThing")
        #expect(i.displayName == "FutureThing")
        #expect(i.settingsAnchor == nil)
        #expect(ServiceCatalog.info(for: "kTCCServiceCamera").settingsAnchor == "Privacy_Camera")
    }
}
