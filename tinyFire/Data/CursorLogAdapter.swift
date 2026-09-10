//
//  CursorLogAdapter.swift
//  tinyFire
//
//  Cursor usage, seamless:
//    1) Official Dashboard API when a local access token is available
//    2) Local state.vscdb bubble estimate as fallback
//

import Foundation
import SQLite3

enum CursorIngestMode: String {
    case dashboard
    case localEstimate
}

struct CursorPollResult {
    var events: [UsageEvent]
    var newWatermark: Int64
    var mode: CursorIngestMode
    var detail: String
}

enum CursorLogAdapter {
    static var stateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                isDirectory: false
            )
    }

    private static let dashboardMinInterval: TimeInterval = 45
    private static var lastDashboardAttempt: Date?
    private static var lastDashboardSuccessAt: Date?

    static func connectionState() -> (SourceConnectionState, String) {
        let hasDB = FileManager.default.fileExists(atPath: stateDB.path)
        let hasToken = CursorDashboardClient.hasAccessToken()
        guard hasDB || hasToken else {
            return (.notFound, "Missing Cursor state.vscdb")
        }
        if hasToken {
            return (.ok, "Dashboard API ready")
        }
        // Probe DB open
        var db: OpaquePointer?
        let uri = "file:\(stateDB.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(uri, &db, flags, nil) != SQLITE_OK {
            let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open failed"
            if let db { sqlite3_close(db) }
            return (.noPermission, msg)
        }
        sqlite3_close(db)
        return (.ok, "Local estimate (no Cursor token)")
    }

    /// Official first; local estimate only when dashboard is unavailable.
    static func poll(
        watermarkMS: Int64,
        startOfDayMS: Int64,
        knownDashboardIDs: Set<String>,
        knownLocalIDs: Set<String>,
        maxNewEvents: Int = 250,
        forceDashboard: Bool = false
    ) -> CursorPollResult {
        let now = Date()
        let canAttemptDashboard =
            forceDashboard
            || lastDashboardAttempt == nil
            || now.timeIntervalSince(lastDashboardAttempt!) >= dashboardMinInterval
            || lastDashboardSuccessAt == nil

        if canAttemptDashboard, CursorDashboardClient.hasAccessToken() {
            lastDashboardAttempt = now
            do {
                let dash = try CursorDashboardClient.fetchTodayEvents(
                    startOfDayMS: startOfDayMS,
                    knownIDs: knownDashboardIDs
                )
                lastDashboardSuccessAt = now
                let events = dash.map { row -> UsageEvent in
                    UsageEvent(
                        id: row.id,
                        source: .cursor,
                        timestamp: row.timestamp,
                        tokens: row.total,
                        breakdown: UsageBreakdown(
                            input: row.input > 0 ? row.input : nil,
                            output: row.output > 0 ? row.output : nil,
                            cacheRead: row.cacheRead > 0 ? row.cacheRead : nil,
                            cacheWrite: row.cacheWrite > 0 ? row.cacheWrite : nil
                        ),
                        filePath: "cursor://dashboard",
                        isEstimated: false
                    )
                }
                return CursorPollResult(
                    events: events,
                    newWatermark: watermarkMS,
                    mode: .dashboard,
                    detail: "Dashboard API"
                )
            } catch CursorDashboardClient.FetchError.unauthorized {
                lastDashboardSuccessAt = nil
                // Fall through to local.
            } catch {
                lastDashboardSuccessAt = nil
                // Fall through to local.
            }
        } else if lastDashboardSuccessAt != nil {
            // Recently succeeded — stay on official path; skip noisy local estimates.
            return CursorPollResult(
                events: [],
                newWatermark: watermarkMS,
                mode: .dashboard,
                detail: "Dashboard API"
            )
        }

        let local = pollLocal(
            watermarkMS: watermarkMS,
            startOfDayMS: startOfDayMS,
            knownIDs: knownLocalIDs,
            maxNewEvents: maxNewEvents
        )
        return CursorPollResult(
            events: local.events,
            newWatermark: local.newWatermark,
            mode: .localEstimate,
            detail: "Local estimate"
        )
    }

    private static func pollLocal(
        watermarkMS: Int64,
        startOfDayMS: Int64,
        knownIDs: Set<String>,
        maxNewEvents: Int
    ) -> (events: [UsageEvent], newWatermark: Int64) {
        let url = stateDB
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            return ([], watermarkMS)
        }
        defer { sqlite3_close(db) }

        // Always include today's composers. Watermark must not hide unfinished work.
        var composers: [(id: String, updated: Int64)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT composerId, lastUpdatedAt FROM composerHeaders WHERE lastUpdatedAt >= ? ORDER BY lastUpdatedAt ASC;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else {
            return ([], watermarkMS)
        }
        sqlite3_bind_int64(stmt, 1, startOfDayMS)

        var maxUpdated = watermarkMS
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let updated = sqlite3_column_int64(stmt, 1)
            if id == "empty-state-draft" { continue }
            composers.append((id, updated))
            maxUpdated = max(maxUpdated, updated)
        }
        sqlite3_finalize(stmt)

        let earliest = Date(timeIntervalSince1970: TimeInterval(startOfDayMS) / 1000.0)
        var events: [UsageEvent] = []
        events.reserveCapacity(min(maxNewEvents, 128))
        var exhaustedAll = true

        for composer in composers {
            if events.count >= maxNewEvents {
                exhaustedAll = false
                break
            }
            let before = events.count
            let batch = bubbles(
                for: composer.id,
                updatedMS: composer.updated,
                earliest: earliest,
                db: db,
                knownIDs: knownIDs,
                remaining: maxNewEvents - events.count
            )
            events.append(contentsOf: batch)
            if batch.count >= maxNewEvents - before {
                exhaustedAll = false
            }
        }

        let newWatermark = exhaustedAll ? max(maxUpdated, watermarkMS) : watermarkMS
        return (events, newWatermark)
    }

    private static func bubbles(
        for composerId: String,
        updatedMS: Int64,
        earliest: Date,
        db: OpaquePointer,
        knownIDs: Set<String>,
        remaining: Int
    ) -> [UsageEvent] {
        guard remaining > 0 else { return [] }
        var keyStmt: OpaquePointer?
        let pattern = "bubbleId:\(composerId):%"
        guard sqlite3_prepare_v2(
            db,
            "SELECT key FROM cursorDiskKV WHERE key LIKE ?;",
            -1,
            &keyStmt,
            nil
        ) == SQLITE_OK else { return [] }
        sqlite3_bind_text(keyStmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var pendingKeys: [String] = []
        while sqlite3_step(keyStmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(keyStmt, 0))
            let bubbleId = key.split(separator: ":").last.map(String.init) ?? key
            let eventID = "cursor:bubble:v2:\(bubbleId)"
            if !knownIDs.contains(eventID) {
                pendingKeys.append(key)
                if pendingKeys.count >= remaining { break }
            }
        }
        sqlite3_finalize(keyStmt)

        guard !pendingKeys.isEmpty else { return [] }

        var events: [UsageEvent] = []
        let stamp = Date(timeIntervalSince1970: TimeInterval(updatedMS) / 1000.0)
        var valueStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1;",
            -1,
            &valueStmt,
            nil
        ) == SQLITE_OK else { return [] }

        for key in pendingKeys {
            sqlite3_reset(valueStmt)
            sqlite3_clear_bindings(valueStmt)
            sqlite3_bind_text(valueStmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(valueStmt) == SQLITE_ROW else { continue }
            let value = String(cString: sqlite3_column_text(valueStmt, 0))
            if let event = parseBubble(key: key, json: value, fallbackDate: stamp),
               event.timestamp >= earliest {
                events.append(event)
                if events.count >= remaining { break }
            }
        }
        sqlite3_finalize(valueStmt)
        return events
    }

    static func parseBubble(key: String, json: String, fallbackDate: Date) -> UsageEvent? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? Int ?? -1
        guard type == 2 else { return nil }

        let bubbleId = (obj["bubbleId"] as? String)
            ?? key.split(separator: ":").last.map(String.init)
            ?? key
        let id = "cursor:bubble:v2:\(bubbleId)"

        let createdAt = parseDate(obj["createdAt"]) ?? fallbackDate

        let tokenCount = obj["tokenCount"] as? [String: Any]
        let input = intValue(tokenCount?["inputTokens"])
        let output = intValue(tokenCount?["outputTokens"])
        var total = (input ?? 0) + (output ?? 0)
        var estimated = false
        var outVal = output
        var inVal = input

        if total == 0 {
            let estimate = estimateTokens(from: obj)
            guard estimate >= 24 else { return nil }
            outVal = estimate
            inVal = nil
            total = estimate
            estimated = true
        }

        return UsageEvent(
            id: id,
            source: .cursor,
            timestamp: createdAt,
            tokens: total,
            breakdown: UsageBreakdown(
                input: inVal,
                output: outVal,
                cacheRead: nil,
                cacheWrite: nil
            ),
            filePath: stateDB.path,
            isEstimated: estimated
        )
    }

    /// Agent bubbles often have empty `text` but carry thinking / tools / attachments.
    private static func estimateTokens(from obj: [String: Any]) -> Int {
        let text = obj["text"] as? String ?? ""

        var thinkChars = 0
        if let s = obj["thinking"] as? String {
            thinkChars += s.count
        } else if let d = obj["thinking"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: d) {
            thinkChars += data.count
        }
        if let blocks = obj["allThinkingBlocks"],
           JSONSerialization.isValidJSONObject(blocks),
           let data = try? JSONSerialization.data(withJSONObject: blocks) {
            thinkChars += data.count
        }

        // Tool / attachment JSON is verbose but still real billed context.
        var toolChars = 0
        for field in [
            "toolFormerData", "toolResults", "codeBlocks",
            "attachedCodeChunks", "attachedFileCodeChunksMetadataOnly",
            "capabilityStatuses", "aiWebSearchResults"
        ] {
            guard let value = obj[field] else { continue }
            if let s = value as? String {
                toolChars += s.count
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value) {
                toolChars += data.count
            }
        }

        let prose = (text.count + thinkChars + 3) / 4
        // ~8 chars/token for dense JSON (was /12 — too stingy).
        let tools = toolChars / 8
        var total = prose + tools

        let agentic = (obj["isAgentic"] as? Bool) == true || obj["toolFormerData"] != nil
        if agentic, total > 0 {
            // Agent steps re-send context far beyond the visible bubble body.
            total = max(total, 400)
            total = Int(Double(total) * 2.2)
        } else if thinkChars > 200 {
            total = Int(Double(total) * 1.35)
        }

        // Cap one bubble so a giant tool dump can't mint a blaze alone.
        return min(24_000, total)
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
