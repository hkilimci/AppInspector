import Testing
import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform
@testable import InspectorSources

private let os = OSInfo(version: OSVersion(26, 5, 1), build: "25F80")

private func ok(_ s: String) -> ProcessResult { ProcessResult(status: 0, stdout: Data(s.utf8), stderr: Data()) }
private func fail(_ code: Int32 = 1, _ err: String = "boom") -> ProcessResult { ProcessResult(status: code, stdout: Data(), stderr: Data(err.utf8)) }

private let pluginkitText = """
     com.vendor.foo.share(1.0)
\t            Path = /Applications/Foo.app/Contents/PlugIns/Share.appex
\t             SDK = com.apple.share-services
\t    Display Name = Foo Share
\t        Platform = macOS

+    com.vendor.foo.finder(1.0)
\t            Path = /Applications/Foo.app/Contents/PlugIns/Finder.appex
\t             SDK = com.apple.FinderSync
\t   Parent Bundle = /Applications/Foo.app

-    com.vendor.foo.ql(1.0)
\t            Path = /Applications/Foo.app/Contents/PlugIns/QL.appex
\t             SDK = com.apple.quicklook.preview

!    com.vendor.foo.dbg(1.0)
\t             SDK = com.apple.thing

     com.ios.only(1.0)
\t             SDK = com.apple.thing
\t        Platform = iOS
"""

private let ctlText = [
    "4 extension(s)",
    "--- com.apple.system_extension.network_extension (Go to 'System Settings')",
    "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]",
    "*\t*\tTEAMFOO111\tcom.vendor.foo.nwext (1.0/1)\tFoo VPN\t[activated enabled]",
    "\t*\tTEAMFOO111\tcom.vendor.foo.wait (1.0/1)\tFoo Wait\t[activated waiting for user]",
    "\t\tTEAMFOO111\tcom.vendor.foo.off (1.0/1)\tFoo Off\t[activated disabled]",
    "\t\tTEAMFOO111\tcom.vendor.foo.weird (1.0/1)\tFoo Weird\t[some future state]",
].joined(separator: "\n")

private func dbPlist() -> Data {
    let d: [String: Any] = ["extensions": [[
        "identifier": "com.vendor.foo.nwext", "teamID": "TEAMFOO111", "state": "activated_enabled",
        "container": ["bundlePath": "/Applications/Foo.app"],
        "originPath": "/Applications/Foo.app/Contents/Library/SystemExtensions/nw.systemextension",
        "references": [["appIdentifier": "com.vendor.foo", "teamID": "TEAMFOO111"]],
    ]]]
    return try! PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
}

private func extCollector(pluginkit: ProcessResult? = nil, ctl: ProcessResult? = nil, db: Data? = nil) -> ExtensionCollector {
    ExtensionCollector(
        run: { exe, _ in
            if exe.hasSuffix("pluginkit") { return pluginkit ?? ok(pluginkitText) }
            return ctl ?? ok(ctlText)
        },
        readFile: { $0 == "/Library/SystemExtensions/db.plist" ? (db ?? dbPlist()) : nil },
        os: os)
}

@Suite struct ExtensionCollectorTests {
    @Test func pluginkitMarksMapToStatesWithoutInventingEnabledDisabled() async {
        let c = await extCollector().collectPluginkit()
        func state(_ id: String) -> Determination<ExtensionState>? { c.items.first { $0.identifier == id }?.state }
        guard case .confirmed(let none, let ev)? = state("com.vendor.foo.share") else { Issue.record("share"); return }
        #expect(none.kind == .systemDefault)                       // no mark → "System default", never Enabled/Disabled
        #expect(ev.source == .pluginkit && !ev.unvalidatedOS)
        guard case .confirmed(let plus, _)? = state("com.vendor.foo.finder") else { Issue.record("finder"); return }
        #expect(plus.kind == .elected)
        guard case .confirmed(let minus, _)? = state("com.vendor.foo.ql") else { Issue.record("ql"); return }
        #expect(minus.kind == .ignored && minus.isNegative)
        guard case .unknown(.formatUnrecognized)? = state("com.vendor.foo.dbg") else { Issue.record("dbg should be unknown"); return }
        #expect(!c.items.contains { $0.identifier == "com.ios.only" })   // other platforms excluded
        #expect(c.statuses.first?.state == .ok)
    }

