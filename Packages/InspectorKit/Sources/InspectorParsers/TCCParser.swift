import Foundation
import CryptoKit
import InspectorModel

/// One row of the TCC `access` table. Column set varies by OS; optional fields tolerate absence.
public struct TCCRow: Sendable, Hashable {
    public let service: String
    public let client: String
    /// 0 = bundle identifier, 1 = absolute path.
    public let clientType: Int
    /// 0 denied, 1 unknown/ask, 2 allowed, 3 limited.
    public let authValue: Int
    public let authReason: Int
    public let csreq: Data?
    public let indirectObject: String?
    public let lastModified: Date?
    public let flags: Int?
}

public struct TCCTable: Sendable {
    public var columns: [String]
    public var rows: [[String: SQLValue]]
    public init(columns: [String], rows: [[String: SQLValue]]) { self.columns = columns; self.rows = rows }
}

public struct TCCParseResult: Sendable {
    public let rows: [TCCRow]
    public let schemaFingerprint: String
    /// Rows skipped because a required field was missing or had the wrong type.
    public let skippedRows: Int
}

public enum TCCParseError: Error, Sendable, Equatable {
    case missingColumns([String])
}

public enum TCCParser {
    public static let requiredColumns = ["service", "client", "client_type", "auth_value", "auth_reason", "last_modified"]

    /// Fingerprint of `PRAGMA table_info(access)` column names (order-sensitive).
    public static func fingerprint(columns: [String]) -> String {
        let digest = SHA256.hash(data: Data(columns.joined(separator: ",").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Pure: never guesses. Missing required columns → throws (caller maps to `.unknown(.formatUnrecognized)`).
    public static func parse(_ table: TCCTable) throws -> TCCParseResult {
        let missing = requiredColumns.filter { !table.columns.contains($0) }
        guard missing.isEmpty else { throw TCCParseError.missingColumns(missing) }

        var out: [TCCRow] = []
        var skipped = 0
        for r in table.rows {
            guard let service = r["service"]?.textValue,
                  let client = r["client"]?.textValue,
                  let clientType = r["client_type"]?.intValue,
                  let authValue = r["auth_value"]?.intValue,
                  let authReason = r["auth_reason"]?.intValue,
                  (0...1).contains(clientType)
            else { skipped += 1; continue }
            let ts = r["last_modified"]?.intValue
            out.append(TCCRow(
                service: service, client: client, clientType: Int(clientType),
                authValue: Int(authValue), authReason: Int(authReason),
                csreq: r["csreq"]?.blobValue,
                indirectObject: r["indirect_object_identifier"]?.textValue.flatMap { $0 == "UNUSED" ? nil : $0 },
                lastModified: ts.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                flags: r["flags"]?.intValue.map(Int.init)))
        }
        return TCCParseResult(rows: out, schemaFingerprint: fingerprint(columns: table.columns), skippedRows: skipped)
    }

    /// Reason codes that mean "set by policy", not by the user.
    public static func isManaged(authReason: Int) -> Bool { authReason == 6 || authReason == 7 }

    /// Maps a row to a state. Unrecognized `auth_value` → nil (caller emits Unknown; never guess).
    /// `token` proves the matrix allows negatives for this service on this OS.
    public static func state(for row: TCCRow, token: ConfirmedSource) -> PermissionState? {
        let managed = isManaged(authReason: row.authReason)
        switch row.authValue {
        case 0: return .denied(managed: managed, authReason: row.authReason, token: token)
        case 1: return .ask(authReason: row.authReason)
        case 2: return .allowed(managed: managed, authReason: row.authReason)
        case 3: return .limited(managed: managed, authReason: row.authReason)
        default: return nil
        }
    }
}
