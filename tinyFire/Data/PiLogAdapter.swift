//
//  PiLogAdapter.swift
//  tinyFire
//
//  pi-agent: ~/.pi/agent/sessions/**/*.jsonl (assistant message.usage)
//

import Foundation

enum PiLogAdapter {
    static var sessionsRoot: URL {
        if let env = ProcessInfo.processInfo.environment["PI_AGENT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let root = sessionsRoot
        var isDir: ObjCBool = false
        // Parent ~/.pi/agent is enough to show "installed but unused"
        let parent = root.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
                return (.ok, root.path)
            } catch {
                return (.noPermission, error.localizedDescription)
            }
        }
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue {
            return (.ok, parent.path)
        }
        return (.notFound, "Missing ~/.pi/agent/sessions")
    }

    static func discoverLogFiles(modifiedSince: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < modifiedSince { continue }
            files.append(url)
        }
        return files
    }

    static func parseLine(_ line: String, file: URL) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "assistant",
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = intValue(usage["input"]) ?? 0
        let output = intValue(usage["output"]) ?? 0
        let cacheRead = intValue(usage["cacheRead"]) ?? 0
        let cacheWrite = intValue(usage["cacheWrite"])
            ?? intValue(usage["cacheWrite1h"])
            ?? 0
        let total: Int
        if let listed = intValue(usage["totalTokens"]), listed > 0 {
            total = listed
        } else {
            total = input + output + cacheRead + cacheWrite
        }
        guard total > 0 else { return nil }

        let ts = parseTimestamp(obj["timestamp"] as? String)
            ?? parseEpochMS(message["timestamp"])
            ?? Date()
        let messageId = (message["id"] as? String)
            ?? (obj["id"] as? String)
            ?? "\(file.lastPathComponent):\(trimmed.hashValue)"

        return UsageEvent(
            id: "pi:\(messageId)",
            source: .pi,
            timestamp: ts,
            tokens: total,
            breakdown: UsageBreakdown(
                input: input > 0 ? input : nil,
                output: output > 0 ? output : nil,
                cacheRead: cacheRead > 0 ? cacheRead : nil,
                cacheWrite: cacheWrite > 0 ? cacheWrite : nil
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

    private static func parseEpochMS(_ any: Any?) -> Date? {
        if let n = any as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let i = any as? Int {
            let v = Double(i)
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
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