    @Test func pluginkitSignalsCarryParentAndPath() async throws {
        let c = await extCollector().collectPluginkit()
        let f = try #require(c.items.first { $0.identifier == "com.vendor.foo.finder" })
        #expect(f.signals.parentBundlePath == "/Applications/Foo.app")
        #expect(f.signals.itemPath == "/Applications/Foo.app/Contents/PlugIns/Finder.appex")
        #expect(f.kind == .app(point: "com.apple.FinderSync"))
    }

    @Test(arguments: ["nonzero", "garbage"])
    func pluginkitFailureYieldsNoItemsAndFailedStatus(mode: String) async {
        let r = mode == "nonzero" ? fail() : ok("what is this\nnot pluginkit")
        let c = await extCollector(pluginkit: r).collectPluginkit()
        #expect(c.items.isEmpty)
        #expect(c.statuses.first?.state != .ok)
    }

    @Test func systemExtensionStatesAndEnrichment() async throws {
        let c = await extCollector().collectSystemExtensions()
        func state(_ id: String) -> Determination<ExtensionState>? { c.items.first { $0.identifier == id }?.state }
        guard case .confirmed(let en, _)? = state("com.vendor.foo.nwext") else { Issue.record("nwext"); return }
        #expect(en.kind == .activatedEnabled)
        guard case .confirmed(let w, _)? = state("com.vendor.foo.wait") else { Issue.record("wait"); return }
        #expect(w.kind == .waitingForUser && !w.isNegative)
        guard case .confirmed(let off, _)? = state("com.vendor.foo.off") else { Issue.record("off"); return }
        #expect(off.kind == .disabled && off.isNegative)
        guard case .unknown(.formatUnrecognized)? = state("com.vendor.foo.weird") else { Issue.record("weird"); return }

        let nw = try #require(c.items.first { $0.identifier == "com.vendor.foo.nwext" })
        #expect(nw.signals.parentBundlePath == "/Applications/Foo.app")
        #expect(nw.signals.associatedBundleIDs == ["com.vendor.foo"])
        #expect(nw.signals.teamID == "TEAMFOO111")
        #expect(nw.kind == .system(category: "com.apple.system_extension.network_extension"))
    }

    @Test(arguments: ["nonzero", "garbage", "malformedRow", "empty"])
    func ctlFailureMakesEveryStateUnknown(mode: String) async {
        let r: ProcessResult = switch mode {
        case "nonzero": fail(1, "denied")
        case "malformedRow": ok("1 extension(s)\n--- com.apple.system_extension.network_extension (x)\n*\t*\tTEAM\tbroken row\tName\t[activated enabled]\n")
        case "empty": ok("")
        default: ok("Unexpected\ntext")
        }
        let c = await extCollector(ctl: r).collectSystemExtensions()
        #expect(!c.items.isEmpty)               // db.plist still lists them
        for i in c.items { guard case .unknown = i.state else { Issue.record("\(i.identifier) not unknown"); continue } }
        #expect(c.statuses.contains { $0.id == .systemExtensionsCtl && $0.state != .ok })
    }

    @Test func unreadableDBStillGivesCtlItems() async {
        let c = await ExtensionCollector(run: { _, _ in ok(ctlText) }, readFile: { _ in nil }, os: os).collectSystemExtensions()
        #expect(c.items.count == 4)
        #expect(c.statuses.contains { $0.id == .systemExtensionsDB && $0.state != .ok })
    }

    @Test func unvalidatedOSIsFlagged() async {
        var coll = extCollector()
        coll.os = OSInfo(version: OSVersion(27, 0), build: "27A1")
        let c = await coll.collectPluginkit()
        guard case .confirmed(_, let ev)? = c.items.first?.state else { Issue.record("state"); return }
        #expect(ev.unvalidatedOS)
    }
}

// MARK: - Startup

private let guiServicesText = """
gui/501 = {
\ttype = login
\tservices = {
\t\t     812      - \tcom.vendor.agent
\t\t       0      - \tcom.vendor.loaded.idle
\t\t       0      - \tcom.vendor.sm.helper
\t\t       0      - \tcom.apple.something
\t\t       0      - \tcom.vendor.loginhelper
\t}
}
"""
private let sysServicesText = "system = {\n\tservices = {\n\t\t   523      - \tcom.vendor.daemon\n\t}\n}"
private let guiDisabledText = "\tdisabled services = {\n\t\t\"com.vendor.disabled.agent\" => disabled\n\t\t\"com.vendor.agent\" => enabled\n\t}"
private let sysDisabledText = "\tdisabled services = {\n\t}"
private let smJob = """
gui/501/com.vendor.sm.helper = {
\tpath = (submitted by smd.336)
\ttype = Submitted
\tmanaged_by = com.apple.xpc.ServiceManagement
\tstate = not running
\tparent bundle identifier = com.vendor.foo
}
"""

