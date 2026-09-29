//
//  DeepSeekLogAdapter.swift
//  tinyFire
//
//  DeepSeek Harness (dsh): ~/.dsh/sessions/**/session*.jsonl[.zstd]
//  Usage from assistant/message.usage, with assistant/chunk usage as fallback
//  (same turn/step id → SQLite OR IGNORE dedupes when both exist).
//
//  Zstd logs are independent frames per append — we only decompress bytes past
//  the stored file cursor, not the whole history every poll.
//

import Foundation

enum DeepSeekLogAdapter {
    static var homeRoot: URL {
        if let env = ProcessInfo.processInfo.environment["DSH_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh", isDirectory: true)
    }

    static var sessionsRoot: URL {
        homeRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let root = homeRoot
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return (.notFound, "Missing ~/.dsh")
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return (.ok, sessionsRoot.path)
        } catch {
            return (.noPermission, error.localizedDescription)
        }
    }

    /// Highest generation per session directory (v0 = session.jsonl[.zstd], vN = session.vN…).
    static func discoverSessionFiles(modifiedSince: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var bestByDir: [String: (version: Int, url: URL)] = [:]
        for case let url as URL in enumerator {
            guard let generation = sessionGeneration(filename: url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < modifiedSince { continue }

            let dir = url.deletingLastPathComponent().path
            if let existing = bestByDir[dir] {
                if generation > existing.version
                    || (generation == existing.version && url.pathExtension == "zstd" && existing.url.pathExtension != "zstd") {
                    bestByDir[dir] = (generation, url)
                }
            } else {
                bestByDir[dir] = (generation, url)
            }
        }
        return bestByDir.values.map(\.url)
    }

    /// Incremental ingest: plain JSONL tails like other adapters; zstd only decodes new frames.
    static func ingest(file: URL, store: UsageStore, fromStart: Bool) -> [UsageEvent] {
        if file.lastPathComponent.hasSuffix(".zstd") {
            return ingestZstd(file: file, store: store, fromStart: fromStart)
        }
        return ingestJSONL(file: file, store: store, fromStart: fromStart)
    }

    // MARK: - Incremental readers

    private static func ingestZstd(file: URL, store: UsageStore, fromStart: Bool) -> [UsageEvent] {
        let path = file.path
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        var cursor = store.fileCursor(path: path)
        var offset = cursor.offset

        let truncated = offset > size
        let stuckAtEOF = !fromStart && size > 0 && offset >= size && !store.hasEvents(forFilePath: path)
        if fromStart || truncated || stuckAtEOF {
            offset = 0
            cursor = (0, nil)
        }
        guard offset < size else { return [] }

        do { try handle.seek(toOffset: offset) } catch { return [] }
        let compressed = handle.readData(ofLength: Int(size - offset))
        guard !compressed.isEmpty else { return [] }

        let (decoded, consumed) = ZstdDecompressor.decompressCompleteFrames(compressed)
        // Torn trailing frame: advance only past complete frames; retry rest next poll.
        let newOffset = offset + UInt64(consumed)

        var buffer = (cursor.partial ?? "") + (String(data: decoded, encoding: .utf8) ?? "")
        let sessionKey = file.deletingLastPathComponent().lastPathComponent
        var events: [UsageEvent] = []
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            if let event = parseLine(line, sessionKey: sessionKey, file: file) {
                events.append(event)
            }
        }
        store.setFileCursor(path: path, offset: newOffset, partial: buffer.isEmpty ? nil : buffer)
        return events
    }

    private static func ingestJSONL(file: URL, store: UsageStore, fromStart: Bool) -> [UsageEvent] {
        let path = file.path
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        var cursor = store.fileCursor(path: path)
        var offset = cursor.offset
        var partial = cursor.partial ?? ""

        let truncated = offset > size
        let stuckAtEOF = !fromStart && size > 0 && offset >= size && !store.hasEvents(forFilePath: path)
        if fromStart || truncated || stuckAtEOF {
            offset = 0
            partial = ""
        }
        do { try handle.seek(toOffset: offset) } catch { return [] }

        var buffer = partial
        let sessionKey = file.deletingLastPathComponent().lastPathComponent
        var events: [UsageEvent] = []
        while true {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { break }
            if let text = String(data: chunk, encoding: .utf8) {
                buffer += text
            } else if let text = String(data: chunk, encoding: .isoLatin1) {
                buffer += text
            } else {
                break
            }
            while let range = buffer.range(of: "\n") {
                let line = String(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                if let event = parseLine(line, sessionKey: sessionKey, file: file) {
                    events.append(event)
                }
            }
        }
        let newOffset = (try? handle.offset()) ?? offset
        store.setFileCursor(path: path, offset: newOffset, partial: buffer.isEmpty ? nil : buffer)
        return events
    }

    // MARK: - Line parse

    private static func parseLine(_ line: String, sessionKey: String, file: URL) -> UsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        // Prefer durable header id when present; fall back to directory key.
        // Event ids always use a stable key derived here for the line.
        if type == "assistant/message" {
            return parseAssistantMessage(obj, sessionKey: sessionKey, file: file)
        }
        if type == "assistant/chunk" {
            return parseAssistantChunkUsage(obj, sessionKey: sessionKey, file: file)
        }
        return nil
    }

    // MARK: - Private

    /// Returns generation number, or nil if not a session log name.
    private static func sessionGeneration(filename: String) -> Int? {
        let name: String
        if filename.hasSuffix(".jsonl.zstd") {
            name = String(filename.dropLast(".jsonl.zstd".count))
        } else if filename.hasSuffix(".jsonl") {
            name = String(filename.dropLast(".jsonl".count))
        } else {
            return nil
        }
        if name == "session" { return 0 }
        guard name.hasPrefix("session.v") else { return nil }
        let ver = String(name.dropFirst("session.v".count))
        return Int(ver)
    }

    private static func parseAssistantMessage(
        _ obj: [String: Any],
        sessionKey: String,
        file: URL
    ) -> UsageEvent? {
        let data = obj["data"] as? [String: Any] ?? [:]
        guard let usage = data["usage"] as? [String: Any] else { return nil }
        let turn = intValue(data["turn"]) ?? 0
        let step = intValue(data["step"]) ?? 0
        return makeEvent(
            usage: usage,
            sessionKey: sessionKey,
            turn: turn,
            step: step,
            time: obj["time"],
            file: file
        )
    }

    private static func parseAssistantChunkUsage(
        _ obj: [String: Any],
        sessionKey: String,
        file: URL
    ) -> UsageEvent? {
        let data = obj["data"] as? [String: Any] ?? [:]
        let chunk = data["chunk"] as? [String: Any] ?? [:]
        guard (chunk["type"] as? String) == "usage",
              let usage = chunk["usage"] as? [String: Any]
        else { return nil }
        let turn = intValue(data["turn"]) ?? 0
        let step = intValue(data["step"]) ?? 0
        return makeEvent(
            usage: usage,
            sessionKey: sessionKey,
            turn: turn,
            step: step,
            time: obj["time"],
            file: file
        )
    }

    private static func makeEvent(
        usage: [String: Any],
        sessionKey: String,
        turn: Int,
        step: Int,
        time: Any?,
        file: URL
    ) -> UsageEvent? {
        // TokenUsage counts are DISJOINT: inputTokens is uncached only.
        let input = intValue(usage["inputTokens"]) ?? 0
        let output = intValue(usage["outputTokens"]) ?? 0
        let cacheRead = intValue(usage["cacheReadTokens"]) ?? 0
        let cacheWrite = intValue(usage["cacheWriteTokens"]) ?? 0
        // reasoningTokens ⊂ output — do not add again.
        let total: Int
        if let listed = intValue(usage["totalTokens"]), listed > 0 {
            total = listed
        } else {
            total = input + output + cacheRead + cacheWrite
        }
        guard total > 0 else { return nil }

        let ts = parseEpochMS(time) ?? Date()
        // Shared id for message + chunk usage on the same step → first insert wins.
        let id = "dsh:\(sessionKey):\(turn):\(step)"

        return UsageEvent(
            id: id,
            source: .deepseek,
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
        if let d = any as? Double {
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
        }
        return nil
    }
}
