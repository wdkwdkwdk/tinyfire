//
//  AmpLogAdapter.swift
//  tinyFire
//
//  Sourcegraph Amp: ~/.local/share/amp/threads/**/*.json (usageLedger.events)
//

import Foundation

enum AmpLogAdapter {
    static var dataRoots: [URL] {
        if let env = ProcessInfo.processInfo.environment["AMP_DATA_DIR"], !env.isEmpty {
            return env.split(separator: ",").compactMap { part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/share/amp", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/amp", isDirectory: true)
        ]
    }

    static func connectionState() -> (SourceConnectionState, String) {
        for root in dataRoots {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    return (.ok, root.path)
                } catch {
                    return (.noPermission, error.localizedDescription)
                }
            }
        }
        return (.notFound, "Missing ~/.local/share/amp")
    }

    static func discoverThreadFiles(modifiedSince: Date) -> [URL] {
        var files: [URL] = []
        for root in dataRoots {
            let threads = root.appendingPathComponent("threads", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: threads,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "json" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values?.contentModificationDate, modified < modifiedSince { continue }
                files.append(url)
            }
        }
        return files
    }

    static func parseThread(file: URL) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let threadId = obj["id"] as? String ?? file.deletingPathExtension().lastPathComponent
        let ledger = obj["usageLedger"] as? [String: Any]
        let events = ledger?["events"] as? [[String: Any]] ?? []
        let messages = obj["messages"] as? [[String: Any]] ?? []

        var out: [UsageEvent] = []
        for event in events {
            let model = event["model"] as? String
            let tokens = event["tokens"] as? [String: Any]
            guard model != nil, let tokens else { continue }
            let input = intValue(tokens["input"]) ?? 0
            let output = intValue(tokens["output"]) ?? 0
            let toMessageId = intValue(event["toMessageId"])
            let cache = cacheTokens(messages: messages, toMessageId: toMessageId)
            let total = input + output + cache.write + cache.read
            guard total > 0 else { continue }

            let ts = parseTimestamp(event["timestamp"] as? String) ?? Date()
            let id = [
                "amp",
                threadId,
                String(ts.timeIntervalSince1970),
                model ?? "?",
                "\(input)",
                "\(output)",
                "\(cache.write)",
                "\(cache.read)",
                "\(toMessageId ?? -1)"
            ].joined(separator: ":")

            out.append(
                UsageEvent(
                    id: id,
                    source: .amp,
                    timestamp: ts,
                    tokens: total,
                    breakdown: UsageBreakdown(
                        input: input > 0 ? input : nil,
                        output: output > 0 ? output : nil,
                        cacheRead: cache.read > 0 ? cache.read : nil,
                        cacheWrite: cache.write > 0 ? cache.write : nil
                    ),
                    filePath: file.path
                )
            )
        }
        return out
    }

    private static func cacheTokens(messages: [[String: Any]], toMessageId: Int?) -> (write: Int, read: Int) {
        guard let toMessageId else { return (0, 0) }
        for message in messages {
            guard (message["role"] as? String) == "assistant",
                  intValue(message["messageId"]) == toMessageId,
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            return (
                intValue(usage["cacheCreationInputTokens"]) ?? 0,
                intValue(usage["cacheReadInputTokens"]) ?? 0
            )
        }
        return (0, 0)
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
