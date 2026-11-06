import Testing
import Foundation
import InspectorModel
@testable import InspectorParsers

@Suite struct TCCParserTests {
    static let cols = ["service", "client", "client_type", "auth_value", "auth_reason", "auth_version", "csreq",
                       "indirect_object_identifier", "flags", "last_modified"]

    func row(_ service: String, _ client: String, type: Int64 = 0, value: Int64 = 2, reason: Int64 = 3,
             ts: Int64 = 1_700_000_000) -> [String: SQLValue] {
        ["service": .text(service), "client": .text(client), "client_type": .int(type),
         "auth_value": .int(value), "auth_reason": .int(reason), "auth_version": .int(1),
         "csreq": .null, "indirect_object_identifier": .text("UNUSED"), "flags": .int(0), "last_modified": .int(ts)]
    }

    @Test func parsesRows() throws {
        let t = TCCTable(columns: Self.cols, rows: [row("kTCCServiceCamera", "com.x.app")])
        let r = try TCCParser.parse(t)
        #expect(r.rows.count == 1)
        #expect(r.rows[0].service == "kTCCServiceCamera")
        #expect(r.rows[0].indirectObject == nil)   // "UNUSED" sentinel dropped
        #expect(r.rows[0].lastModified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.skippedRows == 0)
    }

    @Test func missingRequiredColumnThrows() {
        let t = TCCTable(columns: ["service", "client"], rows: [])
        #expect(throws: TCCParseError.self) { try TCCParser.parse(t) }
    }

    @Test func garbledRowsAreSkippedAndCounted() throws {
        var bad = row("kTCCServiceCamera", "a"); bad["auth_value"] = .text("two")
        var badType = row("kTCCServiceCamera", "b"); badType["client_type"] = .int(9)
        let t = TCCTable(columns: Self.cols, rows: [bad, badType, row("kTCCServiceMicrophone", "c")])
        let r = try TCCParser.parse(t)
        #expect(r.rows.count == 1)
        #expect(r.skippedRows == 2)
    }

    @Test func fingerprintIsStableAndOrderSensitive() {
        #expect(TCCParser.fingerprint(columns: ["a", "b"]) == TCCParser.fingerprint(columns: ["a", "b"]))
        #expect(TCCParser.fingerprint(columns: ["a", "b"]) != TCCParser.fingerprint(columns: ["b", "a"]))
    }

    @Test func stateMapping() throws {
        let tok = try #require(CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy, key: "k", os: OSVersion(26)))
        func st(_ v: Int64, _ reason: Int64 = 3) throws -> PermissionState? {
            let r = try TCCParser.parse(TCCTable(columns: Self.cols, rows: [row("s", "c", value: v, reason: reason)])).rows[0]
            return TCCParser.state(for: r, token: tok)
        }
        #expect(try st(0)?.kind == .denied)
        #expect(try st(1)?.kind == .ask)
        #expect(try st(2)?.kind == .allowed)
        #expect(try st(3)?.kind == .limited)
        #expect(try st(2, 6)?.managed == true)
        #expect(try st(0, 7)?.managed == true)
        #expect(try st(2, 2)?.managed == false)
        #expect(try st(99) == nil)       // unrecognized auth_value → caller emits Unknown
    }

    @Test(arguments: [Int64(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 99])
    func preservesAuthorizationReason(reason: Int64) throws {
        let token = try #require(CapabilityMatrix.phase1.confirmedSource(for: .tccUser, item: .privacy,
                                                                       key: "kTCCServiceCamera", os: OSVersion(26)))
        for value: Int64 in [0, 1, 2, 3] {
            let parsed = try TCCParser.parse(TCCTable(columns: Self.cols, rows: [row("kTCCServiceCamera", "com.x", value: value, reason: reason)]))
            let state = try #require(TCCParser.state(for: parsed.rows[0], token: token))
            #expect(state.authReason == Int(reason))
            #expect(state.reasonDescription != nil)
        }
    }
}