private func plist(_ label: String, program: String = "/usr/local/bin/x", extra: [String: Any] = [:]) -> Data {
    var d: [String: Any] = ["Label": label, "ProgramArguments": [program], "RunAtLoad": true]
    for (k, v) in extra { d[k] = v }
    return try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
}

private struct Fake: Sendable {
    var guiServices: ProcessResult = ok(guiServicesText)
    var sysServices: ProcessResult = ok(sysServicesText)
    var guiDisabled: ProcessResult = ok(guiDisabledText)
    var sysDisabled: ProcessResult = ok(sysDisabledText)
    var files: [String: Data] = [
        "/home/me/Library/LaunchAgents/a.plist": plist("com.vendor.agent"),
        "/home/me/Library/LaunchAgents/b.plist": plist("com.vendor.disabled.agent"),
        "/Library/LaunchAgents/c.plist": plist("com.vendor.notloaded"),
        "/Library/LaunchDaemons/d.plist": plist("com.vendor.daemon", extra: ["AssociatedBundleIdentifiers": ["com.vendor.foo"]]),
        "/Library/LaunchDaemons/bad.plist": Data("junk".utf8),
    ]
    var unreadable: Set<String> = ["/Library/LaunchDaemons/locked.plist"]

    func collector(appPaths: [String] = []) -> StartupCollector {
        let me = self
        return StartupCollector(
            run: { _, args in
                switch args {
                case ["print", "gui/501"]: return me.guiServices
                case ["print", "system"]: return me.sysServices
                case ["print-disabled", "gui/501"]: return me.guiDisabled
                case ["print-disabled", "system"]: return me.sysDisabled
                case ["print", "gui/501/com.vendor.sm.helper"]: return ok(smJob)
                default: return fail(113, "Could not find service")
                }
            },
            readFile: { me.files[$0] },
            listDirectory: { dir in
                let all = Set(me.files.keys).union(me.unreadable)
                let hit = all.filter { ($0 as NSString).deletingLastPathComponent == dir }.sorted()
                return hit.isEmpty ? nil : hit
            },
            os: os, uid: 501, home: "/home/me", appPaths: appPaths)
    }
}

@Suite struct StartupCollectorTests {
    func item(_ c: StartupCollection, _ label: String) -> StartupItem? { c.items.first { $0.label == label } }

    @Test func loadStateOverrideAndSignals() async throws {
        let c = await Fake().collector().collect()

        guard case .confirmed(let run, _)? = item(c, "com.vendor.agent")?.loadState else { Issue.record("agent"); return }
        #expect(run.kind == .running(pid: 812))
        guard case .confirmed(let nl, _)? = item(c, "com.vendor.notloaded")?.loadState else { Issue.record("notloaded"); return }
        #expect(nl.kind == .notLoaded)
        guard case .confirmed(let dm, _)? = item(c, "com.vendor.daemon")?.loadState else { Issue.record("daemon"); return }
        #expect(dm.kind == .running(pid: 523))

        guard case .confirmed(let dis, _)? = item(c, "com.vendor.disabled.agent")?.override else { Issue.record("override"); return }
        #expect(dis.kind == .disabled && dis.isNegative)
        guard case .confirmed(let en, _)? = item(c, "com.vendor.agent")?.override else { Issue.record("enabled"); return }
        #expect(en.kind == .enabled)
        guard case .notRecorded? = item(c, "com.vendor.notloaded")?.override else { Issue.record("no override"); return }

        let d = try #require(item(c, "com.vendor.daemon"))
        #expect(d.kind == .launchDaemon && d.domain == .system)
        #expect(d.signals.associatedBundleIDs == ["com.vendor.foo"])
        #expect(d.runAtLoad == true)
        // BTM approval is never claimed without an import.
        guard case .unknown(.needsBTMImport) = d.approval else { Issue.record("approval"); return }
    }

