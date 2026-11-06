import Foundation
import InspectorModel
import InspectorParsers
import InspectorPlatform

/// Normalizer: turns collector output into `Determination`s, enforcing fail-to-Unknown.
public struct PermissionBuilder: Sendable {
    public let matrix: CapabilityMatrix
    public let os: OSInfo
    public let now: Date
    public let csreqChecker: @Sendable (Data, URL) -> Bool?

    public init(matrix: CapabilityMatrix = .phase1, os: OSInfo, now: Date = Date(),
                csreqChecker: @escaping @Sendable (Data, URL) -> Bool? = { CodeSigning.csreqMatches($0, appURL: $1) }) {
        self.matrix = matrix; self.os = os; self.now = now; self.csreqChecker = csreqChecker
    }

    private struct SourcedRow { let row: TCCRow; let source: SourceID }

    private func sources(for service: ServiceInfo) -> [SourceID] {
        switch service.store {
        case .user: [.tccUser]
        case .system: [.tccSystem]
        case .either: [.tccUser, .tccSystem]
        }
    }

    private func outcome(_ id: SourceID, _ tcc: TCCCollectorOutput) -> DBOutcome { id == .tccUser ? tcc.user : tcc.system }

    private func rowEvidence(_ r: SourcedRow, unvalidated: Bool) -> Evidence {
        let when = r.row.lastModified.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let target = r.row.indirectObject.map { " indirect_object_identifier=\($0)" } ?? ""
        return Evidence(
            source: r.source,
            locator: "\(r.source == .tccUser ? "user" : "system") TCC.db access: service=\(r.row.service) client=\(r.row.client)\(target)",
            observedAt: now, osBuild: os.build,
            excerpt: "client_type=\(r.row.clientType) auth_value=\(r.row.authValue) auth_reason=\(r.row.authReason) last_modified=\(when)",
            unvalidatedOS: unvalidated)
    }

    /// Build permission items for one client (matching rows already selected) + declared usage.
    public func items(rowsByService: [String: [(TCCRow, SourceID)]], usage: [String: String],
                      appURL: URL?, tcc: TCCCollectorOutput) -> [PermissionItem] {
        var services = Set(rowsByService.keys)
        var declaredEvidence: [String: Evidence] = [:]
        for svc in ServiceCatalog.all {
            for key in svc.usageKeys {
                if let text = usage[key] {
                    services.insert(svc.raw)
                    declaredEvidence[svc.raw] = Evidence(
                        source: .bundleInfo, locator: "Info.plist \(key)", observedAt: now, osBuild: os.build, excerpt: text)
                    break
                }
            }
        }

        let items: [PermissionItem] = services.flatMap { raw -> [PermissionItem] in
            let info = ServiceCatalog.info(for: raw)
            let candidates = (rowsByService[raw] ?? []).map { SourcedRow(row: $0.0, source: $0.1) }
            // Automation decisions belong to a target, not to the service as a whole.
            let byTarget: [String?: [SourcedRow]] = candidates.isEmpty
                ? [nil: []] : Dictionary(grouping: candidates, by: { $0.row.indirectObject })
            return byTarget.map { target, rows in
                let latest = rows.max { ($0.row.lastModified ?? .distantPast) < ($1.row.lastModified ?? .distantPast) }

                var item = PermissionItem(service: info, state: .unknown(.needsFullDiskAccess),
                                          declared: declaredEvidence[raw], indirectObject: target)
                item.recordedIn = Set(rows.map(\.source))
                if let r = latest {
                    item.lastModified = r.row.lastModified
                    if let token = matrix.confirmedSource(for: r.source, item: .privacy, key: raw, os: os.version) {
                        let ev = rowEvidence(r, unvalidated: token.unvalidatedOS)
                        if let st = TCCParser.state(for: r.row, token: token) {
                            item.state = .confirmed(st, ev)
                        } else {
                            item.state = .unknown(.formatUnrecognized(r.source, "auth_value \(r.row.authValue)"))
                        }
                        if let csreq = r.row.csreq, let url = appURL {
                            if let ok = csreqChecker(csreq, url) {
                                item.signatureMatch = .confirmed(ok, ev)
                                if !ok { item.state = .recordedForDifferentSignature(ev) }
                            } else {
                                item.signatureMatch = .unknown(.notInspectable("code requirement could not be evaluated"))
                            }
                        }
                    } else {
                        item.state = .unknown(.notInspectable("\(r.source) is not authoritative for \(raw)"))
                    }
                } else {
                    item.state = absentState(info, tcc)
                }
                return item
            }
        }
        return items.sorted { $0.displayName < $1.displayName }
    }

    /// No row: "no record" only if every DB that could hold the service was read OK and the matrix allows absence.
    private func absentState(_ info: ServiceInfo, _ tcc: TCCCollectorOutput) -> Determination<PermissionState> {
        var lastRead: SourceID?
        for src in sources(for: info) {
            switch outcome(src, tcc) {
            case .unavailable(let reason, _): return .unknown(reason)
            case .read(let parsed):
                // Rows we could not parse might have been the one we are looking for.
                guard parsed.skippedRows == 0 else {
                    return .unknown(.formatUnrecognized(src, "\(parsed.skippedRows) unreadable rows; absence not trustworthy"))
                }
                guard matrix.absenceMeaningful(source: src, item: .privacy, key: info.raw) else {
                    return .unknown(.notInspectable("absence in \(src) is not meaningful for \(info.raw)"))
                }
                lastRead = src
            }
        }
        guard let src = lastRead else { return .unknown(.notInspectable("no source for \(info.raw)")) }
        let unvalidated = matrix.capability(src)?.isUnvalidated(on: os.version) ?? true
        return .notRecorded(Evidence(source: src, locator: "access table: no row for service=\(info.raw)",
                                     observedAt: now, osBuild: os.build, unvalidatedOS: unvalidated))
    }
}
