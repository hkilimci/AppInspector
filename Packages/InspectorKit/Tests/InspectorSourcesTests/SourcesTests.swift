import Testing
import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform
@testable import InspectorSources

private let cols = ["service", "client", "client_type", "auth_value", "auth_reason", "csreq", "last_modified"]
private func row(_ service: String, _ client: String, type: Int64 = 0, value: Int64 = 2, reason: Int64 = 3,
                 ts: Int64 = 1_700_000_000) -> [String: SQLValue] {
    ["service": .text(service), "client": .text(client), "client_type": .int(type), "auth_value": .int(value),
     "auth_reason": .int(reason), "csreq": .null, "last_modified": .int(ts)]
}
private let os = OSInfo(version: OSVersion(26, 5, 1), build: "25F80")

private func makeApp(in dir: URL, name: String, id: String, usage: [String: String] = [:]) throws -> URL {
    let app = dir.appendingPathComponent("\(name).app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
    for (k, v) in usage { plist[k] = v }
    try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func orchestrator(root: URL, fda: AccessLevel, user: @escaping @Sendable (String) throws -> TCCTable,
                          system: (@Sendable (String) throws -> TCCTable)? = nil) -> ScanOrchestrator {
    let sys = system ?? user
    let reader: TCCCollector.TableReader = { path in path.hasPrefix("/user") ? try user(path) : try sys(path) }
    return ScanOrchestrator(
        inventory: AppInventoryCollector(roots: [root]),
        tcc: TCCCollector(userPath: "/user/TCC.db", systemPath: "/system/TCC.db", reader: reader),
        fdaProbe: { fda }, osInfo: { os }, csreqChecker: { _, _ in nil }, phase2Enabled: false)
}

@Suite struct SourcesTests {
    @Test func attributionAndStates() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let foo = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSCameraUsageDescription": "scan docs", "NSContactsUsageDescription": "friends"])
        _ = try makeApp(in: d, name: "Bar", id: "com.x.bar")

        let user = TCCTable(columns: cols, rows: [
            row("kTCCServiceCamera", "com.x.foo", value: 2),
            row("kTCCServiceMicrophone", "com.x.foo", value: 0),                       // denied, no declared usage
            row("kTCCServiceCamera", "com.unknown.thing", value: 2),                  // unresolved bundle id
            row("kTCCServiceSystemPolicyAllFiles", foo.path + "/Contents/MacOS/helper", type: 1, value: 2), // path inside Foo
            row("kTCCServiceAccessibility", "/usr/local/bin/tool", type: 1, value: 2),                       // command-line
        ])
        let snap = await orchestrator(root: d, fda: .granted, user: { _ in user }).scan()

        let fooRec = try #require(snap.apps.first { $0.bundleID == "com.x.foo" })
        func state(_ svc: String) -> Determination<PermissionState>? { fooRec.permissions.first { $0.service.raw == svc }?.state }

        guard case .confirmed(let cam, let ev)? = state("kTCCServiceCamera") else { Issue.record("camera"); return }
        #expect(cam.kind == .allowed)
        #expect(ev.source == .tccUser && ev.osBuild == "25F80" && !ev.unvalidatedOS)
        guard case .confirmed(let mic, _)? = state("kTCCServiceMicrophone") else { Issue.record("mic"); return }
        #expect(mic.kind == .denied)
        // Declared, DBs read OK, no row → notRecorded (and declared evidence kept).
        guard case .notRecorded? = state("kTCCServiceAddressBook") else { Issue.record("contacts"); return }
        #expect(fooRec.permissions.first { $0.service.raw == "kTCCServiceAddressBook" }?.declared?.excerpt == "friends")
        guard case .confirmed(let fda, _)? = state("kTCCServiceSystemPolicyAllFiles") else { Issue.record("fda"); return }
        #expect(fda.kind == .allowed)

        let bar = try #require(snap.apps.first { $0.bundleID == "com.x.bar" })
        #expect(bar.permissions.isEmpty)
        #expect(snap.unattributed.contains { $0.kind == .unresolvedBundleID && $0.client == "com.unknown.thing" })
        #expect(snap.unattributed.contains { $0.kind == .commandLine && $0.client == "/usr/local/bin/tool" })
        #expect(snap.sources.filter { $0.state == .ok }.count == 3)  // inventory + 2 DBs
    }

    @Test func managedGrantFlagged() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo")
        let t = TCCTable(columns: cols, rows: [row("kTCCServiceScreenCapture", "com.x.foo", value: 2, reason: 6)])
        let snap = await orchestrator(root: d, fda: .granted, user: { _ in t }).scan()
        guard case .confirmed(let s, _)? = snap.apps[0].permissions.first?.state else { Issue.record("state"); return }
        #expect(s.managed)
    }

    @Test func latestRowWinsAcrossDatabases() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo")
        let old = TCCTable(columns: cols, rows: [row("kTCCServiceCamera", "com.x.foo", value: 2, ts: 100)])
        let new = TCCTable(columns: cols, rows: [row("kTCCServiceCamera", "com.x.foo", value: 0, ts: 200)])
        let snap = await orchestrator(root: d, fda: .granted, user: { _ in old }, system: { _ in new }).scan()
        guard case .confirmed(let s, _)? = snap.apps[0].permissions.first?.state else { Issue.record("state"); return }
        #expect(s.kind == .denied)
    }

    // MARK: fail-to-Unknown: the hard rule

    /// Every degraded-source scenario must yield only `.unknown` states: never denied, never notRecorded.
    @Test(arguments: [
        "fdaNotGranted", "openFailsFdaUnknown", "missingColumns", "readerThrowsGeneric",
        "allRowsGarbled", "someRowsGarbled",
    ])
    func degradedSourceYieldsOnlyUnknown(scenario: String) async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSCameraUsageDescription": "x", "NSMicrophoneUsageDescription": "y"])

        var g = row("kTCCServiceCamera", "com.x.foo"); g["auth_value"] = .text("??")
        let garbled = g
        let reader: @Sendable (String) throws -> TCCTable
        let fda: AccessLevel
        switch scenario {
        case "fdaNotGranted": fda = .notGranted; reader = { _ in TCCTable(columns: cols, rows: []) }
        case "openFailsFdaUnknown": fda = .indeterminate("probe"); reader = { _ in throw SQLiteReadError.openFailed(code: 23, message: "auth denied") }
        case "missingColumns": fda = .granted; reader = { _ in TCCTable(columns: ["service"], rows: []) }
        case "readerThrowsGeneric": fda = .granted; reader = { _ in throw SQLiteReadError.queryFailed(code: 11, message: "corrupt") }
        case "allRowsGarbled": fda = .granted; reader = { _ in TCCTable(columns: cols, rows: [garbled]) }
        case "someRowsGarbled": fda = .granted; reader = { _ in TCCTable(columns: cols, rows: [garbled, row("kTCCServiceCamera", "other.app")]) }
        default: fatalError()
        }
        let snap = await orchestrator(root: d, fda: fda, user: reader).scan()
        let perms = snap.apps.flatMap(\.permissions)
        #expect(!perms.isEmpty)   // declared services still listed
        for p in perms {
            guard case .unknown = p.state else { Issue.record("\(scenario): \(p.service.raw) not unknown: \(p.state)"); continue }
            #expect(p.declared != nil)   // declared capability survives as a capability, not a state
        }
        #expect(snap.sources.filter { [.tccUser, .tccSystem].contains($0.id) }.allSatisfy { $0.state != .ok })
    }

    @Test func unreadableUserDBButReadableSystemStaysUnknownForEitherStoreServices() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSCameraUsageDescription": "x"])
        let sys = TCCTable(columns: cols, rows: [])
        let snap = await orchestrator(root: d, fda: .granted,
                                      user: { _ in throw SQLiteReadError.queryFailed(code: 5, message: "busy") },
                                      system: { _ in sys }).scan()
        guard case .unknown? = snap.apps[0].permissions.first?.state else { Issue.record("expected unknown"); return }
    }

    @Test func unvalidatedOSFlagPropagatesToEvidence() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo")
        let t = TCCTable(columns: cols, rows: [row("kTCCServiceCamera", "com.x.foo")])
        var o = orchestrator(root: d, fda: .granted, user: { _ in t })
        o.osInfo = { OSInfo(version: OSVersion(27, 0), build: "27A1") }
        let snap = await o.scan()
        guard case .confirmed(_, let ev)? = snap.apps[0].permissions.first?.state else { Issue.record("state"); return }
        #expect(ev.unvalidatedOS)
    }

    @Test func withTimeoutReturnsNilOnSlowBody() async {
        let r: Int? = await withTimeout(.milliseconds(50)) { try? await Task.sleep(for: .seconds(5)); return 1 }
        #expect(r == nil)
        let ok: Int? = await withTimeout(.seconds(5)) { 7 }
        #expect(ok == 7)
    }

    @Test func inventoryFindsNestedApps() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let sub = d.appendingPathComponent("Utilities"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makeApp(in: d, name: "A", id: "a"); _ = try makeApp(in: sub, name: "B", id: "b")
        let found = AppInventoryCollector(roots: [d]).findApps().map { $0.lastPathComponent }.sorted()
        #expect(found == ["A.app", "B.app"])
    }

    @Test func automationDecisionsAreIndependentPerTarget() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSAppleEventsUsageDescription": "Automation"])
        func automation(_ target: String, value: Int64, ts: Int64) -> [String: SQLValue] {
            var r = row("kTCCServiceAppleEvents", "com.x.foo", value: value, ts: ts)
            r["indirect_object_identifier"] = .text(target)
            return r
        }
        let columns = cols + ["indirect_object_identifier"]
        let user = TCCTable(columns: columns, rows: [
            automation("com.apple.finder", value: 0, ts: 100),
            automation("com.apple.mail", value: 0, ts: 300),
        ])
        let system = TCCTable(columns: columns, rows: [automation("com.apple.finder", value: 2, ts: 200)])
        let snap = await orchestrator(root: d, fda: .granted, user: { _ in user }, system: { _ in system }).scan()
        let items = try #require(snap.apps.first).permissions
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        for (target, expected) in [("com.apple.finder", PermissionState.Kind.allowed), ("com.apple.mail", .denied)] {
            let item = try #require(items.first { $0.indirectObject == target })
            guard case .confirmed(let state, let evidence) = item.state else { Issue.record("Missing target decision"); continue }
            #expect(state.kind == expected)
            #expect(item.displayName.contains(target))
            #expect(evidence.locator.contains("indirect_object_identifier=\(target)"))
            #expect(item.declared != nil)
        }
    }

    @Test(arguments: [Int64(0), 2])
    func mismatchedSignatureIsNeutral(value: Int64) async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo")
        var r = row("kTCCServiceCamera", "com.x.foo", value: value)
        r["csreq"] = .blob(Data([1, 2]))
        let table = TCCTable(columns: cols, rows: [r])
        var scan = orchestrator(root: d, fda: .granted, user: { _ in table })
        scan.csreqChecker = { _, _ in false }
        let snap = await scan.scan()
        let item = try #require(snap.apps.first?.permissions.first)
        guard case .recordedForDifferentSignature(let evidence) = item.state else { Issue.record("Stale decision was not neutral"); return }
        guard case .confirmed(false, let signatureEvidence)? = item.signatureMatch else { Issue.record("Missing mismatch evidence"); return }
        #expect(item.state.evidence == evidence)
        #expect(evidence == signatureEvidence)
        #expect(evidence.excerpt?.contains("auth_value=\(value)") == true)
    }

    @Test func bundleIDGrantIsCheckedForEveryInstalledCopy() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        for name in ["FooA", "FooB"] { _ = try makeApp(in: d, name: name, id: "com.x.foo", usage: ["NSCameraUsageDescription": "Camera"]) }
        var r = row("kTCCServiceCamera", "com.x.foo")
        r["csreq"] = .blob(Data([1, 2]))
        let table = TCCTable(columns: cols, rows: [r])
        var scan = orchestrator(root: d, fda: .granted, user: { _ in table })
        scan.csreqChecker = { _, _ in true }
        let snap = await scan.scan()
        #expect(snap.apps.count == 2)
        #expect(snap.unattributed.isEmpty)
        for app in snap.apps {
            guard case .confirmed(let state, _)? = app.permissions.first?.state else { Issue.record("Copy lost its bundle-ID decision"); continue }
            #expect(state.kind == .allowed)
            guard case .confirmed(true, _)? = app.permissions.first?.signatureMatch else { Issue.record("Copy was not checked"); continue }
        }

        // The matching copy sorts second, so choosing only the first path would misattribute the grant.
        scan.csreqChecker = { _, url in url.lastPathComponent == "FooB.app" }
        let mixed = await scan.scan()
        guard case .recordedForDifferentSignature? = mixed.apps.first(where: { $0.name == "FooA" })?.permissions.first?.state else {
            Issue.record("Mismatching copy not marked stale"); return
        }
        guard case .confirmed(let state, _)? = mixed.apps.first(where: { $0.name == "FooB" })?.permissions.first?.state else {
            Issue.record("Matching copy lost its grant"); return
        }
        #expect(state.kind == .allowed)
    }

    @Test func timeoutDoesNotWaitForBlockedWork() async {
        let release = DispatchSemaphore(value: 0)
        // A fallback keeps the regression test bounded even with the old task-group implementation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        defer { release.signal() }
        let clock = ContinuousClock(), start = ContinuousClock.now
        let result: Int? = await withTimeout(.milliseconds(30)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { release.wait(); continuation.resume(returning: 7) }
            }
        }
        #expect(result == nil)
        #expect(start.duration(to: clock.now) < .milliseconds(500))
    }

    @Test func callerCancellationDoesNotWaitForBlockedWork() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        defer { release.signal() }
        let operation = Task {
            await withTimeout(.seconds(10)) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { started.signal(); release.wait(); continuation.resume(returning: 7) }
                }
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { started.wait(); continuation.resume() }
        }
        let start = ContinuousClock.now
        operation.cancel()
        #expect(await operation.value == nil)
        #expect(start.duration(to: .now) < .milliseconds(500))
    }

    @Test func blockedTCCReaderProducesTimedOutSnapshot() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSCameraUsageDescription": "Camera"])
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        defer { release.signal() }
        var scan = orchestrator(root: d, fda: .granted, user: { _ in
            release.wait()
            return TCCTable(columns: cols, rows: [row("kTCCServiceCamera", "com.x.foo", value: 0)])
        })
        scan.collectorTimeout = .milliseconds(100)
        let start = ContinuousClock.now
        let snap = await scan.scan()
        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(snap.sources.filter { [.tccUser, .tccSystem].contains($0.id) }.allSatisfy { $0.state == .timedOut })
        let item = try #require(snap.apps.first?.permissions.first)
        guard case .unknown(.timedOut) = item.state else { Issue.record("Timeout became a decision"); return }
    }
}

@Suite struct RecordedInTests {
    /// Rows whose value isn't decoded stay Unknown, but are marked as recorded so they can still be reset.
    @Test func undecodedRowIsMarkedRecordedAndAbsenceIsNot() async throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        _ = try makeApp(in: d, name: "Foo", id: "com.x.foo", usage: ["NSCameraUsageDescription": "x"])
        let rows = [row("kTCCServiceSystemPolicyAppData", "com.gone.app", value: 5)]
        let snap = await orchestrator(root: d, fda: .granted, user: { _ in TCCTable(columns: cols, rows: rows) },
                                      system: { _ in TCCTable(columns: cols, rows: []) }).scan()
        let gone = try #require(snap.unattributed.first { $0.client == "com.gone.app" })
        let item = try #require(gone.permissions.first)
        guard case .unknown(.formatUnrecognized(.tccUser, let why)) = item.state else { Issue.record("\(item.state)"); return }
        #expect(why == "auth_value 5")
        #expect(item.recordedIn == [.tccUser])
        let declaredOnly = try #require(snap.apps.first { $0.bundleID == "com.x.foo" }?.permissions.first)
        #expect(declaredOnly.recordedIn.isEmpty)
    }
}