    @Test func unreadableAndGarbledPlistsAreUnknownNotMissing() async {
        let c = await Fake().collector().collect()
        for name in ["bad", "locked"] {
            guard let i = item(c, name) else { Issue.record("\(name) item missing"); continue }
            guard case .unknown = i.loadState, case .unknown = i.override else { Issue.record("\(name) should be unknown"); continue }
        }
        #expect(c.statuses.first { $0.id == .launchdPlists }?.state != .ok)
    }

    @Test func registeredJobWithoutPlistFoundViaParentBundle() async throws {
        let c = await Fake().collector().collect()
        let i = try #require(item(c, "com.vendor.sm.helper"))
        #expect(i.kind == .serviceManagement && i.plistPath == nil)
        #expect(i.signals.parentBundleID == "com.vendor.foo")
        // Apple and plain loaded labels without registration metadata are not turned into items.
        #expect(item(c, "com.apple.something") == nil)
        #expect(item(c, "com.vendor.loaded.idle") == nil)
    }

    /// Hard rule: a domain we could not read must never turn into "Not loaded".
    @Test(arguments: ["guiNonzero", "guiGarbage", "guiEmpty", "guiTruncated", "sysNonzero", "sysTruncated", "disabledNonzero", "disabledGarbage", "disabledTruncated", "disabledUnknownValue"])
    func unreadableLaunchctlYieldsUnknown(mode: String) async throws {
        var f = Fake()
        switch mode {
        case "guiNonzero": f.guiServices = fail()
        case "guiGarbage": f.guiServices = ok("Could not find domain for gui/501")
        case "guiEmpty": f.guiServices = ok("")
        case "guiTruncated": f.guiServices = ok("gui/501 = {\n\tservices = {\n\t\t     812      - \tcom.vendor.agent\n")
        case "sysTruncated": f.sysServices = ok("system = {\n\tservices = {\n\t\t   523      - \tcom.vendor.daemon\n")
        case "disabledTruncated": f.guiDisabled = ok("\tdisabled services = {\n\t\t\"a.b\" => disabled\n"); f.sysDisabled = f.guiDisabled
        case "disabledUnknownValue": f.guiDisabled = ok("\tdisabled services = {\n\t\t\"a.b\" => maybe\n\t}"); f.sysDisabled = f.guiDisabled
        case "sysNonzero": f.sysServices = fail()
        case "disabledNonzero": f.guiDisabled = fail(); f.sysDisabled = fail()
        case "disabledGarbage": f.guiDisabled = ok("nonsense"); f.sysDisabled = ok("nonsense")
        default: break
        }
        let c = await f.collector().collect()
        let affected: (String) -> Bool = { l in mode.hasPrefix("gui") ? l != "com.vendor.daemon" : mode.hasPrefix("sys") ? l == "com.vendor.daemon" : true }
        for i in c.items where i.plistPath != nil && affected(i.label) {
            if mode.hasPrefix("disabled") {
                guard case .unknown = i.override else { Issue.record("\(mode): \(i.label) override not unknown"); continue }
            } else {
                guard case .unknown = i.loadState else { Issue.record("\(mode): \(i.label) loadState not unknown"); continue }
            }
        }
        #expect(c.statuses.contains { ($0.id == .launchctlDomain || $0.id == .launchctlDisabled) && $0.state != .ok })
    }

    @Test func bundledLoginItemHelperIsContainedInApp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("Foo.app")
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/FooHelper.app")
        try FileManager.default.createDirectory(at: helper.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ([ "CFBundleIdentifier": "com.vendor.loginhelper", "CFBundleName": "FooHelper" ] as NSDictionary)
            .write(to: helper.appendingPathComponent("Contents/Info.plist"))

        var f = Fake(); f.files = [:]; f.unreadable = []
        let me = f
        var coll = f.collector(appPaths: [app.path])
        let baseList = coll.listDirectory
        coll.listDirectory = { dir in dir.hasPrefix(tmp.path) ? defaultDirectoryLister(dir) : baseList(dir) }
        _ = me
        let c = await coll.collect()
        let h = try #require(c.items.first { $0.kind == .loginItemHelper })
        #expect(h.label == "com.vendor.loginhelper")
        #expect(h.signals.itemPath == helper.path)
        guard case .confirmed(let s, _) = h.loadState else { Issue.record("loadState"); return }
        #expect(s.kind == .loaded)
    }

