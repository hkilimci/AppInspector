import Testing
import Foundation
@testable import InspectorParsers

private let pluginkitSample = """
     com.apple.tips.TipsQuicklook(1.0)
\t            Path = /System/Library/CoreServices/TipsSpotlightHandler.app/Contents/PlugIns/TipsQuicklook.appex
\t            UUID = 475F11DE-C307-596E-A82F-8A00D3D06C79
\t             SDK = com.apple.quicklook.preview
\t   Parent Bundle = /System/Library/CoreServices/TipsSpotlightHandler.app
\t    Display Name = TipsQuicklook
\t     Parent Name = Tips
\t        Platform = macOS

+    com.apple.MarkupUI.Markup(1.0)
\t            Path = /System/Library/Frameworks/MarkupUI.framework/PlugIns/Markup.appex
\t             SDK = com.apple.ui-services
\t    Display Name = Markup
\t        Platform = macOS

-    com.example.app.share(2.1)
\t            Path = /Applications/Example.app/Contents/PlugIns/Share.appex
\t             SDK = com.apple.share-services

!    com.example.debug(1)
\t             SDK = com.apple.thing

=    com.example.old((null))
\t             SDK = com.apple.thing
"""

@Suite struct PluginkitParserTests {
    @Test func parsesMarksAndFields() throws {
        let r = try PluginkitParser.parse(pluginkitSample)
        #expect(r.entries.count == 5)
        #expect(r.skipped == 0)
        let tips = r.entries[0]
        #expect(tips.mark == nil && tips.identifier == "com.apple.tips.TipsQuicklook" && tips.version == "1.0")
        #expect(tips.sdk == "com.apple.quicklook.preview")
        #expect(tips.parentBundle == "/System/Library/CoreServices/TipsSpotlightHandler.app")
        #expect(tips.parentName == "Tips")
        #expect(r.entries[1].mark == "+")
        #expect(r.entries[2].mark == "-")
        #expect(r.entries[3].mark == "!")
        #expect(r.entries[4].mark == "=" && r.entries[4].version == "(null)")
    }

    @Test func fingerprintTracksFieldNames() throws {
        let a = try PluginkitParser.parse(pluginkitSample).fieldFingerprint
        let b = try PluginkitParser.parse(pluginkitSample.replacingOccurrences(of: "Platform", with: "Plat")).fieldFingerprint
        #expect(a != b)
    }

    @Test func emptyInputIsEmptyNotError() throws {
        #expect(try PluginkitParser.parse("").entries.isEmpty)
        #expect(try PluginkitParser.parse("\n\n").entries.isEmpty)
    }

    @Test func garbageThrowsUnrecognized() {
        #expect(throws: ParseError.self) { try PluginkitParser.parse("this is not pluginkit output\nat all") }
    }

    @Test func orphanFieldLinesAreCountedNotGuessed() throws {
        let r = try PluginkitParser.parse("\tPath = /x\n\ncom.a.b(1)\n\t SDK = s\n")
        #expect(r.skipped == 1)
        #expect(r.entries.count == 1)
    }
}

