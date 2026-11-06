import Testing
import Foundation
import InspectorModel
@testable import InspectorAssociation

@Suite struct AssociationTests {
    let foo = AppIndexEntry(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.vendor.foo", teamID: "TEAMFOO111")
    let nested = AppIndexEntry(path: "/Applications/Foo.app/Contents/Library/Helper.app", name: "Helper", bundleID: "com.vendor.foo.helper", teamID: "TEAMFOO111")
    let bar = AppIndexEntry(path: "/Applications/Bar.app", name: "Bar", bundleID: "com.other.bar", teamID: "TEAMBAR222")

    func engine(team: @escaping @Sendable (String) -> String? = { _ in nil }) -> AssociationEngine {
        AssociationEngine(apps: [foo, nested, bar], teamOfPath: team)
    }

    @Test func rank1Containment() {
        let a = engine().associate(.init(itemPath: "/Applications/Foo.app/Contents/PlugIns/Share.appex"))
        #expect(a.target == .app(path: foo.path) && a.rank == 1 && a.confidence == .definitive)
    }

    @Test func nestedHelperWinsOverOuterApp() {
        let a = engine().associate(.init(itemPath: nested.path + "/Contents/MacOS/Helper"))
        #expect(a.target == .app(path: nested.path))
    }

    @Test func appItselfIsNotContainedInItself() {
        let a = engine().associate(.init(itemPath: foo.path, identifier: "x"))
        #expect(a.rank != 1)
    }

    @Test func rank2ParentPathBundleIDAndAssociated() {
        let e = engine()
        let p = e.associate(.init(itemPath: "/Library/Foo/x.appex", parentBundlePath: "/Applications/Bar.app"))
        #expect(p.target == .app(path: bar.path) && p.rank == 2 && p.confidence == .strong)
        let b = e.associate(.init(parentBundleID: "com.vendor.foo"))
        #expect(b.target == .app(path: foo.path) && b.rank == 2)
        let c = e.associate(.init(associatedBundleIDs: ["com.nope", "com.other.bar"]))
        #expect(c.target == .app(path: bar.path) && c.rank == 2)
    }

    @Test func rank3ExecutableInsideBundle() {
        let a = engine().associate(.init(itemPath: "/Library/LaunchDaemons/x.plist", executablePath: "/Applications/Bar.app/Contents/MacOS/bard"))
        #expect(a.target == .app(path: bar.path) && a.rank == 3 && a.confidence == .strong)
    }

    @Test func rank4TeamPlusIdentifierPrefix() {
        let a = engine().associate(.init(executablePath: "/usr/local/bin/foo-agent", identifier: "com.vendor.foo.agent", teamID: "TEAMFOO111"))
        #expect(a.target == .app(path: foo.path))      // only foo's bundle ID is a prefix of this identifier
        #expect(a.rank == 4 && a.confidence == .probable)
        // Longest matching bundle id wins: com.vendor.foo.helper.x → nested helper.
        let b = engine().associate(.init(identifier: "com.vendor.foo.helper.x", teamID: "TEAMFOO111"))
        #expect(b.target == .app(path: nested.path))
    }

    @Test func rank4TeamLookedUpViaSigningWhenSignalsLackIt() {
        let a = engine(team: { $0 == "/usr/local/bin/foo-agent" ? "TEAMFOO111" : nil })
            .associate(.init(executablePath: "/usr/local/bin/foo-agent", identifier: "com.vendor.foo.agent"))
        #expect(a.rank == 4)
    }

    @Test func rank4RequiresMatchingTeam() {
        // Same prefix, different team: must NOT attribute to Foo.
        let a = engine().associate(.init(identifier: "com.vendor.foo.agent", teamID: "SOMEONEELSE"))
        #expect(a.rank == 5)
        #expect(a.target == .developerGroup(teamID: "SOMEONEELSE"))
    }

    @Test func rank5TeamOnlyIsGroupNotApp() {
        let a = engine().associate(.init(identifier: "org.unrelated.thing", teamID: "TEAMBAR222"))
        #expect(a.target == .developerGroup(teamID: "TEAMBAR222") && a.confidence == .developerGroup)
    }

    @Test func rank6HeuristicIsOnlyASuggestion() {
        let a = engine().associate(.init(identifier: "com.other.bar.mystery.thing"))
        #expect(a.target == .app(path: bar.path) && a.rank == 6 && a.confidence == .suggestion)
    }

    @Test func duplicateBundleIDIsNotPickedByParentID() {
        let a1 = AppIndexEntry(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.vendor.foo", teamID: "T")
        let a2 = AppIndexEntry(path: "/Users/me/Downloads/Foo.app", name: "Foo", bundleID: "com.vendor.foo", teamID: "T")
        let e = AssociationEngine(apps: [a1, a2])
        // Ambiguous ID alone: not attributed to either copy by rank 2.
        let amb = e.associate(.init(parentBundleID: "com.vendor.foo"))
        #expect(amb.rank != 2)
        // The executable path disambiguates: copy B wins by rank 3, not copy A by "first in list".
        let b = e.associate(.init(executablePath: a2.path + "/Contents/MacOS/x", parentBundleID: "com.vendor.foo"))
        #expect(b.target == .app(path: a2.path) && b.rank == 3)
        let c = e.associate(.init(associatedBundleIDs: ["com.vendor.foo"]))
        #expect(c.rank != 2)
    }

    @Test func tiedRank4CandidatesAreNotGuessed() {
        let a1 = AppIndexEntry(path: "/Applications/Foo.app", name: "Foo", bundleID: "com.vendor.foo", teamID: "T")
        let a2 = AppIndexEntry(path: "/Users/me/Foo.app", name: "Foo", bundleID: "com.vendor.foo", teamID: "T")
        let r = AssociationEngine(apps: [a1, a2]).associate(.init(identifier: "com.vendor.foo.agent", teamID: "T"))
        #expect(r.rank == 5 && r.target == .developerGroup(teamID: "T"))
    }

    @Test func rank6AmbiguousMatchIsNotGuessed() {
        let a1 = AppIndexEntry(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.suite.iWork.Pages", teamID: nil)
        let a2 = AppIndexEntry(path: "/Applications/Numbers.app", name: "Numbers", bundleID: "com.suite.iWork.Numbers", teamID: nil)
        let e = AssociationEngine(apps: [a1, a2])
        #expect(e.associate(.init(identifier: "com.suite.iWork.Shared.thing")) == .none)
    }

    @Test func nothingMatches() {
        let a = engine().associate(.init(executablePath: "/opt/x", identifier: "org.random.x"))
        #expect(a == .none)
        #expect(a.target == Association.Target.unattributed && a.confidence == nil)
    }

    @Test func symlinkedPathsStillContained() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("assoc-\(UUID().uuidString)")
        let real = tmp.appendingPathComponent("Real.app"); let link = tmp.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let e = AssociationEngine(apps: [AppIndexEntry(path: real.path, name: "Real", bundleID: "a.b.c", teamID: nil)])
        let a = e.associate(.init(itemPath: link.path + "/Contents/x"))
        #expect(a.rank == 1)
    }

    @Test func reasonIsAlwaysPresent() {
        let e = engine()
        for s in [AssociationSignals(itemPath: "/Applications/Foo.app/x"), .init(parentBundleID: "com.other.bar"),
                  .init(identifier: "a.b.c", teamID: "T"), .init()] {
            #expect(!e.associate(s).reason.isEmpty)
        }
    }
}
