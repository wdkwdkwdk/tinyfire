//
//  CursorDashboardClient.swift
//  tinyFire
//
//  Official Cursor usage via Dashboard API (same path as ccclub).
//  Token sources (first hit wins), never uploaded:
//    1) CURSOR_ACCESS_TOKEN env
//    2) state.vscdb ItemTable cursorAuth/accessToken  (desktop Cursor)
//    3) Keychain cursor-access-token / cursor-user     (cursor-agent CLI)
//

import Foundation
import Security
import SQLite3

enum CursorDashboardClient {
    private static let apiURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")!
    private static let pageSize = 100
    private static let maxPages = 20

    struct DashEvent {
        var id: String
        var timestamp: Date
        var input: Int
        var output: Int
        var cacheWrite: Int
        var cacheRead: Int
        var total: Int
    }

    enum FetchError: Error {
        case noToken
        case http(Int)
        case unauthorized
        case decode
    }

    static func hasAccessToken() -> Bool {
        readAccessToken() != nil
    }

    /// Prefer desktop DB token — most users never have the CLI Keychain item.
    static func readAccessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CURSOR_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let db = readStateDBAccessToken(), !db.isEmpty { return db }
        if let kc = readKeychainAccessToken(), !kc.isEmpty { return kc }
        return nil
    }

    static func fetchTodayEvents(
        startOfDayMS: Int64,
        knownIDs: Set<String>,
        nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> [DashEvent] {
        guard let token = readAccessToken() else { throw FetchError.noToken }

        var collected: [DashEvent] = []
        var totalCount: Int?
        var fetchedRaw = 0

        for page in 1...maxPages {
            let payload = try fetchPage(token: token, page: page, startMS: startOfDayMS, endMS: nowMS)
            let rows = payload.rows
            if page == 1 { totalCount = payload.totalCount }
            fetchedRaw += rows.count

            for row in rows {
                guard let event = parseRow(row) else { continue }
                if knownIDs.contains(event.id) { continue }
                if event.timestamp.timeIntervalSince1970 * 1000 < Double(startOfDayMS) { continue }
                collected.append(event)
            }

            if rows.isEmpty { break }
            if let totalCount, fetchedRaw >= totalCount { break }
            if totalCount == nil, rows.count < pageSize { break }
        }
        return collected
    }

    // MARK: - Token sources

    private static func readStateDBAccessToken() -> String? {
        let url = CursorLogAdapter.stateDB
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0)
        else { return nil }
        let value = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func readKeychainAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-access-token",
            kSecAttrAccount as String: "cursor-user",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - HTTP

    private struct PagePayload {
        var rows: [[String: Any]]
        var totalCount: Int?
    }

    private static func fetchPage(
        token: String,
        page: Int,
        startMS: Int64,
        endMS: Int64
    ) throws -> PagePayload {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("cursor-agent/2026.08.11", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "startDate": String(startMS),
            "endDate": String(endMS),
            "page": page,
            "pageSize": pageSize
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var dataOut: Data?
        var responseOut: URLResponse?
        var errorOut: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            dataOut = data
            responseOut = response
            errorOut = error
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 18)

        if let errorOut { throw errorOut }
        guard let http = responseOut as? HTTPURLResponse else { throw FetchError.decode }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard let dataOut,
              let obj = try JSONSerialization.jsonObject(with: dataOut) as? [String: Any]
        else { throw FetchError.decode }

        let rows = obj["usageEventsDisplay"] as? [[String: Any]] ?? []
        let total = intValue(obj["totalUsageEventsCount"])
        return PagePayload(rows: rows, totalCount: total)
    }

    private static func parseRow(_ row: [String: Any]) -> DashEvent? {
        let usage = row["tokenUsage"] as? [String: Any] ?? [:]
        let input = intValue(usage["inputTokens"]) ?? 0
        let output = intValue(usage["outputTokens"]) ?? 0
        let cacheWrite = intValue(usage["cacheWriteTokens"]) ?? 0
        let cacheRead = intValue(usage["cacheReadTokens"]) ?? 0
        let total = input + output + cacheWrite + cacheRead
        guard total > 0 else { return nil }

        let ts = parseTimestamp(row["timestamp"]) ?? Date()
        let conversation = (row["conversationId"] as? String) ?? "unknown"
        let model = (row["model"] as? String) ?? "cursor"
        // Stable id matching ccclub’s request key shape.
        let id = [
            "cursor:dash",
            conversation,
            String(Int64(ts.timeIntervalSince1970 * 1000)),
            model,
            "\(input)",
            "\(output)",
            "\(cacheWrite)",
            "\(cacheRead)"
        ].joined(separator: ":")

        return DashEvent(
            id: id,
            timestamp: ts,
            input: input,
            output: output,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead,
            total: total
        )
    }

    private static func parseTimestamp(_ any: Any?) -> Date? {
        if let n = any as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let i = any as? Int {
            let v = Double(i)
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let s = any as? String {
            if let v = Double(s), v > 0 {
                return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let v = Double(s) { return Int(v) }
        return nil
    }
}
