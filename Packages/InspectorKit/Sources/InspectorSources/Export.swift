import Foundation
import InspectorModel

public enum ExportRedaction: Sendable {
    /// Paths as found.
    case none
    /// Home folder becomes `~`, other `/Users/<name>` become `/Users/<user>`. Applied to every string in the file.
    case paths
}

/// Optional JSON export of a snapshot. Only runs when the user asks; nothing is sent anywhere.
public enum SnapshotExporter {
    struct EvidenceDTO: Codable { let source: String; let locator: String; let observedAt: Date; let osBuild: String; let excerpt: String?; let unvalidatedOS: Bool; let staleSource: Bool }
    struct StateDTO: Codable { let kind: String; let value: String?; let reason: String?; let evidence: EvidenceDTO? }
    struct PermissionDTO: Codable { let service: String; let name: String; let state: StateDTO; let declared: EvidenceDTO?; let lastModified: Date?; let signatureMatch: StateDTO? }
    struct AssociationDTO: Codable { let target: String; let rank: Int; let confidence: String?; let reason: String }
    struct ExtensionDTO: Codable { let id: String; let kind: String; let identifier: String; let name: String; let version: String?; let path: String?; let teamID: String?; let state: StateDTO; let association: AssociationDTO }
    struct StartupDTO: Codable { let id: String; let kind: String; let label: String; let path: String?; let program: String?; let loadState: StateDTO; let override: StateDTO; let approval: StateDTO; let association: AssociationDTO }
    struct AppDTO: Codable { let path: String; let name: String; let bundleID: String?; let version: String?; let signature: String; let teamID: String?; let permissions: [PermissionDTO]; let extensions: [ExtensionDTO]; let startupItems: [StartupDTO] }
    struct ClientDTO: Codable { let kind: String; let client: String; let permissions: [PermissionDTO] }
    struct GroupDTO: Codable { let teamID: String; let extensions: [ExtensionDTO]; let startupItems: [StartupDTO] }
    struct SourceDTO: Codable { let id: String; let state: String; let itemCount: Int; let lastRun: Date; let note: String? }
    struct Doc: Codable {
        let schema: Int; let generatedAt: Date; let macOS: String; let build: String; let fullDiskAccess: String; let redaction: String
        let sources: [SourceDTO]; let apps: [AppDTO]; let unattributedClients: [ClientDTO]
        let developerGroups: [GroupDTO]; let unattributedExtensions: [ExtensionDTO]; let unattributedStartup: [StartupDTO]
    }

