//
//  GrokLogAdapter.swift
//  tinyFire
//
//  Grok Build CLI: ~/.grok/sessions/**/updates.jsonl (turn_completed)
//  Legacy fallback: ~/.grok/logs/unified.jsonl (shell.turn.inference_done)
//

import Foundation

enum GrokLogAdapter {
    static var homeRoot: URL {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static var sessionsRoot: URL {
        homeRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    static var unifiedLog: URL {
        homeRoot.appendingPathComponent("logs/unified.jsonl", isDirectory: false)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let root = homeRoot
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (.notFound, "Missing ~/.grok")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return (.ok, root.path)
        } catch {
            return (.noPermission, error.localizedDescription)
        }
    }

    static func discoverLogFiles(modifiedSince: Date) -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "updates.jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values?.contentModificationDate, modified < modifiedSince { continue }
                files.append(url)
            }
        }
        if FileManager.default.fileExists(atPath: unifiedLog.path) {
            let values = try? unifiedLog.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified >= modifiedSince {
                files.append(unifiedLog)
            } else if values?.contentModificationDate == nil {
                files.append(unifiedLog)
            }
        }
        return files
    }

    static func parseLine(_ line: String, file: URL) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if (obj["sessionUpdate"] as? String) == "turn_completed" {
            return parseTurnCompleted(obj, file: file, line: trimmed)
        }
        if (obj["msg"] as? String) == "shell.turn.inference_done" {
            return parseUnifiedInference(obj, file: file, line: trimmed)
        }
        return nil
    }

    private static func parseTurnCompleted(_ obj: [String: Any], file: URL, line: String) -> UsageEvent? {
        let usage = obj["usage"] as? [String: Any] ?? obj
        let inputTotal = intValue(usage["inputTokens"]) ?? 0
        let output = intValue(usage["outputTokens"]) ?? 0
        let cacheRead = intValue(usage["cachedReadTokens"]) ?? 0
        let cacheWrite = intValue(usage["cacheCreationTokens"]) ?? 0
        // OpenAI-style: inputTokens includes cache; bill total ≈ input + output.
        let total: Int
        if let listed = intValue(usage["totalTokens"]), listed > 0 {
            total = listed
        } else {
            total = inputTotal + output
        }
        guard total > 0 else { return nil }

        let nonCacheInput = max(0, inputTotal - cacheRead)
        let turnId = obj["turnId"] as? String
            ?? obj["promptId"] as? String
            ?? "\(file.lastPathComponent):\(line.hashValue)"
        let ts = parseTimestamp(obj["timestamp"] as? String)
            ?? parseTimestamp(obj["ts"] as? String)
            ?? Date()

        return UsageEvent(
            id: "grok:turn:\(turnId)",
            source: .grok,
            timestamp: ts,
            tokens: total,
            breakdown: UsageBreakdown(
                input: nonCacheInput,
                output: output,
                cacheRead: cacheRead > 0 ? cacheRead : nil,
                cacheWrite: cacheWrite > 0 ? cacheWrite : nil
            ),
            filePath: file.path
        )
    }

    private static func parseUnifiedInference(_ obj: [String: Any], file: URL, line: String) -> UsageEvent? {
        let ctx = obj["ctx"] as? [String: Any] ?? [:]
        let promptTotal = max(0, intValue(ctx["prompt_tokens"]) ?? 0)
        let cached = min(promptTotal, max(0, intValue(ctx["cached_prompt_tokens"]) ?? 0))
        let output = max(0, intValue(ctx["completion_tokens"]) ?? 0)
        // reasoning is subset of output in newer formats; older logs may separate it — don't double-count.
        let total = promptTotal + output
        guard total > 0 else { return nil }

        let sid = obj["sid"] as? String ?? "unknown"
        let ts = parseTimestamp(obj["ts"] as? String) ?? Date()
        let id = "grok:unified:\(sid):\(ts.timeIntervalSince1970):\(total)"

        return UsageEvent(
            id: id,
            source: .grok,
            timestamp: ts,
            tokens: total,
            breakdown: UsageBreakdown(
                input: max(0, promptTotal - cached),
                output: output,
                cacheRead: cached > 0 ? cached : nil,
                cacheWrite: nil
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
        if raw.hasSuffix("Z") { raw = String(raw.dropLast()) + "+0000" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw.replacingOccurrences(of: "+00:00", with: "+0000")) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw.replacingOccurrences(of: "+00:00", with: "+0000"))
    }
}