    /// Two files declaring one label: launchd state cannot be assigned to either of them.
    @Test func duplicateLabelsMakeLoadStateAndOverrideUnknown() async {
        var f = Fake()
        f.files["/Library/LaunchAgents/dup-b.plist"] = plist("com.vendor.agent", program: "/other/copy/agent")
        let c = await f.collector().collect()
        let dups = c.items.filter { $0.label == "com.vendor.agent" }
        #expect(dups.count == 2)
        for d in dups {
            guard case .unknown(.notInspectable) = d.loadState, case .unknown(.notInspectable) = d.override else {
                Issue.record("duplicate label should be unknown: \(d.id)"); continue
            }
        }
        // An unrelated label keeps its confirmed state.
        guard case .confirmed? = c.items.first(where: { $0.label == "com.vendor.daemon" })?.loadState else { Issue.record("daemon"); return }
    }

    /// "Nothing found" must not hide a folder that exists but could not be listed.
    @Test func unlistableExistingDirectoryIsReported() async {
        var coll = Fake().collector()
        let base = coll.listDirectory
        coll.listDirectory = { $0 == "/Library/LaunchAgents" ? nil : base($0) }
        coll.directoryExists = { $0 == "/Library/LaunchAgents" }
        let c = await coll.collect()
        guard case .failed? = c.statuses.first(where: { $0.id == .launchdPlists })?.state else { Issue.record("status should be failed"); return }
    }

    @Test func missingDirectoryIsNotAProblem() async {
        var coll = Fake().collector()
        coll.directoryExists = { _ in false }
        let c = await coll.collect()
        // Only the unreadable/garbled plists (bad.plist, locked) make this source non-OK, not missing folders.
        #expect(c.statuses.first(where: { $0.id == .launchdPlists })?.itemCount == 6)
    }

    @Test func failedJobLookupsAreReportedNotSilentlyDropped() async {
        let c = await Fake().collector().collect()
        guard case .failed(let why)? = c.statuses.first(where: { $0.id == .launchctlJobs })?.state else { Issue.record("expected failed lookups status"); return }
        #expect(why.contains("job lookups failed"))
    }

    @Test func lookupCapIsReported() async {
        var coll = Fake().collector()
        coll.maxRegisteredJobLookups = 1
        let c = await coll.collect()
        guard case .failed(let why)? = c.statuses.first(where: { $0.id == .launchctlJobs })?.state else { Issue.record("status"); return }
        #expect(why.contains("skipped"))
    }

    @Test func bundledPlistIsADeclarationNotARegistration() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bp-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("Foo.app/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pl = app.appendingPathComponent("com.vendor.bundled.plist")
        try plist("com.vendor.bundled").write(to: pl)
        var f = Fake(); f.files = [:]; f.unreadable = []
        var coll = f.collector(appPaths: [tmp.appendingPathComponent("Foo.app").path])
        let base = coll.listDirectory
        coll.listDirectory = { $0.hasPrefix(tmp.path) ? defaultDirectoryLister($0) : base($0) }
        coll.readFile = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let c = await coll.collect()
        let i = try #require(c.items.first { $0.label == "com.vendor.bundled" })
        #expect(i.kind == .bundledLaunchPlist)
    }

    @Test func unreadableBundledItemsAreReported() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bu-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("Foo.app/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("junk".utf8).write(to: dir.appendingPathComponent("broken.plist"))
        var f = Fake(); f.files = [:]; f.unreadable = []
        var coll = f.collector(appPaths: [tmp.appendingPathComponent("Foo.app").path])
        let base = coll.listDirectory
        coll.listDirectory = { $0.hasPrefix(tmp.path) ? defaultDirectoryLister($0) : base($0) }
        coll.readFile = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let c = await coll.collect()
        guard case .failed? = c.statuses.first(where: { $0.id == .bundledHelpers })?.state else { Issue.record("bundled status should be failed"); return }
    }

    @Test func registrationCandidateFilter() {
        #expect(StartupCollector.isRegistrationCandidate("com.vendor.x"))
        for l in ["com.apple.x", "application.com.x.1", "0x1234", "[abc]", "com.openssh.ssh-agent"] {
            #expect(!StartupCollector.isRegistrationCandidate(l))
        }
    }
}

// MARK: - Orchestrator integration

@Suite struct Phase2OrchestrationTests {
    @Test func itemsAreAttachedToAppsGroupsAndUnattributed() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("p2-\(UUID().uuidString)")
        let app = d.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.vendor.foo", "CFBundleName": "Foo"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: d) }

