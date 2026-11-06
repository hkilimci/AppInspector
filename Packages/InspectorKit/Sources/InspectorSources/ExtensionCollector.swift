import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform

public typealias CommandRunner = @Sendable (_ executable: String, _ args: [String]) async throws -> ProcessResult

public let defaultCommandRunner: CommandRunner = { exe, args in
    try await ProcessRunner.run(exe, args, timeout: .seconds(20))
}

public typealias FileReader = @Sendable (_ path: String) -> Data?
public let defaultFileReader: FileReader = { try? Data(contentsOf: URL(fileURLWithPath: $0)) }

/// Shared helper: builds Evidence stamped with OS build and the "unvalidated" flag.
struct EvidenceMaker: Sendable {
    let os: OSInfo
    let now: Date
    let matrix: CapabilityMatrix
    func make(_ source: SourceID, _ locator: String, excerpt: String? = nil, at: Date? = nil, stale: Bool = false) -> Evidence {
        Evidence(source: source, locator: locator, observedAt: at ?? now, osBuild: os.build, excerpt: excerpt,
                 unvalidatedOS: matrix.capability(source)?.isUnvalidated(on: os.version) ?? true, staleSource: stale)
    }
}

struct CommandOutcome: Sendable {
    let text: String?
    let failure: String?
}

