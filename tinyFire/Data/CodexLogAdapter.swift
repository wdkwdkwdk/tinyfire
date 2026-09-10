//
//  CodexLogAdapter.swift
//  tinyFire
//
//  Reads ~/.codex/sessions/**/*.jsonl token_usage_record lines.
//  Uses per-response `usage` (not cumulative thread totals).
//

import Foundation

enum CodexLogAdapter {
    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let root = sessionsRoot
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (.notFound, "未找到 ~/.codex/sessions")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return (.ok, root.path)
        } catch {
            return (.noPermission, error.localizedDescription)
        }
    }

    static func discoverLogFiles(modifiedSince: Date) -> [URL] {
        let root = sessionsRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < modifiedSince {
                continue
            }
            files.append(url)
        }
        return files
    }

    /// Parse one complete JSONL line into an event, if it is a usage record.
    static func parseLine(_ line: String, file: URL) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "token_usage_record"
        else { return nil }

        let payload = obj["payload"] as? [String: Any] ?? [:]
        let usage = payload["usage"] as? [String: Any] ?? [:]

        let input = intValue(usage["input_tokens"])
        let output = intValue(usage["output_tokens"])
        // reasoning_output_tokens is a subset of output — do not add again.
        let cacheRead = intValue(usage["cached_input_tokens"])
        let cacheWrite = intValue(usage["cache_write_input_tokens"])

        // OpenAI-style: input_tokens already includes cached tokens.
        // total_tokens ≈ input + output. Prefer total when present.
        let total: Int
        if let listed = intValue(usage["total_tokens"]), listed > 0 {
            total = listed
        } else {
            total = (input ?? 0) + (output ?? 0)
        }
        guard total > 0 else { return nil }

        let responseId = payload["response_id"] as? String
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let ordinal = obj["ordinal"] as? Int
        let id: String
        if let responseId, !responseId.isEmpty {
            id = "codex:\(responseId)"
        } else if let ordinal {
            id = "codex:\(sessionId):\(ordinal)"
        } else {
            id = "codex:\(file.lastPathComponent):\(trimmed.hashValue)"
        }

        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()

        // Stats breakdown: report cache separately; input shown as non-cache when possible.
        let nonCacheInput: Int? = {
            guard let input else { return nil }
            if let cacheRead { return max(0, input - cacheRead) }
            return input
        }()

        return UsageEvent(
            id: id,
            source: .codex,
            timestamp: timestamp,
            tokens: total,
            breakdown: UsageBreakdown(
                input: nonCacheInput ?? input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            ),
            filePath: file.path
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard var raw else { return nil }
        if raw.hasSuffix("Z") {
            raw = String(raw.dropLast()) + "+0000"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw.replacingOccurrences(of: "+00:00", with: "+0000")) {
            return d
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw.replacingOccurrences(of: "+00:00", with: "+0000"))
    }
}