@Suite struct SystemExtensionParserTests {
    static let ctl = """
    3 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    \t*\tPXPZ95SK77\tcom.paloaltonetworks.GlobalProtect.client.extension (6.3.1-376/1)\tGlobalProtectExtension\t[activated waiting for user]
    *\t*\tAH4XFXJ7DK\tcom.fortinet.forticlient.macos.vpn.nwextension (7.4.2/1717)\tvpnprovider\t[activated enabled]
    --- com.apple.system_extension.endpoint_security
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    \t\t-\tcom.old.es (1.0/1)\tOld ES\t[terminated waiting to uninstall on reboot]
    """.split(separator: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: " ")) }.joined(separator: "\n")

    @Test func parsesCtl() throws {
        let rows = try SystemExtensionCtlParser.parse(Self.ctl)
        #expect(rows.count == 3)
        #expect(rows[0].category == "com.apple.system_extension.network_extension")
        #expect(rows[0].bundleID == "com.paloaltonetworks.GlobalProtect.client.extension")
        #expect(rows[0].version == "6.3.1-376/1")
        #expect(rows[0].enabledMark == false && rows[0].activeMark == true)
        #expect(rows[0].state == "activated waiting for user")
        #expect(rows[1].enabledMark && rows[1].state == "activated enabled")
        #expect(rows[2].category == "com.apple.system_extension.endpoint_security")
        #expect(rows[2].state == "terminated waiting to uninstall on reboot")
    }

    @Test func zeroExtensionsIsValid() throws {
        #expect(try SystemExtensionCtlParser.parse("0 extension(s)\n").isEmpty)
    }

    @Test func emptyOutputThrows() {
        #expect(throws: ParseError.self) { try SystemExtensionCtlParser.parse("") }
    }

    /// A section header with unparseable rows must not parse as "no extensions".
    @Test func malformedRowsUnderHeaderThrow() {
        let text = "1 extension(s)\n--- com.apple.system_extension.network_extension (x)\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tTEAM\tbroken row without version\tName\t[activated enabled]\n"
        #expect(throws: ParseError.self) { try SystemExtensionCtlParser.parse(text) }
        #expect(throws: ParseError.self) { try SystemExtensionCtlParser.parse("1 extension(s)\n--- cat\nonly\ttwo cols\n") }
    }

    @Test func garbageThrows() {
        #expect(throws: ParseError.self) { try SystemExtensionCtlParser.parse("Something else entirely\nhappened") }
    }

    @Test func parsesDB() throws {
        let plist: [String: Any] = ["extensions": [[
            "identifier": "com.x.ext", "state": "activated_enabled", "categories": ["com.apple.system_extension.network_extension"],
            "container": ["bundlePath": "/Applications/X.app"], "originPath": "/Applications/X.app/Contents/Library/SystemExtensions/x.systemextension",
            "references": [["appIdentifier": "com.x.app", "teamID": "TEAM123456"]],
            "bundleVersion": ["CFBundleShortVersionString": "2.0"],
        ], ["noIdentifier": true]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let recs = try SystemExtensionParser.parseDB(data)
        #expect(recs.count == 1)
        #expect(recs[0].teamID == "TEAM123456" && recs[0].containerBundlePath == "/Applications/X.app")
        #expect(recs[0].appIdentifiers == ["com.x.app"] && recs[0].version == "2.0" && recs[0].dbState == "activated_enabled")
        #expect(throws: ParseError.self) { try SystemExtensionParser.parseDB(Data("junk".utf8)) }
    }
}

@Suite struct LaunchdParserTests {
    @Test func parsesServicesBlock() throws {
        let text = """
        gui/502 = {
        \ttype = login
        \tservices = {
        \t\t   31318   (pe) \tcom.apple.syncdefaultsd
        \t\t       0      - \tcom.vendor.helper
        \t\t     775      - \tcom.vendor.agent
        \t}

        \tdisabled services = {
        \t}
        }
        """
        let s = try LaunchctlParser.parseServices(text)
        #expect(s.map(\.label) == ["com.apple.syncdefaultsd", "com.vendor.helper", "com.vendor.agent"])
        #expect(s.map(\.pid) == [31318, 0, 775])
        #expect(s[0].flags == "(pe)")
    }

    @Test func servicesFormatChangeThrows() throws {
        #expect(throws: ParseError.self) { try LaunchctlParser.parseServices("Could not find domain for") }
    }

    /// A partial list must never parse as a complete one: absence from it is later read as "not loaded".
    @Test(arguments: [
        "",                                                                              // empty output
        "gui/1 = {\n\tservices = {\n\t\t  1  -  \tcom.a.b\n",                          // cut off, block never closed
        "gui/1 = {\n\tservices = {\n\t\t  1  -  \tcom.a.b\n\t\tgarbage row\n\t}\n}",   // unparseable row
        "gui/1 = {\n\tservices = {\n\t\tx  -  \tcom.a.b\n\t}\n}",                       // non-numeric pid
    ])
    func partialOrEmptyServicesThrow(text: String) {
        #expect(throws: ParseError.self) { try LaunchctlParser.parseServices(text) }
    }

    @Test func emptyButClosedServicesBlockIsValid() throws {
        #expect(try LaunchctlParser.parseServices("gui/1 = {\n\tservices = {\n\t}\n}").isEmpty)
    }

    @Test func parsesDisabled() throws {
        let text = """
        \tdisabled services = {
        \t\t"com.a.b" => disabled
        \t\t"com.c.d" => enabled
        \t}
        """
        let d = try LaunchctlParser.parseDisabled(text)
        #expect(d == ["com.a.b": true, "com.c.d": false])
        #expect(try LaunchctlParser.parseDisabled("\tdisabled services = {\n\t}").isEmpty)
    }

    @Test(arguments: [
        "", "nonsense",
        "\tdisabled services = {\n\t\t\"com.e.f\" => weird\n\t}",             // unknown value: dropping it would read as "no override"
        "\tdisabled services = {\n\t\t\"com.a.b\" => disabled\n",                // cut off
        "\tdisabled services = {\n\t\tnot a row\n\t}",
    ])
    func partialDisabledThrows(text: String) {
        #expect(throws: ParseError.self) { try LaunchctlParser.parseDisabled(text) }
    }

    static let smJob = """
    gui/502/com.postgresapp.Postgres2LoginHelper = {
    \tactive count = 0
    \tpath = (submitted by smd.336)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = not running

    \tprogram identifier = com.postgresapp.Postgres2LoginHelper (mode: 1)
    \tparent bundle identifier = com.postgresapp.Postgres2
    \tparent bundle version = 381
    \targuments = {
    \t\t/Applications/Postgres.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper
    \t\t--flag
    \t}
    \tenvironment = {
    \t\tXPC_SERVICE_NAME => com.postgresapp.Postgres2LoginHelper
    \t}
    \tdomain = gui/502 [100023]
    \tpid = 4242
    }
    """

    @Test func parsesJob() throws {
        let j = try LaunchdJobParser.parse(Self.smJob)
        #expect(j.target == "gui/502/com.postgresapp.Postgres2LoginHelper")
        #expect(j.isSubmitted && j.managedBy == "com.apple.xpc.ServiceManagement")
        #expect(j.parentBundleID == "com.postgresapp.Postgres2")
        #expect(j.state == "not running" && j.pid == 4242)
        #expect(j.arguments.first == "/Applications/Postgres.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")
        #expect(j.arguments.count == 2)
        #expect(j.fields["XPC_SERVICE_NAME"] == nil)      // nested env block not leaked to top level
    }

    @Test func jobWithoutHeaderThrows() {
        #expect(throws: ParseError.self) { try LaunchdJobParser.parse("Could not find service \"x\" in domain") }
    }

    @Test func parsesPlist() throws {
        let d: [String: Any] = ["Label": "com.x.agent", "ProgramArguments": ["/usr/local/bin/x", "-d"], "RunAtLoad": true,
                                "KeepAlive": ["SuccessfulExit": false], "AssociatedBundleIdentifiers": "com.x.app"]
        let data = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
        let j = try LaunchdPlistParser.parse(data)
        #expect(j.label == "com.x.agent" && j.program == "/usr/local/bin/x")
        #expect(j.runAtLoad == true && j.keepAlive == true)
        #expect(j.associatedBundleIDs == ["com.x.app"])
        #expect(throws: ParseError.self) { try LaunchdPlistParser.parse(Data("junk".utf8)) }
        let noLabel = try PropertyListSerialization.data(fromPropertyList: ["Program": "/x"], format: .xml, options: 0)
        #expect(throws: ParseError.self) { try LaunchdPlistParser.parse(noLabel) }
    }
}
