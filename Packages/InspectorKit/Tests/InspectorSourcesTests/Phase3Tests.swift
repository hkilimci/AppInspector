import Testing
import Foundation
import InspectorModel
@testable import InspectorSources

private let os = OSInfo(version: OSVersion(26, 5, 1), build: "25F80")
private func ev(_ s: SourceID = .tccUser) -> Evidence { Evidence(source: s, locator: "/Users/alice/Library/x", osBuild: "25F80", excerpt: "path /Users/bob/y") }

private func snapshot(permission: Determination<PermissionState>, extras: [ExtensionItem] = [], startup: [StartupItem] = []) -> Snapshot {
    let perm = PermissionItem(service: ServiceCatalog.info(for: "kTCCServiceCamera"), state: permission)
    var app = AppRecord(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.x.foo", version: "1.0", build: "1", signing: SigningSummary(kind: .developerID, teamID: "TEAM"))
    app.permissions = [perm]; app.extensions = extras; app.startupItems = startup
    return Snapshot(apps: [app], unattributed: [], sources: [SourceStatus(id: .btm, state: .needsImport, itemCount: 0)], os: os, fullDiskAccess: .granted)
}

private func extItem(_ id: String) -> ExtensionItem {
    ExtensionItem(id: id, kind: .app(point: "com.apple.share-services"), identifier: id, name: id, version: nil, path: "/Users/alice/Library/e.appex",
                  teamID: nil, state: .confirmed(.elected, ev(.pluginkit)), signals: AssociationSignals())
}

@Suite struct SnapshotDiffTests {
    @Test func firstScanHasNothingNew() {
        #expect(SnapshotDiff.between(nil, snapshot(permission: .unknown(.needsFullDiskAccess))).isEmpty)
    }

    @Test func newItemsAndChangedStatesAndRemovals() {
        let old = snapshot(permission: .unknown(.needsFullDiskAccess), extras: [extItem("a")])
        let tok = CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: os.version)!
        let new = snapshot(permission: .confirmed(.denied(token: tok), ev()), extras: [extItem("b")])
        let d = SnapshotDiff.between(old, new)
        #expect(d.newIDs == [SnapshotDiff.extensionID("b")])
        #expect(d.changedIDs == [SnapshotDiff.permissionID(owner: "/Applications/Foo.app", itemID: "kTCCServiceCamera")])
        #expect(d.removedCount == 1)
    }

    @Test func evidenceTimeAloneIsNotAChange() {
        func s(_ t: TimeInterval) -> Snapshot {
            snapshot(permission: .confirmed(.allowed(), Evidence(source: .tccUser, locator: "l", observedAt: Date(timeIntervalSince1970: t), osBuild: "x")))
        }
        #expect(SnapshotDiff.between(s(1), s(2)).isEmpty)
    }
}

@Suite struct DiffAutomationTests {
    private func perm(_ target: String, allowed: Bool) -> PermissionItem {
        let tok = CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: os.version)!
        let st: PermissionState = allowed ? .allowed() : .denied(token: tok)
        return PermissionItem(service: ServiceCatalog.info(for: "kTCCServiceAppleEvents"), state: .confirmed(st, ev()), indirectObject: target)
    }
    private func snap(_ items: [PermissionItem]) -> Snapshot {
        var app = AppRecord(path: "/Applications/Foo.app", name: "Foo", bundleID: "x", version: "1", build: "1", signing: SigningSummary(kind: .adHoc))
        app.permissions = items
        return Snapshot(apps: [app], unattributed: [], sources: [], os: os, fullDiskAccess: .granted)
    }

    @Test func addingOrChangingOneAutomationTargetIsVisible() {
        let old = snap([perm("com.apple.mail", allowed: true), perm("com.apple.finder", allowed: true)])
        let added = SnapshotDiff.between(old, snap([perm("com.apple.mail", allowed: true), perm("com.apple.finder", allowed: true), perm("com.apple.notes", allowed: true)]))
        #expect(added.newIDs.count == 1 && added.newIDs.first!.hasSuffix("kTCCServiceAppleEvents:com.apple.notes"))
        let changed = SnapshotDiff.between(old, snap([perm("com.apple.mail", allowed: true), perm("com.apple.finder", allowed: false)]))
        #expect(changed.changedIDs.count == 1 && changed.changedIDs.first!.hasSuffix(":com.apple.finder"))
    }
}

@Suite struct ExporterTests {
    @Test func pathRedactionCoversEveryString() throws {
        let s = snapshot(permission: .confirmed(.allowed(), ev()), extras: [extItem("a")])
        let plain = String(decoding: try SnapshotExporter.json(s, redaction: .none, home: "/Users/alice"), as: UTF8.self)
        #expect(plain.contains("/Users/alice/Library"))
        let red = String(decoding: try SnapshotExporter.json(s, redaction: .paths, home: "/Users/alice"), as: UTF8.self)
        #expect(!red.contains("alice") && !red.contains("bob"))
        #expect(red.contains("~/Library/e.appex"))                 // path field
        #expect(red.contains("~/Library/x"))                       // evidence locator
        #expect(red.contains("/Users/<user>/y"))                   // another user's path inside an excerpt
        #expect(red.contains("\"redaction\" : \"paths\""))
    }

    @Test func exportRoundTripsAndKeepsUnknownAsUnknown() throws {
        let s = snapshot(permission: .unknown(.needsFullDiskAccess))
        let data = try SnapshotExporter.json(s, redaction: .none)
        let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(doc["schema"] as? Int == 1)
        let apps = doc["apps"] as! [[String: Any]]
        let perm = (apps[0]["permissions"] as! [[String: Any]])[0]
        let state = perm["state"] as! [String: Any]
        #expect(state["kind"] as? String == "unknown")
        #expect(state["value"] == nil)
    }

    /// Redaction runs on decoded values: a home path with quotes and backslashes must not survive JSON escaping.
    @Test func homeWithQuotesAndBackslashesIsRedacted() throws {
        let home = "/Volumes/Odd \"name\"\\x/me"
        let e = Evidence(source: .tccUser, locator: "\(home)/Library/a", osBuild: "x", excerpt: "see \(home)/Documents")
        let s = snapshot(permission: .confirmed(.allowed(), e))
        let out = String(decoding: try SnapshotExporter.json(s, redaction: .paths, home: home), as: UTF8.self)
        #expect(!out.contains("Odd") && !out.contains("Volumes"), "home path leaked: \(out.prefix(400))")
        #expect(out.contains("~/Library/a") && out.contains("~/Documents"))
        let full = String(decoding: try SnapshotExporter.json(s, redaction: .none, home: home), as: UTF8.self)
        #expect(full.contains("Odd"))
    }

    @Test func redactLeavesAlreadyRedactedTextAlone() {
        #expect(SnapshotExporter.redact("/Users/<user>/x ~/y", home: "/Users/alice") == "/Users/<user>/x ~/y")
    }
}

@Suite struct SourceCatalogTests {
    @Test func everyReportedSourceHasAboutText() {
        let ids: [SourceID] = [.appInventory, .tccUser, .tccSystem, .pluginkit, .systemExtensionsCtl, .systemExtensionsDB,
                               .launchdPlists, .launchctlDomain, .launchctlDisabled, .launchctlJobs, .bundledHelpers, .btm]
        for id in ids { #expect(SourceCatalog.info(for: id) != nil, "missing About text for \(id)") }
        for i in SourceCatalog.all { #expect(!i.limits.isEmpty && !i.reads.isEmpty) }
    }
}
