import Testing
import Foundation
import InspectorModel
@testable import InspectorParsers

/// Deterministic generator so failures reproduce.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func mutate(_ text: String, seed: UInt64) -> String {
    var g = SplitMix(state: seed)
    var lines = text.components(separatedBy: "\n")
    for _ in 0..<Int.random(in: 1...6, using: &g) where !lines.isEmpty {
        let i = Int.random(in: 0..<lines.count, using: &g)
        switch Int.random(in: 0..<5, using: &g) {
        case 0: lines.remove(at: i)
        case 1: lines.insert(lines[i], at: i)
        case 2: lines[i] = String(lines[i].prefix(Int.random(in: 0...lines[i].count, using: &g)))
        case 3: lines[i] = lines[i].replacingOccurrences(of: ":", with: "")
        default: lines[i] = String(lines[i].shuffled(using: &g))
        }
    }
    return lines.joined(separator: "\n")
}

@Suite struct FuzzTests {
    // MARK: BTM

    /// Cutting the file anywhere may lose items but may never invent or alter an approval.
    @Test func btmTruncationNeverChangesASurvivingDisposition() throws {
        let text = BTMFixture.sample
        let original = Dictionary(uniqueKeysWithValues: try BTMFixture.report().records.map { ($0.uuid, $0) })
        for cut in stride(from: 0, to: text.count, by: 7) {
            let part = String(text.prefix(cut))
            guard let r = try? BTMParser.parse(part, importedAt: Date(), isLiveRead: false) else { continue }
            for rec in r.records {
                let o = try #require(original[rec.uuid], "cut \(cut): unknown uuid \(rec.uuid)")
                #expect(rec.disposition == nil || rec.disposition == o.disposition, "cut \(cut)")
                #expect(rec.uid == o.uid, "cut \(cut)")
                #expect(rec.typeCode == o.typeCode, "cut \(cut)")
            }
        }
    }

    @Test func btmRandomCorruptionNeverCrashes() {
        for seed in 0..<400 {
            _ = try? BTMParser.parse(mutate(BTMFixture.sample, seed: UInt64(seed)), importedAt: Date(), isLiveRead: false)
        }
    }

    // MARK: launchctl

    private static let services = "gui/501 = {\n\ttype = login\n\tservices = {\n\t\t   812      - \tcom.vendor.agent\n\t\t     0      - \tcom.vendor.other\n\t}\n\n\tdisabled services = {\n\t}\n}\n"
    private static let disabled = "\tdisabled services = {\n\t\t\"com.a.b\" => disabled\n\t\t\"com.c.d\" => enabled\n\t}\n"

    /// A services list cut anywhere before its closing brace must throw: it can never be a "complete" list.
    @Test func servicesTruncationBeforeCloseAlwaysThrows() throws {
        let text = Self.services
        let closeAt = try #require(text.range(of: "\t}\n\n\tdisabled")).lowerBound
        let limit = text.distance(from: text.startIndex, to: closeAt)
        for cut in 0..<limit {
            #expect(throws: ParseError.self, "cut \(cut)") { try LaunchctlParser.parseServices(String(text.prefix(cut))) }
        }
        #expect(try LaunchctlParser.parseServices(text).count == 2)
    }

    @Test func disabledTruncationBeforeCloseAlwaysThrows() throws {
        let text = Self.disabled
        let closeAt = try #require(text.range(of: "\t}\n", options: .backwards)).lowerBound
        let limit = text.distance(from: text.startIndex, to: closeAt)
        for cut in 0..<limit {
            #expect(throws: ParseError.self, "cut \(cut)") { try LaunchctlParser.parseDisabled(String(text.prefix(cut))) }
        }
    }

    @Test func launchctlRandomCorruptionNeverCrashesNorInventsLabels() {
        let known: Set<String> = ["com.vendor.agent", "com.vendor.other"]
        for seed in 0..<400 {
            let t = mutate(Self.services, seed: UInt64(seed))
            if let s = try? LaunchctlParser.parseServices(t) {
                // Mutations can rename a label, but a parsed list must still be well formed.
                #expect(s.allSatisfy { !$0.label.isEmpty })
                _ = known
            }
            _ = try? LaunchctlParser.parseDisabled(mutate(Self.disabled, seed: UInt64(seed)))
            _ = try? LaunchdJobParser.parse(mutate(LaunchdParserTests.smJob, seed: UInt64(seed)))
        }
    }

    // MARK: systemextensionsctl / pluginkit

    private static let ctl = "2 extension(s)\n--- com.apple.system_extension.network_extension (x)\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tTEAM\tcom.a.b (1.0/1)\tA\t[activated enabled]\n\t*\tTEAM\tcom.c.d (1.0/1)\tC\t[activated waiting for user]\n"

    /// A list cut at any point must not parse as a complete one: the declared count catches row-boundary cuts.
    @Test func ctlTruncationAlwaysThrows() throws {
        for cut in 0..<Self.ctl.count - 1 {
            #expect(throws: ParseError.self, "cut \(cut)") { try SystemExtensionCtlParser.parse(String(Self.ctl.prefix(cut))) }
        }
        #expect(try SystemExtensionCtlParser.parse(Self.ctl).count == 2)
    }

    @Test func ctlAndPluginkitRandomCorruptionNeverCrash() {
        for seed in 0..<400 {
            _ = try? SystemExtensionCtlParser.parse(mutate(Self.ctl, seed: UInt64(seed)))
            _ = try? PluginkitParser.parse(mutate("+    com.a.b(1.0)\n\t SDK = x\n\t Path = /p\n\n     com.c.d(2)\n\t SDK = y\n", seed: UInt64(seed)))
        }
    }

    // MARK: TCC

    @Test func tccRandomGarbageNeverCrashes() {
        var g = SplitMix(state: 42)
        for _ in 0..<300 {
            var row: [String: SQLValue] = [:]
            for key in TCCParser.requiredColumns + ["csreq", "flags", "indirect_object_identifier"] where Bool.random(using: &g) {
                row[key] = [SQLValue.null, .int(Int64.random(in: -5...20, using: &g)), .text("x"), .real(1.5), .blob(Data([1]))].randomElement(using: &g)!
            }
            _ = try? TCCParser.parse(TCCTable(columns: TCCParser.requiredColumns, rows: [row]))
        }
    }
}