        // pluginkit: one child of Foo (by explicit parent), one orphan.
        let pk = """
        +    com.vendor.foo.finder(1.0)
        \t            Path = /elsewhere/Finder.appex
        \t             SDK = com.apple.FinderSync
        \t   Parent Bundle = \(app.path)

             org.orphan.ext(1.0)
        \t            Path = /elsewhere/Orphan.appex
        \t             SDK = com.apple.share-services
        """
        let fake = Fake()
        let orch = ScanOrchestrator(
            inventory: AppInventoryCollector(roots: [d]),
            tcc: TCCCollector(userPath: "/user", systemPath: "/system", reader: { _ in TCCTable(columns: ["service", "client", "client_type", "auth_value", "auth_reason", "last_modified"], rows: []) }),
            fdaProbe: { .granted }, osInfo: { os }, csreqChecker: { _, _ in nil },
            extensionsFactory: { o in
                ExtensionCollector(run: { exe, _ in exe.hasSuffix("pluginkit") ? ok(pk) : ok("0 extension(s)") },
                                   readFile: { _ in nil }, os: o)
            },
            startupFactory: { o, paths in
                var c = fake.collector(appPaths: paths); c.os = o; return c
            },
            teamOfPath: { _ in nil }, btm: nil)
        let snap = await orch.scan()

        let foo = try #require(snap.apps.first { $0.bundleID == "com.vendor.foo" })
        #expect(foo.extensions.map(\.identifier) == ["com.vendor.foo.finder"])
        #expect(foo.extensions.first?.association.rank == 2)
        #expect(snap.unattributedExtensions.map(\.identifier) == ["org.orphan.ext"])
        // Startup: the daemon names com.vendor.foo as associated bundle; the SM helper's parent is com.vendor.foo.
        #expect(Set(foo.startupItems.map(\.label)).isSuperset(of: ["com.vendor.daemon", "com.vendor.sm.helper"]))
        #expect(snap.sources.contains { $0.id == .pluginkit })
        #expect(snap.sources.contains { $0.id == .launchctlDomain })
    }
}

// MARK: - Background Task Management merge

private enum BTMFixture {
    static var sample: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic/btm-sample.txt")
        return try! String(contentsOf: url, encoding: .utf8)
    }
    static func report(importedAt: Date, live: Bool = true) throws -> BTMReport {
        try BTMParser.parse(sample, importedAt: importedAt, isLiveRead: live)
    }
}

@Suite struct BTMMergeTests {
    let importedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func collector(report: BTMReport?, boot: Date? = nil, modified: Date? = Date(timeIntervalSince1970: 1_700_000_000), exists: Bool = true) -> StartupCollector {
        var f = Fake()
        f.files["/Library/LaunchAgents/blocked.plist"] = plist("com.vendor.blocked")
        var c = f.collector()
        c.btm = report
        c.bootTime = boot
        c.now = importedAt
        c.pathExists = { _ in exists }
        c.modifiedAt = { _ in modified }
        return c
    }
    func approval(_ c: StartupCollection, _ label: String) -> Determination<BackgroundApproval>? {
        c.items.first { $0.label == label }?.approval
    }

    @Test func noReportKeepsApprovalUnknown() async {
        let c = await collector(report: nil).collect()
        for i in c.items { guard case .unknown(.needsBTMImport) = i.approval else { Issue.record("\(i.label)"); continue } }
    }

