import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform

public struct StartupCollection: Sendable {
    public var items: [StartupItem]
    public var statuses: [SourceStatus]
}

public typealias DirectoryLister = @Sendable (_ path: String) -> [String]?

public let defaultDirectoryLister: DirectoryLister = { dir in
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    return names.sorted().map { (dir as NSString).appendingPathComponent($0) }
}

public struct StartupCollector: Sendable {
    public var run: CommandRunner
    public var readFile: FileReader
    public var listDirectory: DirectoryLister
    /// Tells "directory missing" (normal) from "directory exists but could not be listed" (a problem).
    public var directoryExists: @Sendable (String) -> Bool
    public var matrix: CapabilityMatrix
    public var os: OSInfo
    public var now: Date
    public var uid: UInt32
    public var home: String
    /// Inventoried app paths, scanned for bundled login items and launch plists.
    public var appPaths: [String]
    /// Background Task Management report (live read or imported file). nil → approval stays Unknown.
    public var btm: BTMReport?
    public var bootTime: Date? = SystemInfo.bootTime()
    public var pathExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    public var modifiedAt: @Sendable (String) -> Date? = StartupCollector.modificationDate
    /// Upper bound on per-job `launchctl print` calls for registered (ServiceManagement) jobs.
    public var maxRegisteredJobLookups = 300

    public init(run: @escaping CommandRunner = defaultCommandRunner, readFile: @escaping FileReader = defaultFileReader,
                listDirectory: @escaping DirectoryLister = defaultDirectoryLister,
                directoryExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                matrix: CapabilityMatrix = .phase1, os: OSInfo = SystemInfo.current(), now: Date = Date(),
                uid: UInt32 = getuid(), home: String = NSHomeDirectory(), appPaths: [String] = []) {
        self.run = run; self.readFile = readFile; self.listDirectory = listDirectory; self.directoryExists = directoryExists; self.matrix = matrix
        self.os = os; self.now = now; self.uid = uid; self.home = home; self.appPaths = appPaths
    }

    // Domain listing results
    private struct Domain: Sendable {
        var services: [String: LaunchdService]?        // nil = unreadable
        var disabled: [String: Bool]?
        var servicesProblem: String?
        var disabledProblem: String?
    }