    public static func json(_ s: Snapshot, redaction: ExportRedaction, home: String = NSHomeDirectory()) throws -> Data {
        let doc = document(s, redaction: redaction, home: home)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]   // readable paths; redaction no longer depends on it
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(doc)
    }

    /// Replaces the home folder with `~` and any other `/Users/<name>` with `/Users/<user>`.
    /// Runs on decoded string values, before JSON encoding: after encoding, a home path containing quotes or
    /// backslashes would no longer match its raw form.
    public static func redact(_ text: String, home: String) -> String {
        var t = text
        if home.count > 1 { t = t.replacingOccurrences(of: home, with: "~") }
        return t.replacingOccurrences(of: #"/Users/(?!<user>)[^/\s"\\]+"#, with: "/Users/<user>", options: .regularExpression)
    }

    /// Applied to every string that goes into the document.
    struct R {
        let on: Bool; let home: String
        func s(_ x: String) -> String { on ? SnapshotExporter.redact(x, home: home) : x }
        func o(_ x: String?) -> String? { x.map(s) }
    }

    // MARK: building

    static func document(_ s: Snapshot, redaction: ExportRedaction, home: String) -> Doc {
        let r = R(on: redaction == .paths, home: home)
        return Doc(schema: 1, generatedAt: s.createdAt, macOS: s.os.version.description, build: s.os.build,
            fullDiskAccess: "\(s.fullDiskAccess)", redaction: redaction == .paths ? "paths" : "none",
            sources: s.sources.map { SourceDTO(id: $0.id.rawValue, state: r.s("\($0.state)"), itemCount: $0.itemCount, lastRun: $0.lastRun, note: r.o($0.note)) },
            apps: s.apps.map { a in AppDTO(path: r.s(a.path), name: r.s(a.name), bundleID: a.bundleID, version: a.version, signature: "\(a.signing.kind)",
                                           teamID: a.signing.teamID, permissions: a.permissions.map { perm($0, r) },
                                           extensions: a.extensions.map { ext($0, r) }, startupItems: a.startupItems.map { start($0, r) }) },
            unattributedClients: s.unattributed.map { ClientDTO(kind: "\($0.kind)", client: r.s($0.client), permissions: $0.permissions.map { perm($0, r) }) },
            developerGroups: s.developerGroups.map { GroupDTO(teamID: $0.teamID, extensions: $0.extensions.map { ext($0, r) }, startupItems: $0.startupItems.map { start($0, r) }) },
            unattributedExtensions: s.unattributedExtensions.map { ext($0, r) }, unattributedStartup: s.unattributedStartup.map { start($0, r) })
    }

    static func ev(_ e: Evidence?, _ r: R) -> EvidenceDTO? {
        e.map { EvidenceDTO(source: $0.source.rawValue, locator: r.s($0.locator), observedAt: $0.observedAt, osBuild: $0.osBuild,
                            excerpt: r.o($0.excerpt), unvalidatedOS: $0.unvalidatedOS, staleSource: $0.staleSource) }
    }

    static func state<V>(_ d: Determination<V>, _ r: R, _ describe: (V) -> String = { "\($0)" }) -> StateDTO {
        switch d {
        case .confirmed(let v, let e): StateDTO(kind: "confirmed", value: r.s(describe(v)), reason: nil, evidence: ev(e, r))
        case .notRecorded(let e): StateDTO(kind: "notRecorded", value: nil, reason: nil, evidence: ev(e, r))
        case .recordedForDifferentSignature(let e): StateDTO(kind: "recordedForDifferentSignature", value: nil, reason: nil, evidence: ev(e, r))
        case .declared(let e): StateDTO(kind: "declared", value: nil, reason: nil, evidence: ev(e, r))
        case .inferred(let v, let e, let why): StateDTO(kind: "inferred", value: r.s(describe(v)), reason: r.s(why), evidence: ev(e, r))
        case .unknown(let u): StateDTO(kind: "unknown", value: nil, reason: r.s(u.message), evidence: nil)
        }
    }

    static func perm(_ p: PermissionItem, _ r: R) -> PermissionDTO {
        PermissionDTO(service: p.service.raw, name: r.s(p.displayName),
                      state: state(p.state, r) { "\($0.kind)" + ($0.managed ? " (managed)" : "") }, declared: ev(p.declared, r),
                      lastModified: p.lastModified, signatureMatch: p.signatureMatch.map { state($0, r) })
    }
    static func assoc(_ a: Association, _ r: R) -> AssociationDTO {
        AssociationDTO(target: r.s("\(a.target)"), rank: a.rank, confidence: a.confidence.map { "\($0)" }, reason: r.s(a.reason))
    }
    static func ext(_ e: ExtensionItem, _ r: R) -> ExtensionDTO {
        ExtensionDTO(id: r.s(e.id), kind: r.s("\(e.kind)"), identifier: e.identifier, name: r.s(e.name), version: e.version, path: r.o(e.path),
                     teamID: e.teamID, state: state(e.state, r) { "\($0.kind)" }, association: assoc(e.association, r))
    }
    static func start(_ i: StartupItem, _ r: R) -> StartupDTO {
        StartupDTO(id: r.s(i.id), kind: "\(i.kind)", label: r.s(i.label), path: r.o(i.plistPath), program: r.o(i.program),
                   loadState: state(i.loadState, r) { "\($0.kind)" }, override: state(i.override, r) { "\($0.kind)" },
                   approval: state(i.approval, r) { "enabled=\($0.enabled) allowed=\($0.allowed) notified=\($0.notified)" },
                   association: assoc(i.association, r))
    }
}