    @Test func matchesByLabelAndByPathAndFlagsNegatives() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt)).collect()
        guard case .confirmed(let a, let ev)? = approval(c, "com.vendor.agent") else { Issue.record("agent"); return }
        #expect(a.enabled && a.allowed && a.notified && !a.isNegative)
        #expect(ev.source == .btm && ev.observedAt == importedAt)                 // observation time is the report's
        // d.plist matched by path (record is in the global UID -2 section).
        guard case .confirmed(let d, _)? = approval(c, "com.vendor.daemon") else { Issue.record("daemon"); return }
        #expect(d.enabled && d.allowed)
        guard case .confirmed(let b, _)? = approval(c, "com.vendor.blocked") else { Issue.record("blocked"); return }
        #expect(b.enabled && !b.allowed && b.isNegative)
    }

    @Test func recordsFromOtherUsersAreIgnored() async throws {
        let text = BTMFixture.sample.replacingOccurrences(of: "Records for UID 501", with: "Records for UID 777")
        let r = try BTMParser.parse(text, importedAt: importedAt, isLiveRead: true)
        let c = await collector(report: r).collect()
        // The agent's only record now belongs to another user: not this user's approval.
        if case .confirmed? = approval(c, "com.vendor.agent") { Issue.record("must not use another user's record") }
    }

    @Test func btmOnlyLoginItemIsListedWithItsApproval() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt)).collect()
        let h = try #require(c.items.first { $0.label == "com.vendor.loginhelper" })
        #expect(h.kind == .loginItemHelper && h.id.hasPrefix("btm:"))
        #expect(h.signals.parentBundleID == "com.vendor.foo")
        #expect(h.signals.itemPath == "/Applications/Foo.app/Contents/Library/LoginItems/FooHelper.app")
        guard case .confirmed(let a, _) = h.approval else { Issue.record("approval"); return }
        #expect(!a.enabled && a.allowed && a.isNegative)                         // disabled in Login Items
        // A record with a disposition we do not understand is listed but Unknown.
        let f = try #require(c.items.first { $0.label == "com.vendor.future" })
        guard case .unknown(.formatUnrecognized) = f.approval else { Issue.record("future should be unknown"); return }
    }

    /// BTM keeps records for removed items until overnight maintenance: do not list what is gone from disk.
    @Test func lingeringRecordsForMissingFilesAreNotListed() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt), exists: false).collect()
        #expect(!c.items.contains { $0.label == "com.vendor.loginhelper" })
        #expect(!c.items.contains { $0.id.hasPrefix("btm:") })
    }

    // MARK: absence ("no record") is only claimed from a trustworthy read

    @Test func liveCompleteFreshReadCanSayNoRecord() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt, live: true)).collect()
        guard case .notRecorded(let ev)? = approval(c, "com.vendor.notloaded") else { Issue.record("expected notRecorded"); return }
        #expect(ev.source == .btm && !ev.staleSource)
    }

    @Test func importedFileCannotProveAbsence() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt, live: false)).collect()
        guard case .unknown = approval(c, "com.vendor.notloaded") else { Issue.record("imported must be unknown"); return }
        // ...but its positive matches still count.
        guard case .confirmed? = approval(c, "com.vendor.agent") else { Issue.record("positive match should hold"); return }
    }

    @Test func staleReportIsFlaggedAndCannotProveAbsence() async throws {
        let boot = importedAt.addingTimeInterval(600)           // booted after the report was made
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt), boot: boot).collect()
        guard case .unknown = approval(c, "com.vendor.notloaded") else { Issue.record("stale must be unknown"); return }
        guard case .confirmed(_, let ev)? = approval(c, "com.vendor.agent") else { Issue.record("agent"); return }
        #expect(ev.staleSource)
    }

    @Test func oldImportedFileIsStaleAfterADay() async throws {
        var c = await collector(report: try BTMFixture.report(importedAt: importedAt.addingTimeInterval(-3 * 86400), live: false)).collect()
        guard case .confirmed(_, let ev)? = approval(c, "com.vendor.agent") else { Issue.record("agent"); return }
        #expect(ev.staleSource)
        c = StartupCollection(items: [], statuses: [])
    }

    @Test func incompleteReportCannotProveAbsence() async throws {
        let text = BTMFixture.sample.replacingOccurrences(of: "           UUID: 55555555-5555-4555-8555-555555555555\n", with: "")
        let r = try BTMParser.parse(text, importedAt: importedAt, isLiveRead: true)
        #expect(!r.isComplete)
        let c = await collector(report: r).collect()
        guard case .unknown(.formatUnrecognized) = approval(c, "com.vendor.notloaded") else { Issue.record("incomplete must be unknown"); return }
    }

    @Test func itemNewerThanTheReportCannotBeCalledUnrecorded() async throws {
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt), modified: importedAt.addingTimeInterval(60)).collect()
        guard case .unknown = approval(c, "com.vendor.notloaded") else { Issue.record("new item must be unknown"); return }
    }

    // MARK: review fixes

    /// A lingering record for an old plist must not describe its replacement at another path.
    @Test func conflictingPathRecordIsRejectedEvenWithTheSameLabel() async throws {
        let text = BTMFixture.sample.replacingOccurrences(of: "file:///home/me/Library/LaunchAgents/a.plist", with: "file:///home/me/Library/LaunchAgents/OLD-LOCATION.plist")
            .replacingOccurrences(of: "[enabled, allowed, notified] (0xb)\n           Identifier: 8.com.vendor.agent", with: "[disabled, allowed, notified] (0xa)\n           Identifier: 8.com.vendor.agent")
        let r = try BTMParser.parse(text, importedAt: importedAt, isLiveRead: true)
        let c = await collector(report: r).collect()
        if case .confirmed(let a, _)? = approval(c, "com.vendor.agent") { Issue.record("old record applied: enabled=\(a.enabled)") }
        // ...and with no applicable record the absence rules decide (fresh live read, old file): no record.
        guard case .notRecorded? = approval(c, "com.vendor.agent") else { Issue.record("expected notRecorded, got \(String(describing: approval(c, "com.vendor.agent")))"); return }
    }

    @Test func relativeRecordPathsAreResolvedBeforeComparison() async throws {
        // The login helper's record URL is relative; it still equals the BTM-only item's absolute path (no conflict, listed once).
        let c = await collector(report: try BTMFixture.report(importedAt: importedAt)).collect()
        #expect(c.items.filter { $0.label == "com.vendor.loginhelper" }.count == 1)
    }

    /// A same-label daemon record must not lend its approval to a GUI agent.
    @Test func guiItemsIgnoreDaemonRecordsAndViceVersa() async throws {
        let text = BTMFixture.sample.replacingOccurrences(of: "8.com.vendor.agent", with: "16.com.vendor.agent")
            .replacingOccurrences(of: "legacy agent (0x10008)\nFlags: [ legacy ] (0x1)\n          Disposition: [enabled, allowed, notified] (0xb)\n           Identifier: 16.com.vendor.agent",
                                  with: "legacy daemon (0x10010)\nFlags: [ legacy ] (0x1)\n          Disposition: [enabled, allowed, notified] (0xb)\n           Identifier: 16.com.vendor.agent")
        // Build a report where the only record labelled com.vendor.agent is a legacy daemon in the global section.
        let daemonOnly = text.replacingOccurrences(of: "Type: legacy agent (0x10008)\n                Flags: [ legacy ] (0x1)\n          Disposition: [enabled, allowed, notified] (0xb)\n           Identifier: 16.com.vendor.agent",
                                                   with: "Type: legacy daemon (0x10010)\n                Flags: [ legacy ] (0x1)\n          Disposition: [disabled, allowed, notified] (0xa)\n           Identifier: 16.com.vendor.agent")
        let r = try BTMParser.parse(daemonOnly, importedAt: importedAt, isLiveRead: true)
        #expect(r.records.contains { $0.label == "com.vendor.agent" && $0.kind == .legacyDaemon })
        let c = await collector(report: r).collect()
        if case .confirmed? = approval(c, "com.vendor.agent") { Issue.record("a daemon record described a GUI agent") }
    }

    /// Login-item helpers have no plist; their own files must prove they are not newer than the report.
    @Test func newerHelperIsNotCalledUnrecorded() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("age-\(UUID().uuidString)")
        let helper = tmp.appendingPathComponent("Foo.app/Contents/Library/LoginItems/NewHelper.app/Contents")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try (["CFBundleIdentifier": "com.vendor.newhelper"] as NSDictionary).write(to: helper.appendingPathComponent("Info.plist"))

        var f = Fake(); f.files = [:]; f.unreadable = []
        func run(modified: Date?) async -> StartupCollection {
            var c = f.collector(appPaths: [tmp.appendingPathComponent("Foo.app").path])
            let base = c.listDirectory
            c.listDirectory = { $0.hasPrefix(tmp.path) ? defaultDirectoryLister($0) : base($0) }
            c.btm = try! BTMFixture.report(importedAt: importedAt)
            c.now = importedAt
            c.modifiedAt = { _ in modified }
            return await c.collect()
        }
        let newer = await run(modified: importedAt.addingTimeInterval(60))
        guard case .unknown? = newer.items.first(where: { $0.label == "com.vendor.newhelper" })?.approval else { Issue.record("newer helper must be unknown"); return }
        let unknownAge = await run(modified: nil)
        guard case .unknown? = unknownAge.items.first(where: { $0.label == "com.vendor.newhelper" })?.approval else { Issue.record("unprovable age must be unknown"); return }
        let older = await run(modified: importedAt.addingTimeInterval(-3600))
        guard case .notRecorded? = older.items.first(where: { $0.label == "com.vendor.newhelper" })?.approval else { Issue.record("provably old helper may be notRecorded"); return }
    }
}
