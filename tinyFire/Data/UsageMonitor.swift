//
//  UsageMonitor.swift
//  tinyFire
//

import Foundation
import Combine

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var statuses: [SourceStatus] = UsageSource.allCases.map {
        SourceStatus(source: $0, state: .notFound, detail: "—", lastReadAt: nil, todayTokens: 0)
    }
    @Published private(set) var todayTokens: Int = 0
    @Published private(set) var todayBySource: [UsageSource: Int] = [:]
    @Published private(set) var todayHourly: [HourlyUsage] = (0..<24).map { HourlyUsage(hour: $0, tokens: 0) }
    @Published private(set) var todayBreakdown: UsageBreakdown = UsageBreakdown()
    @Published private(set) var lastEvent: UsageEvent?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    private weak var fire: FireStateMachine?
    private let store = UsageStore.shared
    private var timer: Timer?
    private var didCompleteBaseline = false
    private var scanTask: Task<Void, Never>?
    private var claudeBestTotal: [String: Int] = [:]

    private let warmWindow: TimeInterval = 4 * 60

    func attach(fire: FireStateMachine) {
        self.fire = fire
    }

    func start() {
        if store.meta("cursor.estimate.v2") != "1" {
            store.purgeCursorBubbleV1()
            store.setMeta("cursor.estimate.v2", value: "1")
            store.setMeta("cursor.watermark", value: "0")
        }
        reloadStatsFromStore()
        refreshSourceStatuses()
        // Warm fire from persisted recent events before live scan.
        warmFromStore()
        enqueueScan(baseline: true)
        timer?.invalidate()
        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.enqueueScan(baseline: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
    }

    func rescan() {
        didCompleteBaseline = false
        claudeBestTotal.removeAll()
        store.clearFileCursors()
        reloadStatsFromStore()
        refreshSourceStatuses()
        enqueueScan(baseline: true)
    }

    private func enqueueScan(baseline: Bool) {
        guard !isScanning else { return }
        isScanning = true
        refreshSourceStatuses()

        let fileSince = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-12 * 60 * 60)
        let startMS = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let watermark = Int64(store.meta("cursor.watermark") ?? "0") ?? 0
        let wantCodex = status(for: .codex)?.state == .ok
        let wantClaude = status(for: .claudeCode)?.state == .ok
        let wantCursor = status(for: .cursor)?.state == .ok
        let wantGrok = status(for: .grok)?.state == .ok
        let wantPi = status(for: .pi)?.state == .ok
        let wantAmp = status(for: .amp)?.state == .ok
        let knownCursorLocal = wantCursor ? store.eventIDs(withPrefix: "cursor:bubble:v2:") : []
        let knownCursorDash = wantCursor ? store.eventIDs(withPrefix: "cursor:dash:") : []
        let storeRef = store

        scanTask = Task.detached(priority: .utility) { [weak self] in
            var collected: [UsageEvent] = []
            var newWatermark = watermark
            var cursorMode: CursorIngestMode?
            var cursorDetail: String?

            if wantCodex {
                for file in CodexLogAdapter.discoverLogFiles(modifiedSince: fileSince) {
                    collected.append(contentsOf: Self.readJSONLDetached(
                        file: file, store: storeRef, fromStart: baseline
                    ) {
                        CodexLogAdapter.parseLine($0, file: file)
                    })
                }
            }
            if wantClaude {
                for file in ClaudeCodeLogAdapter.discoverLogFiles(modifiedSince: fileSince) {
                    collected.append(contentsOf: Self.readJSONLDetached(
                        file: file, store: storeRef, fromStart: baseline
                    ) {
                        ClaudeCodeLogAdapter.parseLine($0, file: file)
                    })
                }
            }
            if wantGrok {
                for file in GrokLogAdapter.discoverLogFiles(modifiedSince: fileSince) {
                    collected.append(contentsOf: Self.readJSONLDetached(
                        file: file, store: storeRef, fromStart: baseline
                    ) {
                        GrokLogAdapter.parseLine($0, file: file)
                    })
                }
            }
            if wantPi {
                for file in PiLogAdapter.discoverLogFiles(modifiedSince: fileSince) {
                    collected.append(contentsOf: Self.readJSONLDetached(
                        file: file, store: storeRef, fromStart: baseline
                    ) {
                        PiLogAdapter.parseLine($0, file: file)
                    })
                }
            }
            if wantAmp {
                for file in AmpLogAdapter.discoverThreadFiles(modifiedSince: fileSince) {
                    collected.append(contentsOf: AmpLogAdapter.parseThread(file: file))
                }
            }
            if wantCursor {
                let result = CursorLogAdapter.poll(
                    watermarkMS: watermark,
                    startOfDayMS: startMS,
                    knownDashboardIDs: knownCursorDash,
                    knownLocalIDs: knownCursorLocal,
                    maxNewEvents: 250,
                    forceDashboard: baseline
                )
                collected.append(contentsOf: result.events)
                newWatermark = result.newWatermark
                cursorMode = result.mode
                cursorDetail = result.detail
            }

            collected.sort { $0.timestamp < $1.timestamp }
            await self?.finishScan(
                events: collected,
                newCursorWatermark: newWatermark,
                cursorMode: cursorMode,
                cursorDetail: cursorDetail,
                touched: [
                    .codex: wantCodex,
                    .claudeCode: wantClaude,
                    .cursor: wantCursor,
                    .grok: wantGrok,
                    .pi: wantPi,
                    .amp: wantAmp
                ],
                isBaseline: baseline
            )
        }
    }

    private func finishScan(
        events: [UsageEvent],
        newCursorWatermark: Int64,
        cursorMode: CursorIngestMode?,
        cursorDetail: String?,
        touched: [UsageSource: Bool],
        isBaseline: Bool
    ) {
        defer { isScanning = false }
        store.setMeta("cursor.watermark", value: String(newCursorWatermark))

        if let cursorMode {
            let previous = store.meta("cursor.ingest.mode")
            store.setMeta("cursor.ingest.mode", value: cursorMode.rawValue)
            if let cursorDetail {
                store.setMeta("cursor.ingest.detail", value: cursorDetail)
            }
            // First time official wins: drop local estimates so totals don't double.
            if cursorMode == .dashboard, previous != CursorIngestMode.dashboard.rawValue {
                store.purgeCursorLocalEstimates()
            }
        }

        let warmCutoff = Date().addingTimeInterval(-warmWindow)
        let baselinePass = isBaseline || !didCompleteBaseline
        for event in events {
            apply(event, warmCutoff: warmCutoff, baselinePass: baselinePass)
        }
        for (source, did) in touched where did {
            touch(source)
        }

        reloadStatsFromStore()
        if baselinePass { didCompleteBaseline = true }
        refreshSourceStatuses()
    }

    /// Background-safe JSONL tail reader (UsageStore is lock-protected).
    ///
    /// - Baseline / `fromStart`: re-read from byte 0. Inserts are idempotent by event id.
    /// - Incremental: seek to saved cursor. If the cursor is already at EOF but this path
    ///   never produced any stored events, rewind (self-heal the "stuck at 0 tokens" case).
    nonisolated private static func readJSONLDetached(
        file: URL,
        store: UsageStore,
        fromStart: Bool = false,
        parse: (String) -> UsageEvent?
    ) -> [UsageEvent] {
        let path = file.path
        let cursor = store.fileCursor(path: path)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
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
                if let event = parse(line) {
                    events.append(event)
                }
            }
        }
        let newOffset = (try? handle.offset()) ?? offset
        store.setFileCursor(path: path, offset: newOffset, partial: buffer)
        return events
    }

    private func reloadStatsFromStore() {
        let totals = store.todayTotals()
        todayTokens = totals.total
        todayBySource = totals.bySource
        todayHourly = store.todayHourlyTotals()
        todayBreakdown = store.todayBreakdown()
        fire?.updateTodayTokens(totals.total, bySource: totals.bySource)
    }

    private func warmFromStore() {
        let cutoff = Date().addingTimeInterval(-warmWindow)
        let recent = store.recentEvents(since: cutoff)
        for event in recent {
            fire?.ingest(tokens: Double(event.tokens), source: event.source, at: event.timestamp, animate: false)
        }
        // Afterglow if something burned earlier today.
        if fire?.snapshot.phase == .unlit || fire?.snapshot.phase == .out {
            let start = Calendar.current.startOfDay(for: Date())
            if let last = store.recentEvents(since: start, limit: 5000).last {
                let age = Date().timeIntervalSince(last.timestamp)
                let horizon: TimeInterval = 2 * 60 * 60
                if age >= 0, age < horizon {
                    let remaining = max(0.12, 1 - age / horizon)
                    fire?.ingest(tokens: 30_000 * remaining, source: last.source, at: last.timestamp, animate: false)
                }
            }
        }
    }

    private func refreshSourceStatuses() {
        var cursorConn = CursorLogAdapter.connectionState()
        if cursorConn.0 == .ok {
            if let detail = store.meta("cursor.ingest.detail"), !detail.isEmpty {
                cursorConn.1 = detail
            } else if store.meta("cursor.ingest.mode") == CursorIngestMode.dashboard.rawValue {
                cursorConn.1 = "Dashboard API"
            } else if store.meta("cursor.ingest.mode") == CursorIngestMode.localEstimate.rawValue {
                cursorConn.1 = "Local estimate"
            }
        }
        let pairs: [(UsageSource, (SourceConnectionState, String))] = [
            (.claudeCode, ClaudeCodeLogAdapter.connectionState()),
            (.codex, CodexLogAdapter.connectionState()),
            (.cursor, cursorConn),
            (.grok, GrokLogAdapter.connectionState()),
            (.pi, PiLogAdapter.connectionState()),
            (.amp, AmpLogAdapter.connectionState())
        ]
        statuses = pairs.map { source, state in
            SourceStatus(
                source: source,
                state: state.0,
                detail: shortPath(state.1),
                lastReadAt: status(for: source)?.lastReadAt,
                todayTokens: todayBySource[source] ?? 0
            )
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func status(for source: UsageSource) -> SourceStatus? {
        statuses.first { $0.source == source }
    }

    private func touch(_ source: UsageSource) {
        guard let idx = statuses.firstIndex(where: { $0.source == source }) else { return }
        statuses[idx].lastReadAt = Date()
        statuses[idx].todayTokens = todayBySource[source] ?? 0
    }

    private func apply(_ event: UsageEvent, warmCutoff: Date, baselinePass: Bool) {
        var toStore = event

        if event.source == .claudeCode {
            let previous = claudeBestTotal[event.id] ?? 0
            if event.tokens <= previous { return }
            let delta = event.tokens - previous
            claudeBestTotal[event.id] = event.tokens
            toStore = UsageEvent(
                id: previous == 0 ? event.id : "\(event.id)#\(event.tokens)",
                source: event.source,
                timestamp: event.timestamp,
                tokens: delta,
                breakdown: event.breakdown,
                filePath: event.filePath,
                isEstimated: false
            )
        }
        // Cursor estimates are one-shot per bubble id (no growth chase).

        guard store.insertEvent(toStore) else { return }
        lastEvent = toStore
        feedFire(
            tokens: toStore.tokens,
            source: toStore.source,
            at: toStore.timestamp,
            warmCutoff: warmCutoff,
            baselinePass: baselinePass
        )
    }

    private func feedFire(
        tokens: Int,
        source: UsageSource,
        at date: Date,
        warmCutoff: Date,
        baselinePass: Bool
    ) {
        guard tokens > 0, let fire else { return }
        if baselinePass {
            guard date >= warmCutoff else { return }
            fire.ingest(tokens: Double(tokens), source: source, at: date, animate: false)
        } else {
            fire.ingest(tokens: Double(tokens), source: source, at: date, animate: true)
        }
    }
}