    public func collect() async -> StartupCollection {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        let ev = EvidenceMaker(os: os, now: now, matrix: matrix)

        async let g = loadDomain("gui/\(uid)")
        async let s = loadDomain("system")
        let (gui, sys) = await (g, s)
        func dom(_ d: LaunchdDomain) -> Domain { d == .gui ? gui : sys }
        func name(_ d: LaunchdDomain) -> String { d == .gui ? "gui/\(uid)" : "system" }

        let duplicates = duplicateLabels()
        func ambiguous(_ label: String, _ d: LaunchdDomain) -> UnknownReason? {
            duplicates.contains("\(d)/\(label)")
                ? .notInspectable("several files declare the label \(label); launchd state cannot be assigned to one of them") : nil
        }

        func loadState(_ label: String, _ d: LaunchdDomain) -> Determination<StartupState> {
            if let r = ambiguous(label, d) { return .unknown(r) }
            let dm = dom(d)
            guard let services = dm.services else {
                return .unknown(.sourceFailed(.launchctlDomain, dm.servicesProblem ?? "unreadable"))
            }
            if let svc = services[label] {
                let e = ev.make(.launchctlDomain, "launchctl print \(name(d)): \(label)", excerpt: "pid=\(svc.pid) flags=\(svc.flags)")
                return .confirmed(StartupState(svc.pid > 0 ? .running(pid: svc.pid) : .loaded), e)
            }
            guard matrix.absenceMeaningful(source: .launchctlDomain, item: .startup, key: label) else {
                return .unknown(.notInspectable("absence in launchctl is not meaningful"))
            }
            return .confirmed(StartupState(.notLoaded),
                              ev.make(.launchctlDomain, "launchctl print \(name(d)): no service \(label)"))
        }

        func override(_ label: String, _ d: LaunchdDomain) -> Determination<LaunchdOverride> {
            if let r = ambiguous(label, d) { return .unknown(r) }
            let dm = dom(d)
            guard let disabled = dm.disabled else {
                return .unknown(.sourceFailed(.launchctlDisabled, dm.disabledProblem ?? "unreadable"))
            }
            if let isDisabled = disabled[label] {
                let e = ev.make(.launchctlDisabled, "launchctl print-disabled \(name(d)): \(label)", excerpt: isDisabled ? "disabled" : "enabled")
                if !isDisabled { return .confirmed(.enabled, e) }
                guard let t = matrix.confirmedSource(for: .launchctlDisabled, item: .startup, key: label, os: os.version) else {
                    return .unknown(.notInspectable("print-disabled is not authoritative"))
                }
                return .confirmed(.disabled(token: t), e)
            }
            guard matrix.absenceMeaningful(source: .launchctlDisabled, item: .startup, key: label) else {
                return .unknown(.notInspectable("absence in print-disabled is not meaningful"))
            }
            return .notRecorded(ev.make(.launchctlDisabled, "launchctl print-disabled \(name(d)): no override for \(label)"))
        }

        var items: [StartupItem] = []
        var seen = Set<String>()                     // "domain/label"
        var statuses: [SourceStatus] = []

        // ---- 1. Legacy plists --------------------------------------------------------------
        let dirs: [(String, StartupKind, LaunchdDomain)] = [
            (home + "/Library/LaunchAgents", .launchAgent, .gui),
            ("/Library/LaunchAgents", .launchAgent, .gui),
            ("/Library/LaunchDaemons", .launchDaemon, .system),
        ]
        var plistCount = 0, plistProblems = 0
        for (dir, kind, d) in dirs {
            let listing = listDirectory(dir)
            if listing == nil && directoryExists(dir) { plistProblems += 1 }      // exists but unlistable
            for path in (listing ?? []) where path.hasSuffix(".plist") {
                plistCount += 1
                let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                guard let data = readFile(path) else {
                    plistProblems += 1
                    items.append(unreadable(label: fallback, path: path, kind: kind, d: d,
                                            reason: .sourceFailed(.launchdPlists, "cannot read plist (permissions?)")))
                    continue
                }
                do {
                    let job = try LaunchdPlistParser.parse(data)
                    seen.insert("\(d)/\(job.label)")
                    items.append(StartupItem(
                        id: "plist:\(path)", kind: kind, domain: d, label: job.label, plistPath: path, program: job.program,
                        runAtLoad: job.runAtLoad, keepAlive: job.keepAlive, loadState: loadState(job.label, d),
                        override: override(job.label, d),
                        signals: AssociationSignals(itemPath: path, executablePath: job.program,
                                                    associatedBundleIDs: job.associatedBundleIDs, identifier: job.label)))
                } catch {
                    plistProblems += 1
                    items.append(unreadable(label: fallback, path: path, kind: kind, d: d,
                                            reason: .formatUnrecognized(.launchdPlists, "\(error)")))
                }
            }
        }
        statuses.append(SourceStatus(id: .launchdPlists, state: plistProblems > 0 ? .failed("\(plistProblems) plists unreadable") : .ok,
                                     itemCount: plistCount, durationMs: ms()))

        // ---- 2. Bundled login-item helpers and launch plists inside apps ------------------------
        var bundledCount = 0, bundledProblems = 0
        func listBundled(_ dir: String) -> [String] {
            let l = listDirectory(dir)
            if l == nil && directoryExists(dir) { bundledProblems += 1 }
            return l ?? []
        }
        for app in appPaths {
            for helper in listBundled(app + "/Contents/Library/LoginItems") where helper.hasSuffix(".app") {
                guard let info = BundleReader.read(URL(fileURLWithPath: helper)), let id = info.bundleID else { bundledProblems += 1; continue }
                bundledCount += 1
                seen.insert("gui/\(id)")
                items.append(StartupItem(
                    id: "helper:\(helper)", kind: .loginItemHelper, domain: .gui, label: id, plistPath: nil,
                    program: helper, runAtLoad: nil, keepAlive: nil, loadState: loadState(id, .gui), override: override(id, .gui),
                    signals: AssociationSignals(itemPath: helper, executablePath: helper, identifier: id)))
            }
            for (sub, d) in [("LaunchAgents", LaunchdDomain.gui), ("LaunchDaemons", .system)] {
                for path in listBundled(app + "/Contents/Library/" + sub) where path.hasSuffix(".plist") {
                    guard let data = readFile(path), let job = try? LaunchdPlistParser.parse(data) else { bundledProblems += 1; continue }
                    bundledCount += 1
                    seen.insert("\(d)/\(job.label)")
                    items.append(StartupItem(
                        id: "bundled:\(path)", kind: .bundledLaunchPlist, domain: d, label: job.label, plistPath: path,
                        program: job.program ?? job.bundleProgram, runAtLoad: job.runAtLoad, keepAlive: job.keepAlive,
                        loadState: loadState(job.label, d), override: override(job.label, d),
                        signals: AssociationSignals(itemPath: path, executablePath: job.program,
                                                    associatedBundleIDs: job.associatedBundleIDs, identifier: job.label)))
                }
            }
        }
        statuses.append(SourceStatus(id: .bundledHelpers,
                                     state: bundledProblems > 0 ? .failed("\(bundledProblems) bundled items or folders unreadable") : .ok,
                                     itemCount: bundledCount, durationMs: ms()))

        // ---- 3. Registered (ServiceManagement) jobs with no plist we know about ---------------
        var candidates: [(String, LaunchdDomain)] = []
        for d in [LaunchdDomain.gui, .system] {
            for label in (dom(d).services ?? [:]).keys.sorted() where !seen.contains("\(d)/\(label)") && Self.isRegistrationCandidate(label) {
                candidates.append((label, d))
            }
        }
        let capped = Array(candidates.prefix(maxRegisteredJobLookups))
        let (jobs, lookupFailures) = await lookupJobs(capped, nameOf: name)
        var lookupProblems: [String] = []
        if candidates.count > capped.count { lookupProblems.append("\(candidates.count - capped.count) candidates skipped (cap \(maxRegisteredJobLookups))") }
        if lookupFailures > 0 { lookupProblems.append("\(lookupFailures) of \(capped.count) job lookups failed") }
        if Task.isCancelled { lookupProblems.append("cancelled") }
        statuses.append(SourceStatus(id: .launchctlJobs, state: lookupProblems.isEmpty ? .ok : .failed(lookupProblems.joined(separator: "; ")),
                                     itemCount: jobs.count, durationMs: ms()))
        for (label, d, job) in jobs {
            guard job.managedBy == "com.apple.xpc.ServiceManagement" || job.parentBundleID != nil else { continue }
            items.append(StartupItem(
                id: "sm:\(d)/\(label)", kind: .serviceManagement, domain: d, label: label, plistPath: nil,
                program: job.program, runAtLoad: nil, keepAlive: nil, loadState: loadState(label, d), override: override(label, d),
                signals: AssociationSignals(executablePath: job.program, parentBundleID: job.parentBundleID, identifier: label)))
        }

        // ---- 4. Background Task Management: approval + items only BTM knows about ----------------
        if let report = btm {
            let b = BTMMerger(report: report, matrix: matrix, os: os, now: now, uid: Int(uid), bootTime: bootTime,
                              pathExists: pathExists, modifiedAt: modifiedAt)
            for i in items.indices { items[i].approval = b.approval(for: items[i]) }
            let known = Set(items.map { "\($0.domain)/\($0.label)" })
            for r in b.startupRecordsMissing(from: known, items: items) {
                let d: LaunchdDomain = (r.kind == .daemon || r.kind == .legacyDaemon) ? .system : .gui
                let path = b.resolvedPath(r)
                let kind: StartupKind = switch r.kind {
                case .loginItem: .loginItemHelper
                case .legacyAgent: .launchAgent
                case .legacyDaemon: .launchDaemon
                default: .serviceManagement
                }
                var it = StartupItem(
                    id: "btm:\(r.uid):\(r.identifier)", kind: kind, domain: d, label: r.label, plistPath: kind == .loginItemHelper ? nil : path,
                    program: r.executablePath ?? (kind == .loginItemHelper ? path : nil), runAtLoad: nil, keepAlive: nil,
                    loadState: loadState(r.label, d), override: override(r.label, d),
                    signals: AssociationSignals(
                        itemPath: path, executablePath: r.executablePath, parentBundleID: b.parentBundleID(r),
                        associatedBundleIDs: r.assocBundleIDs, identifier: r.label, teamID: r.teamID))
                it.approval = b.approval(for: it)
                items.append(it)
            }
        }

        // ---- domain statuses ----------------------------------------------------------------
        func domainStatus(_ id: SourceID, _ pick: (Domain) -> String?, count: Int) -> SourceStatus {
            let problems = [gui, sys].compactMap(pick)
            return SourceStatus(id: id, state: problems.isEmpty ? .ok : .failed(problems.joined(separator: "; ")),
                                itemCount: count, durationMs: ms())
        }
        statuses.append(domainStatus(.launchctlDomain, { $0.servicesProblem }, count: (gui.services?.count ?? 0) + (sys.services?.count ?? 0)))
        statuses.append(domainStatus(.launchctlDisabled, { $0.disabledProblem }, count: (gui.disabled?.count ?? 0) + (sys.disabled?.count ?? 0)))
        return StartupCollection(items: items, statuses: statuses)
    }

