//
//  UsageStore.swift
//  tinyFire
//
//  Local SQLite: usage events, file cursors, cursor watermarks.
//  Never stores prompts, code, or account credentials.
//

import Foundation
import SQLite3

final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    private var db: OpaquePointer?
    private let lock = NSLock()
    /// Avoid SELECT-per-key during Cursor scans (was tens of thousands of queries).
    private var knownEventIDs = Set<String>()

    private init() {
        open()
        migrate()
        warmIDCache()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private var dbURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tinyFire", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage.sqlite")
    }

    private func open() {
        let path = dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY NOT NULL,
            source TEXT NOT NULL,
            timestamp REAL NOT NULL,
            tokens INTEGER NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read INTEGER,
            cache_write INTEGER,
            file_path TEXT,
            is_estimated INTEGER NOT NULL DEFAULT 0,
            inserted_at REAL NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(timestamp);")
        exec("CREATE INDEX IF NOT EXISTS idx_events_source_ts ON usage_events(source, timestamp);")

        exec("""
        CREATE TABLE IF NOT EXISTS file_cursors (
            path TEXT PRIMARY KEY NOT NULL,
            byte_offset INTEGER NOT NULL,
            partial_line TEXT,
            updated_at REAL NOT NULL
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Events

    @discardableResult
    func insertEvent(_ event: UsageEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        INSERT OR IGNORE INTO usage_events
        (id, source, timestamp, tokens, input_tokens, output_tokens, cache_read, cache_write, file_path, is_estimated, inserted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, event.id)
        bindText(stmt, 2, event.source.rawValue)
        sqlite3_bind_double(stmt, 3, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 4, Int64(event.tokens))
        bindOptionalInt(stmt, 5, event.breakdown.input)
        bindOptionalInt(stmt, 6, event.breakdown.output)
        bindOptionalInt(stmt, 7, event.breakdown.cacheRead)
        bindOptionalInt(stmt, 8, event.breakdown.cacheWrite)
        bindText(stmt, 9, event.filePath)
        sqlite3_bind_int(stmt, 10, event.isEstimated ? 1 : 0)
        sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)

        let ok = sqlite3_step(stmt) == SQLITE_DONE
        let changes = sqlite3_changes(db)
        if ok && changes > 0 {
            knownEventIDs.insert(event.id)
        }
        return ok && changes > 0
    }

    func hasEvent(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if knownEventIDs.contains(id) { return true }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM usage_events WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        bindText(stmt, 1, id)
        let found = sqlite3_step(stmt) == SQLITE_ROW
        if found { knownEventIDs.insert(id) }
        return found
    }

    /// Bulk membership for Cursor bubble scans — one query instead of N.
    func eventIDs(withPrefix prefix: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id FROM usage_events WHERE id LIKE ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return knownEventIDs }
        bindText(stmt, 1, prefix + "%")
        var ids = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            ids.insert(id)
            knownEventIDs.insert(id)
        }
        return ids
    }

    private func warmIDCache() {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM usage_events;", -1, &stmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            knownEventIDs.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
    }

    func todayTotals(now: Date = Date()) -> (total: Int, bySource: [UsageSource: Int]) {
        lock.lock(); defer { lock.unlock() }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT source, SUM(tokens) FROM usage_events
        WHERE timestamp >= ?
        GROUP BY source;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (0, [:])
        }
        sqlite3_bind_double(stmt, 1, start)

        var bySource: [UsageSource: Int] = [:]
        var total = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 0))
            let sum = Int(sqlite3_column_int64(stmt, 1))
            if let source = UsageSource(rawValue: sourceRaw) {
                bySource[source] = sum
                total += sum
            }
        }
        return (total, bySource)
    }

    /// 24 hourly buckets for today (local calendar), including empty hours.
    func todayHourlyTotals(now: Date = Date()) -> [HourlyUsage] {
        lock.lock(); defer { lock.unlock() }
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        var buckets = Array(repeating: 0, count: 24)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT timestamp, tokens FROM usage_events
        WHERE timestamp >= ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (0..<24).map { HourlyUsage(hour: $0, tokens: 0) }
        }
        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let hour = cal.component(.hour, from: date)
            let tokens = Int(sqlite3_column_int64(stmt, 1))
            if hour >= 0, hour < 24 {
                buckets[hour] += tokens
            }
        }
        return buckets.enumerated().map { HourlyUsage(hour: $0.offset, tokens: $0.element) }
    }

    func todayBreakdown(now: Date = Date()) -> UsageBreakdown {
        lock.lock(); defer { lock.unlock() }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT
          SUM(COALESCE(input_tokens, 0)),
          SUM(COALESCE(output_tokens, 0)),
          SUM(COALESCE(cache_read, 0)),
          SUM(COALESCE(cache_write, 0))
        FROM usage_events
        WHERE timestamp >= ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return UsageBreakdown()
        }
        sqlite3_bind_double(stmt, 1, start)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return UsageBreakdown() }
        return UsageBreakdown(
            input: Int(sqlite3_column_int64(stmt, 0)),
            output: Int(sqlite3_column_int64(stmt, 1)),
            cacheRead: Int(sqlite3_column_int64(stmt, 2)),
            cacheWrite: Int(sqlite3_column_int64(stmt, 3))
        )
    }

    func recentEvents(since: Date, limit: Int = 200) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT id, source, timestamp, tokens, input_tokens, output_tokens, cache_read, cache_write, file_path, is_estimated
        FROM usage_events
        WHERE timestamp >= ?
        ORDER BY timestamp ASC
        LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let source = UsageSource(rawValue: String(cString: sqlite3_column_text(stmt, 1))) else { continue }
            events.append(
                UsageEvent(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    source: source,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    tokens: Int(sqlite3_column_int64(stmt, 3)),
                    breakdown: UsageBreakdown(
                        input: optionalInt(stmt, 4),
                        output: optionalInt(stmt, 5),
                        cacheRead: optionalInt(stmt, 6),
                        cacheWrite: optionalInt(stmt, 7)
                    ),
                    filePath: sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "",
                    isEstimated: sqlite3_column_int(stmt, 9) == 1
                )
            )
        }
        return events
    }

    // MARK: - File cursors / meta

    func fileCursor(path: String) -> (offset: UInt64, partial: String?) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT byte_offset, partial_line FROM file_cursors WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return (0, nil)
        }
        bindText(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil) }
        let offset = UInt64(sqlite3_column_int64(stmt, 0))
        let partial = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        return (offset, partial)
    }

    func setFileCursor(path: String, offset: UInt64, partial: String?) {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        INSERT INTO file_cursors(path, byte_offset, partial_line, updated_at)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          byte_offset=excluded.byte_offset,
          partial_line=excluded.partial_line,
          updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, path)
        sqlite3_bind_int64(stmt, 2, Int64(offset))
        if let partial {
            bindText(stmt, 3, partial)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// True if any stored event originated from this log path.
    func hasEvents(forFilePath path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM usage_events WHERE file_path = ? LIMIT 1;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return false }
        bindText(stmt, 1, path)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func clearFileCursors() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM file_cursors;")
    }

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func setMeta(_ key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        sqlite3_step(stmt)
    }

    /// Drop legacy Cursor bubble rows so v2 re-estimates can replace them.
    func purgeCursorBubbleV1() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM usage_events WHERE id LIKE 'cursor:bubble:%' AND id NOT LIKE 'cursor:bubble:v2:%';")
        knownEventIDs = knownEventIDs.filter { !($0.hasPrefix("cursor:bubble:") && !$0.hasPrefix("cursor:bubble:v2:")) }
    }

    /// Once Dashboard API is authoritative, drop local bubble estimates to avoid double-count.
    func purgeCursorLocalEstimates() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM usage_events WHERE id LIKE 'cursor:bubble:%';")
        knownEventIDs = knownEventIDs.filter { !$0.hasPrefix("cursor:bubble:") }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func optionalInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, idx))
    }
}
