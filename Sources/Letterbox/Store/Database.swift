import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
    case null
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .text(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    static func of(_ v: Int) -> SQLValue { .int(Int64(v)) }
    static func of(_ v: UInt32) -> SQLValue { .int(Int64(v)) }
    static func of(_ v: Bool) -> SQLValue { .int(v ? 1 : 0) }
    static func of(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
}

struct SQLRow {
    fileprivate let stmt: OpaquePointer
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func blob(_ i: Int32) -> [UInt8] {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return [] }
        return Array(UnsafeRawBufferPointer(start: p, count: n))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite handle with a statement cache, guarded by a recursive lock.
final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    let lock = NSRecursiveLock()

    init(path: String, readOnly: Bool) {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        sqlite3_open_v2(path, &db, flags, nil)
        sqlite3_busy_timeout(db, 3000)
    }

    deinit {
        cache.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
    }

    func exec(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        if let s = cache[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let msg = sqlite3_errmsg(db) { NSLog("SQLite error: %@ in %@", String(cString: msg), sql) }
            return nil
        }
        cache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLValue]) {
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let b): b.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(b.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func run(_ sql: String, _ args: [SQLValue] = []) {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql) else { return }
        bind(stmt, args)
        while sqlite3_step(stmt) == SQLITE_ROW {}
        sqlite3_reset(stmt)
    }

    func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLRow) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare(sql) else { return [] }
        bind(stmt, args)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(SQLRow(stmt: stmt))) }
        sqlite3_reset(stmt)
        return out
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
}

/// The local mail cache. WAL mode with separate reader/writer handles so the UI
/// can read while sync writes in the background.
final class Database: @unchecked Sendable {
    let writer: SQLiteConnection
    let reader: SQLiteConnection
    let url: URL

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Letterbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mail.sqlite")
    }

    init(url: URL = Database.defaultURL()) {
        self.url = url
        writer = SQLiteConnection(path: url.path, readOnly: false)
        writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        writer.exec("""
        CREATE TABLE IF NOT EXISTS folders(
            path TEXT PRIMARY KEY, name TEXT, delimiter TEXT, role TEXT,
            uidvalidity INTEGER DEFAULT 0, uidnext INTEGER DEFAULT 0,
            total INTEGER DEFAULT 0, unread INTEGER DEFAULT 0, selectable INTEGER DEFAULT 1);
        CREATE TABLE IF NOT EXISTS messages(
            folder TEXT, uid INTEGER, message_id TEXT, subject TEXT,
            from_name TEXT, from_addr TEXT, to_list TEXT, cc_list TEXT, reply_to TEXT,
            recipients TEXT, delivered_to TEXT, date REAL,
            seen INTEGER, flagged INTEGER, answered INTEGER, size INTEGER, has_att INTEGER,
            snippet TEXT DEFAULT '', in_reply_to TEXT, refs TEXT,
            PRIMARY KEY(folder, uid));
        CREATE INDEX IF NOT EXISTS idx_messages_folder_date ON messages(folder, date DESC);
        CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date DESC);
        CREATE TABLE IF NOT EXISTS bodies(folder TEXT, uid INTEGER, raw BLOB, fetched REAL, PRIMARY KEY(folder, uid));
        CREATE TABLE IF NOT EXISTS insights(
            folder TEXT, uid INTEGER, priority INTEGER, category TEXT, summary TEXT, reason TEXT,
            action TEXT, due TEXT, needs_reply INTEGER, done INTEGER DEFAULT 0, analyzed REAL,
            PRIMARY KEY(folder, uid));
        CREATE TABLE IF NOT EXISTS thread_insights(
            thread TEXT PRIMARY KEY, latest TEXT, priority INTEGER, category TEXT, summary TEXT, reason TEXT,
            action TEXT, due TEXT, due_date TEXT, status TEXT, needs_reply INTEGER, timeline TEXT,
            done INTEGER DEFAULT 0, analyzed REAL);
        CREATE TABLE IF NOT EXISTS aliases(email TEXT PRIMARY KEY, name TEXT, source TEXT, hidden INTEGER DEFAULT 0, score INTEGER DEFAULT 0);
        """)
        reader = SQLiteConnection(path: url.path, readOnly: true)
    }

    func wipe() {
        writer.exec("DELETE FROM messages; DELETE FROM bodies; DELETE FROM folders; DELETE FROM aliases; DELETE FROM insights; DELETE FROM thread_insights; VACUUM;")
    }
}