func runText(_ run: CommandRunner, _ exe: String, _ args: [String]) async -> CommandOutcome {
    do {
        let r = try await run(exe, args)
        if r.timedOut { return CommandOutcome(text: nil, failure: "timed out") }
        if r.truncated { return CommandOutcome(text: nil, failure: "output truncated at cap") }
        if r.status != 0 {
            let err = String(decoding: r.stderr.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandOutcome(text: nil, failure: "exit \(r.status)" + (err.isEmpty ? "" : ": \(err)"))
        }
        return CommandOutcome(text: r.stdoutString, failure: nil)
    } catch {
        return CommandOutcome(text: nil, failure: "\(error)")
    }
}

public struct ExtensionCollection: Sendable {
    public var items: [ExtensionItem]
    public var statuses: [SourceStatus]
}

public struct ExtensionCollector: Sendable {
    public var run: CommandRunner
    public var readFile: FileReader
    public var matrix: CapabilityMatrix
    public var os: OSInfo
    public var now: Date

    public init(run: @escaping CommandRunner = defaultCommandRunner, readFile: @escaping FileReader = defaultFileReader,
                matrix: CapabilityMatrix = .phase1, os: OSInfo = SystemInfo.current(), now: Date = Date()) {
        self.run = run; self.readFile = readFile; self.matrix = matrix; self.os = os; self.now = now
    }

    public func collect() async -> ExtensionCollection {
        async let pk = collectPluginkit()
        async let se = collectSystemExtensions()
        let (a, b) = await (pk, se)
        return ExtensionCollection(items: a.items + b.items, statuses: a.statuses + b.statuses)
    }

    // MARK: pluginkit

    func collectPluginkit() async -> ExtensionCollection {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let ev = EvidenceMaker(os: os, now: now, matrix: matrix)
        let out = await runText(run, "/usr/bin/pluginkit", ["-mAvvv"])
        guard let text = out.text else {
            return .init(items: [], statuses: [SourceStatus(id: .pluginkit, state: .failed(out.failure ?? "?"), itemCount: 0, durationMs: ms())])
        }
        let parsed: PluginkitParseResult
        do { parsed = try PluginkitParser.parse(text) } catch {
            return .init(items: [], statuses: [SourceStatus(id: .pluginkit, state: .formatUnrecognized("\(error)"), itemCount: 0, durationMs: ms())])
        }

        let items: [ExtensionItem] = parsed.entries.compactMap { e in
            guard e.platform == nil || e.platform == "macOS" || e.platform == "Mac Catalyst", let sdk = e.sdk else { return nil }
            let evidence = ev.make(.pluginkit, "pluginkit -mAvvv \(e.identifier)(\(e.version))",
                                   excerpt: "mark=\(e.mark.map(String.init) ?? "none") SDK=\(sdk)" + (e.path.map { " Path=\($0)" } ?? ""))
            let token = matrix.confirmedSource(for: .pluginkit, item: .extension, key: sdk, os: os.version)
            let state: Determination<ExtensionState>
            switch (e.mark, token) {
            case (_, nil): state = .unknown(.notInspectable("pluginkit is not authoritative for \(sdk)"))
            case ("+"?, _): state = .confirmed(.elected, evidence)
            case ("-"?, let t?): state = .confirmed(.ignored(token: t), evidence)
            case ("="?, _): state = .confirmed(.superseded, evidence)
            case (nil, _): state = .confirmed(.systemDefault, evidence)
            case (let m?, _): state = .unknown(.formatUnrecognized(.pluginkit, "unknown election mark \(m)"))
            }
            return ExtensionItem(
                id: "pluginkit:\(e.identifier)@\(e.path ?? e.version)", kind: .app(point: sdk), identifier: e.identifier,
                name: e.displayName ?? e.identifier, version: e.version == "(null)" ? nil : e.version, path: e.path, teamID: nil,
                state: state,
                signals: AssociationSignals(itemPath: e.path, parentBundlePath: e.parentBundle, identifier: e.identifier))
        }
        let note = "fields \(parsed.fieldFingerprint)" + (parsed.skipped > 0 ? ", \(parsed.skipped) lines skipped" : "")
        let status: SourceStatus.State = parsed.skipped > 0 ? .formatUnrecognized("\(parsed.skipped) lines skipped") : .ok
        return .init(items: items, statuses: [SourceStatus(id: .pluginkit, state: status, itemCount: items.count, durationMs: ms(), note: note)])
    }

    // MARK: system extensions

    func collectSystemExtensions() async -> ExtensionCollection {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let ev = EvidenceMaker(os: os, now: now, matrix: matrix)
        var statuses: [SourceStatus] = []

        var records: [SystemExtensionRecord] = []
        if let data = readFile("/Library/SystemExtensions/db.plist") {
            do {
                records = try SystemExtensionParser.parseDB(data)
                statuses.append(SourceStatus(id: .systemExtensionsDB, state: .ok, itemCount: records.count, durationMs: ms()))
            } catch {
                statuses.append(SourceStatus(id: .systemExtensionsDB, state: .formatUnrecognized("\(error)"), itemCount: 0, durationMs: ms()))
            }
        } else {
            statuses.append(SourceStatus(id: .systemExtensionsDB, state: .failed("cannot read db.plist"), itemCount: 0, durationMs: ms()))
        }
        let byID = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })

        let out = await runText(run, "/usr/bin/systemextensionsctl", ["list"])
        var rows: [SystemExtensionCtlRow] = []
        var ctlProblem: UnknownReason?
        if let text = out.text {
            do {
                rows = try SystemExtensionCtlParser.parse(text)
                statuses.append(SourceStatus(id: .systemExtensionsCtl, state: .ok, itemCount: rows.count, durationMs: ms()))
            } catch {
                ctlProblem = .formatUnrecognized(.systemExtensionsCtl, "\(error)")
                statuses.append(SourceStatus(id: .systemExtensionsCtl, state: .formatUnrecognized("\(error)"), itemCount: 0, durationMs: ms()))
            }
        } else {
            ctlProblem = .sourceFailed(.systemExtensionsCtl, out.failure ?? "?")
            statuses.append(SourceStatus(id: .systemExtensionsCtl, state: .failed(out.failure ?? "?"), itemCount: 0, durationMs: ms()))
        }

        func signals(_ id: String, team: String?, rec: SystemExtensionRecord?) -> AssociationSignals {
            AssociationSignals(itemPath: rec?.originPath, parentBundlePath: rec?.containerBundlePath,
                               associatedBundleIDs: rec?.appIdentifiers ?? [], identifier: id, teamID: team)
        }

        var items: [ExtensionItem] = []
        if let problem = ctlProblem {
            // State unreadable: list what db.plist knows, every state Unknown.
            items = records.map { r in
                ExtensionItem(id: "sysext:\(r.identifier)", kind: .system(category: r.categories.first ?? "unknown"),
                              identifier: r.identifier, name: r.identifier, version: r.version, path: r.originPath,
                              teamID: r.teamID, state: .unknown(problem), signals: signals(r.identifier, team: r.teamID, rec: r))
            }
        } else {
            items = rows.map { row in
                let rec = byID[row.bundleID]
                let evidence = ev.make(.systemExtensionsCtl, "systemextensionsctl list: \(row.bundleID)",
                                       excerpt: "[\(row.state)] enabled=\(row.enabledMark ? "*" : "-") active=\(row.activeMark ? "*" : "-")")
                let token = matrix.confirmedSource(for: .systemExtensionsCtl, item: .extension, key: row.category, os: os.version)
                let state: Determination<ExtensionState>
                switch (row.state, token) {
                case (_, nil): state = .unknown(.notInspectable("systemextensionsctl is not authoritative for \(row.category)"))
                case ("activated enabled", _): state = .confirmed(.activatedEnabled, evidence)
                case ("activated waiting for user", _): state = .confirmed(.waitingForUser, evidence)
                case ("activated disabled", let t?): state = .confirmed(.disabled(token: t), evidence)
                case ("terminated waiting to uninstall on reboot", _): state = .confirmed(.pendingUninstall, evidence)
                default: state = .unknown(.formatUnrecognized(.systemExtensionsCtl, "state [\(row.state)]"))
                }
                return ExtensionItem(
                    id: "sysext:\(row.bundleID)", kind: .system(category: row.category), identifier: row.bundleID,
                    name: row.name, version: row.version, path: rec?.originPath, teamID: row.teamID.isEmpty ? rec?.teamID : row.teamID,
                    state: state, signals: signals(row.bundleID, team: row.teamID.isEmpty ? rec?.teamID : row.teamID, rec: rec))
            }
        }
        return .init(items: items, statuses: statuses)
    }
}