    // MARK: helpers

    /// Newest of the item's own mtime and, for bundles, its Info.plist (a directory's mtime ignores in-place edits).
    @Sendable static func modificationDate(_ path: String) -> Date? {
        let fm = FileManager.default
        func m(_ p: String) -> Date? { try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date }
        let dates = [m(path), m(path + "/Contents/Info.plist")].compactMap { $0 }
        return dates.max()
    }

    /// Labels worth a per-job lookup: not Apple, not per-app session labels, not raw addresses.
    static func isRegistrationCandidate(_ label: String) -> Bool {
        !(label.hasPrefix("com.apple.") || label.hasPrefix("application.") || label.hasPrefix("0x")
          || label.hasPrefix("[") || label.hasPrefix("com.openssh.") || label.hasPrefix("gui/") || label.hasPrefix("user/"))
    }

    private func unreadable(label: String, path: String, kind: StartupKind, d: LaunchdDomain, reason: UnknownReason) -> StartupItem {
        StartupItem(id: "plist:\(path)", kind: kind, domain: d, label: label, plistPath: path, program: nil,
                    runAtLoad: nil, keepAlive: nil, loadState: .unknown(reason), override: .unknown(reason),
                    signals: AssociationSignals(itemPath: path, identifier: label))
    }

    private func loadDomain(_ target: String) async -> Domain {
        var d = Domain()
        let sv = await runText(run, "/bin/launchctl", ["print", target])
        if let t = sv.text {
            do { d.services = Dictionary(try LaunchctlParser.parseServices(t).map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a }) }
            catch { d.servicesProblem = "\(target): \(error)" }
        } else { d.servicesProblem = "\(target): \(sv.failure ?? "?")" }
        let ds = await runText(run, "/bin/launchctl", ["print-disabled", target])
        if let t = ds.text {
            do { d.disabled = try LaunchctlParser.parseDisabled(t) } catch { d.disabledProblem = "\(target): \(error)" }
        } else { d.disabledProblem = "\(target): \(ds.failure ?? "?")" }
        return d
    }

    /// Labels declared by more than one file in the same launchd domain ("gui/label"). Their launchd state is ambiguous.
    private func duplicateLabels() -> Set<String> {
        var counts: [String: Int] = [:]
        func note(_ label: String, _ d: LaunchdDomain) { counts["\(d)/\(label)", default: 0] += 1 }
        let dirs: [(String, LaunchdDomain)] = [(home + "/Library/LaunchAgents", .gui), ("/Library/LaunchAgents", .gui), ("/Library/LaunchDaemons", .system)]
        func scan(_ dir: String, _ d: LaunchdDomain) {
            for path in listDirectory(dir) ?? [] where path.hasSuffix(".plist") {
                if let data = readFile(path), let job = try? LaunchdPlistParser.parse(data) { note(job.label, d) }
            }
        }
        for (dir, d) in dirs { scan(dir, d) }
        for app in appPaths {
            scan(app + "/Contents/Library/LaunchAgents", .gui)
            scan(app + "/Contents/Library/LaunchDaemons", .system)
            for helper in listDirectory(app + "/Contents/Library/LoginItems") ?? [] where helper.hasSuffix(".app") {
                if let id = BundleReader.read(URL(fileURLWithPath: helper))?.bundleID { note(id, .gui) }
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func lookupJobs(_ list: [(String, LaunchdDomain)], nameOf: (LaunchdDomain) -> String) async -> ([(String, LaunchdDomain, LaunchdJob)], Int) {
        let targets = list.map { ($0.0, $0.1, "\(nameOf($0.1))/\($0.0)") }
        let run = self.run
        var out: [(String, LaunchdDomain, LaunchdJob)] = []
        var failures = 0
        var index = 0
        let batch = 8
        while index < targets.count, !Task.isCancelled {
            let slice = targets[index..<min(index + batch, targets.count)]
            await withTaskGroup(of: (String, LaunchdDomain, LaunchdJob)?.self) { g in
                for (label, d, target) in slice {
                    g.addTask {
                        let o = await runText(run, "/bin/launchctl", ["print", target])
                        guard let t = o.text, let job = try? LaunchdJobParser.parse(t) else { return nil }
                        return (label, d, job)
                    }
                }
                for await r in g { if let r { out.append(r) } else { failures += 1 } }
            }
            index += batch
        }
        return (out.sorted { $0.0 < $1.0 }, failures)
    }
}
