import Testing
import Foundation
@testable import AppInspector

/// Only a release build may start Sparkle: anything else could replace a dev copy with the public release.
@Suite @MainActor struct UpdateManagerTests {
    private func bundle(_ info: [String: Any]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTest-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Contents/Info.plist"))
        return try #require(Bundle(url: dir))
    }

    private let release: [String: Any] = [
        "CFBundleIdentifier": "dev.appinspector.AppInspector",
        "AppInspectorDistribution": "release",
        "SUFeedURL": "https://raw.githubusercontent.com/hkilimci/AppInspector/main/appcast.xml",
        "SUPublicEDKey": "U8eaZtyGxl6XOv+xOE4oIWywioo60RiUZWm8QUXrTaE=",
    ]

    @Test func releaseBuildStarts() throws {
        #expect(UpdateManager.shouldStart(bundle: try bundle(release)))
    }

    @Test(arguments: ["AppInspectorDistribution", "SUFeedURL", "SUPublicEDKey"])
    func missingKeyKeepsUpdaterOff(key: String) throws {
        var info = release; info.removeValue(forKey: key)
        #expect(!UpdateManager.shouldStart(bundle: try bundle(info)))
    }

    @Test func otherBundleIDOrDevMarkerKeepsUpdaterOff() throws {
        var other = release; other["CFBundleIdentifier"] = "dev.appinspector.AppInspector.test"
        #expect(!UpdateManager.shouldStart(bundle: try bundle(other)))
        var dev = release; dev["AppInspectorDistribution"] = "dev"
        #expect(!UpdateManager.shouldStart(bundle: try bundle(dev)))
    }
}
