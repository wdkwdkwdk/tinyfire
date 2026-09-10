//
//  ClaudeCodeLogAdapter.swift
//  tinyFire
//
//  Reads ~/.claude/projects/**/*.jsonl assistant usage.
//  Dedup key is message.id — keep the richest snapshot per id.
//

import Foundation

enum ClaudeCodeLogAdapter {
    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let root = projectsRoot
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (.notFound, "未找到 ~/.claude/projects")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return (.ok, root.path)
        } catch {
            return (.noPermission, error.localizedDescription)
        }
    }

    static func discoverLogFiles(modifiedSince: Date) -> [URL] {
        let root = projectsRoot
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

    static func parseLine(_ line: String, file: URL) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = intValue(usage["input_tokens"])
        let output = intValue(usage["output_tokens"])
        let cacheWrite = intValue(usage["cache_creation_input_tokens"])
        let cacheRead = intValue(usage["cache_read_input_tokens"])

        // Anthropic: input / cache_read / cache_creation are separate buckets.
        let total = (input ?? 0) + (output ?? 0) + (cacheWrite ?? 0) + (cacheRead ?? 0)
        guard total > 0 else { return nil }

        let messageId = (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = obj["uuid"] as? String
        let id: String
        if let messageId, !messageId.isEmpty {
            id = "claude:\(messageId)"
        } else if let uuid, !uuid.isEmpty {
            id = "claude-uuid:\(uuid)"
        } else {
            id = "claude:\(file.lastPathComponent):\(trimmed.hashValue)"
        }

        let timestamp = parseTimestamp(obj["timestamp"] as? String) ?? Date()

        return UsageEvent(
            id: id,
            source: .claudeCode,
            timestamp: timestamp,
            tokens: total,
            breakdown: UsageBreakdown(
                input: input,
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
