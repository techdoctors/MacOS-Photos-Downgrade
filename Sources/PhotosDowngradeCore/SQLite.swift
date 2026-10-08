import Foundation
import SQLite3

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var blob: Data? { if case .blob(let v) = self { return v }; return nil }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal SQLite wrapper. Source libraries are always opened immutable so we
/// never touch the user's original (no WAL checkpoint, no lock files).
public final class SQLiteDB {
    public enum Mode { case immutable, readOnly, readWrite }

    let handle: OpaquePointer

    public init(path: String, mode: Mode = .immutable) throws {
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = path
        switch mode {
        case .immutable: comps.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        case .readOnly: comps.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        case .readWrite: break
        }
        let flags = (mode == .readWrite ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_URI
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(comps.string, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(h)
            throw SQLiteError(code: rc, message: "\(msg) (\(path))")
        }
        handle = h
    }

    deinit { sqlite3_close(handle) }

    public func query(_ sql: String) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    row[name] = n == 0 ? .blob(Data()) : .blob(Data(bytes: sqlite3_column_blob(stmt, i), count: n))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    public func scalarInt(_ sql: String) throws -> Int64? {
        try query(sql).first?.values.first?.int
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}

// MARK: - Schema introspection

public struct ColumnInfo: Hashable {
    public let name: String
    public let type: String
    public let notNull: Bool
    public let hasDefault: Bool
    public let primaryKey: Bool
}

public struct TableInfo {
    public let name: String
    public let columns: [ColumnInfo]
    public var columnNames: Set<String> { Set(columns.map(\.name)) }
}

public struct SchemaSnapshot {
    static func columns(of table: String, in db: SQLiteDB) throws -> Set<String> {
        Set(try db.query("PRAGMA main.table_info(\"\(table)\")").compactMap { $0["name"]?.text })
    }

    public let tables: [String: TableInfo]
    /// Core Data entity name -> Z_ENT number, from Z_PRIMARYKEY.
    public let entities: [String: Int]
    /// Z_METADATA plist (store metadata: version hashes, PLModelVersion, ...).
    public let metadata: [String: Any]

    public init(db: SQLiteDB) throws {
        var tables: [String: TableInfo] = [:]
        let names = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0["name"]?.text }
        for name in names {
            let cols = try db.query("PRAGMA table_info(\"\(name)\")").map { r in
                ColumnInfo(name: r["name"]?.text ?? "",
                           type: r["type"]?.text ?? "",
                           notNull: (r["notnull"]?.int ?? 0) != 0,
                           hasDefault: r["dflt_value"].map { $0 != .null } ?? false,
                           primaryKey: (r["pk"]?.int ?? 0) != 0)
            }
            tables[name] = TableInfo(name: name, columns: cols)
        }
        self.tables = tables

        var entities: [String: Int] = [:]
        if tables["Z_PRIMARYKEY"] != nil {
            for r in try db.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") {
                if let n = r["Z_NAME"]?.text, let e = r["Z_ENT"]?.int { entities[n] = Int(e) }
            }
        }
        self.entities = entities

        var metadata: [String: Any] = [:]
        if tables["Z_METADATA"] != nil,
           let blob = try db.query("SELECT Z_PLIST FROM Z_METADATA LIMIT 1").first?["Z_PLIST"]?.blob,
           let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any] {
            metadata = plist
        }
        self.metadata = metadata
    }
}
