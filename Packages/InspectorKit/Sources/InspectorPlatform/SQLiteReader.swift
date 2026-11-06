import Foundation
import SQLite3
import InspectorModel
import InspectorParsers

public enum SQLiteReadError: Error, Sendable, Equatable {
    case openFailed(code: Int32, message: String)
    case queryFailed(code: Int32, message: String)
}

/// Read-only access through the system libsqlite3. Never writes or copies the database.
public enum SQLiteReader {
    private static let transient = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

    public static func readTable(at path: String, table: String, busyTimeoutMs: Int32 = 250) throws -> TCCTable {
        try Task.checkCancellation()
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteReadError.openFailed(code: rc, message: msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, busyTimeoutMs)
        // SQLite checks this while a query runs; cancellation need not wait for a full table scan.
        sqlite3_progress_handler(db, 1000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)

        let columns = try columnNames(db, table: table)
        let rows = try select(db, "SELECT * FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\"")
        return TCCTable(columns: columns, rows: rows)
    }

    private static func columnNames(_ db: OpaquePointer, table: String) throws -> [String] {
        let rows = try select(db, "SELECT name FROM pragma_table_info(?1)", bind: table)
        return rows.compactMap { $0["name"]?.textValue }
    }

    private static func select(_ db: OpaquePointer, _ sql: String, bind: String? = nil) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteReadError.queryFailed(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let bind { sqlite3_bind_text(stmt, 1, bind, -1, transient) }

        let n = sqlite3_column_count(stmt)
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var out: [[String: SQLValue]] = []
        while true {
            try Task.checkCancellation()
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteReadError.queryFailed(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
            var row: [String: SQLValue] = [:]
            for i in 0..<n {
                let v: SQLValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: v = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: v = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, i))
                    v = len == 0 ? .blob(Data()) : .blob(Data(bytes: sqlite3_column_blob(stmt, i), count: len))
                default: v = .null
                }
                row[names[Int(i)]] = v
            }
            out.append(row)
        }
        return out
    }
}
