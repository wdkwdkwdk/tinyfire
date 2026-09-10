//
//  FireStateMachine.swift
//  tinyFire
//
//  Intensity tracks short-window burn rate (hard to max, falls fast when idle).
//  Daily usage only silently lifts a small 底火 floor — never the headline UI.
//

import Foundation
import Combine

enum FirePhase: String, Equatable {
    case unlit
    case flame
    case ember
    case out
}

enum FireTier: String, Equatable, CaseIterable, Identifiable {
    case hush
    case glow
    case crackle
    case roar
    case blaze

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hush: return L10n.t("tier.hush")
        case .glow: return L10n.t("tier.glow")
        case .crackle: return L10n.t("tier.crackle")
        case .roar: return L10n.t("tier.roar")
        case .blaze: return L10n.t("tier.blaze")
        }
    }

    /// Tier is driven by live intensity only — fuel must not inflate the look.
    /// Bands are uneven on purpose: 中火 easy, 大火 harder, 烈火 rare.
    static func from(intensity: Double, fuel: Double = 0) -> FireTier {
        _ = fuel
        switch intensity {
        case ..<0.16: return .hush
        case ..<0.34: return .glow
        case ..<0.56: return .crackle
        case ..<0.78: return .roar
        default: return .blaze
        }
    }
}

/// Debug / design preview that freezes the desktop flame on a fixed look.
enum FirePreviewStyle: String, CaseIterable, Identifiable {
    case out
    case ember
    case hush
    case glow
    case crackle
    case roar
    case blaze

    var id: String { rawValue }

    var label: String {
        switch self {
        case .out: return L10n.t("phase.out")
        case .ember: return L10n.t("phase.ember")
        case .hush: return L10n.t("tier.hush")
        case .glow: return L10n.t("tier.glow")
        case .crackle: return L10n.t("tier.crackle")
        case .roar: return L10n.t("tier.roar")
        case .blaze: return L10n.t("tier.blaze")
        }
    }

    var snapshot: FireSnapshot {
        switch self {
        case .out:
            return FireSnapshot(intensity: 0, fuel: 0, emberHeat: 0, phase: .out, sparkBurst: 0, tier: .hush, colorMix: .classic)
        case .ember:
            return FireSnapshot(intensity: 0, fuel: 0, emberHeat: 0.85, phase: .ember, sparkBurst: 0.15, tier: .hush, colorMix: .classic)
        case .hush:
            return FireSnapshot(intensity: 0.10, fuel: 0.18, emberHeat: 0.35, phase: .flame, sparkBurst: 0.1, tier: .hush, colorMix: .classic)
        case .glow:
            return FireSnapshot(intensity: 0.22, fuel: 0.35, emberHeat: 0.45, phase: .flame, sparkBurst: 0.25, tier: .glow, colorMix: .classic)
        case .crackle:
            return FireSnapshot(intensity: 0.45, fuel: 0.55, emberHeat: 0.55, phase: .flame, sparkBurst: 0.45, tier: .crackle, colorMix: .classic)
        case .roar:
            return FireSnapshot(intensity: 0.72, fuel: 0.78, emberHeat: 0.7, phase: .flame, sparkBurst: 0.75, tier: .roar, colorMix: .classic)
        case .blaze:
            return FireSnapshot(intensity: 1.0, fuel: 1.0, emberHeat: 0.9, phase: .flame, sparkBurst: 1.0, tier: .blaze, colorMix: .classic)
        }
    }
}

struct FireSnapshot: Equatable {
    var intensity: Double
    var fuel: Double
    var emberHeat: Double
    var phase: FirePhase
    var sparkBurst: Double
    var tier: FireTier
    /// Soft multi-source tint for the live flame.
    var colorMix: FlameColorMix = .classic

    static let extinguished = FireSnapshot(
        intensity: 0, fuel: 0, emberHeat: 0, phase: .unlit, sparkBurst: 0, tier: .hush, colorMix: .classic
    )
}

struct FireTuning: Sendable {
    /// Rolling window for 火势 — think in minutes, not seconds.
    var intensityWindowSeconds: Double = 60
    /// Piecewise TPM → intensity. Easy mid, harder roar, hard blaze.
    /// Cursor Agent estimates are small; 小火 must be easy to hold with light continuous use.
    ///   ~0.8k 微火 · ~2.5k 小火 · ~12k 中火 · ~45k 大火 · ~180k 烈火
    var tpmAnchors: [(tpm: Double, intensity: Double)] = [
        (0, 0),
        (800, 0.10),
        (2_500, 0.26),
        (12_000, 0.48),
        (45_000, 0.72),
        (180_000, 1.0),
    ]
    /// One log line credits at most this many tokens (whole-turn dumps).
    var eventCreditTokens: Double = 45_000
    /// Asymmetric smoothing on top of the 1-minute window.
    var intensityRiseSeconds: Double = 2.5
    var intensityFallSeconds: Double = 14

    /// Short session warmth — meters / sparks only, does not prop tier.
    var fuelTokenScale: Double = 120_000
    var fuelBurnPerSecondAtFull: Double = 1.0 / (90)
    var fuelBurnPerSecondAtIdle: Double = 1.0 / (150)

    var emberDecayPerSecond: Double = 1.0 / (2.5 * 60)
    var emberFromFuelGain: Double = 0.4
    var maxSparkBurst: Double = 1.0
    var sparkDecayPerSecond: Double = 1.4

    /// Daily usage gently raises a silent 底火 (asymptote ≈ hush / 小火 edge).
    var dailyBaseStartTokens: Double = 40_000
    var dailyBaseHalfTokens: Double = 600_000
    var dailyBaseMaxIntensity: Double = 0.22
}

@MainActor
final class FireStateMachine: ObservableObject {
    var snapshot: FireSnapshot {
        customPreview ?? previewStyle?.snapshot ?? liveSnapshot
    }

    @Published private(set) var liveSnapshot: FireSnapshot = .extinguished
    @Published private(set) var todayTokens: Int = 0
    @Published private(set) var todayBySource: [UsageSource: Int] = [:]
    /// Smoothed mix shown in console / flame (0…1 per source).
    @Published private(set) var displayedColorMix: FlameColorMix = .classic
    @Published var previewStyle: FirePreviewStyle? = nil
    @Published private(set) var customPreview: FireSnapshot? = nil
    @Published var animationPaused: Bool = false
    @Published var reduceMotion: Bool = false
    /// Bumps when user edits source colors so the scene rebuilds ramps.
    @Published private(set) var colorPaletteEpoch: Int = 0

    var isPreviewing: Bool { previewStyle != nil || customPreview != nil }

    private var tuning = FireTuning()
    private var recentInflows: [(date: Date, tokens: Double, source: UsageSource?)] = []
    private var lastTick: Date = .now
    private var timer: Timer?
    /// Live burn rate only — daily 底火 is applied at compose time.
    private var burnIntensity: Double = 0
    private var smoothedWeights: [UsageSource: Double] = [:]
    private var colorObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        lastTick = .now
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if colorObserver == nil {
            colorObserver = NotificationCenter.default.addObserver(
                forName: .sourceFlameColorsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.colorPaletteEpoch &+= 1
                    self?.liveSnapshot = self?.compose(self?.liveSnapshot ?? .extinguished) ?? .extinguished
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let colorObserver {
            NotificationCenter.default.removeObserver(colorObserver)
            self.colorObserver = nil
        }
    }

    func showPreview(_ style: FirePreviewStyle) {
        customPreview = nil
        previewStyle = style
        objectWillChange.send()
    }

    func showCustomPreview(intensity: Double) {
        let i = min(1, max(0, intensity))
        previewStyle = nil
        let tier: FireTier
        switch i {
        case ..<0.18: tier = .hush
        case ..<0.35: tier = .glow
        case ..<0.58: tier = .crackle
        case ..<0.82: tier = .roar
        default: tier = .blaze
        }
        let phase: FirePhase
        if i < 0.02 {
            phase = .out
        } else if i < 0.08 {
            phase = .ember
        } else {
            phase = .flame
        }
        customPreview = FireSnapshot(
            intensity: phase == .ember || phase == .out ? 0 : i,
            fuel: i,
            emberHeat: phase == .ember ? 0.85 : max(0.2, i * 0.9),
            phase: phase,
            sparkBurst: i,
            tier: tier,
            colorMix: displayedColorMix
        )
        objectWillChange.send()
    }

    func returnToLive() {
        previewStyle = nil
        customPreview = nil
        objectWillChange.send()
    }

    func updateTodayTokens(_ tokens: Int, bySource: [UsageSource: Int] = [:]) {
        todayTokens = max(0, tokens)
        todayBySource = bySource
        liveSnapshot = compose(liveSnapshot)
    }

    func ingest(tokens: Double, source: UsageSource? = nil, at date: Date = .now, animate: Bool = true) {
        guard tokens > 0 else { return }

        recentInflows.append((date, tokens, source))
        pruneInflows(now: date)

        let compressed = Self.softCompress(tokens)
        let fuelGain = min(0.55, compressed / tuning.fuelTokenScale)

        var next = liveSnapshot
        next.fuel = min(1.0, next.fuel + fuelGain)
        next.emberHeat = min(
            1.0,
            max(next.emberHeat, next.fuel * tuning.emberFromFuelGain + instantaneousRatePush(tokens: tokens) * 0.25)
        )
        if animate, previewStyle == nil {
            let burst = min(1.0, instantaneousRatePush(tokens: tokens))
            next.sparkBurst = min(
                tuning.maxSparkBurst,
                next.sparkBurst + 0.2 + burst * 0.9
            )
        }

        // Burn intensity is owned by the rate window; nudge toward target, keep 底火 separate.
        let target = targetIntensity(now: date)
        burnIntensity = max(burnIntensity, min(1.0, burnIntensity + (target - burnIntensity) * 0.55))
        next.intensity = burnIntensity
        next.phase = .flame
        smoothColorMix(dt: 0.9)
        next.colorMix = displayedColorMix
        liveSnapshot = compose(next)
    }

    func applySleepGap(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        advance(by: min(seconds, 6 * 60 * 60))
    }

    func resetToUnlit() {
        recentInflows.removeAll()
        burnIntensity = 0
        smoothedWeights = [:]
        displayedColorMix = .classic
        liveSnapshot = .extinguished
        lastTick = .now
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard dt > 0, !animationPaused else { return }
        advance(by: min(dt, 1.0))
    }

    private func advance(by dt: TimeInterval) {
        pruneInflows(now: .now)

        let target = targetIntensity(now: .now)
        var fuel = liveSnapshot.fuel
        var ember = liveSnapshot.emberHeat
        var spark = liveSnapshot.sparkBurst

        let tau = target > burnIntensity
            ? tuning.intensityRiseSeconds
            : tuning.intensityFallSeconds
        let alpha = 1.0 - exp(-dt / max(0.05, tau))
        burnIntensity += (target - burnIntensity) * alpha
        burnIntensity = min(1.0, max(0, burnIntensity))

        // Fuel is warmth residue only — never props burn intensity.
        if fuel > 0 {
            let burnRate = tuning.fuelBurnPerSecondAtIdle
                + (tuning.fuelBurnPerSecondAtFull - tuning.fuelBurnPerSecondAtIdle) * pow(max(burnIntensity, target), 1.1)
            fuel = max(0, fuel - burnRate * dt)
            ember = max(ember, fuel * 0.55 + burnIntensity * 0.25)
        } else {
            ember = max(0, ember - tuning.emberDecayPerSecond * dt)
        }

        spark = max(0, spark - tuning.sparkDecayPerSecond * dt)

        // Ease color mix so the flame doesn’t hard-cut between tools.
        smoothColorMix(dt: dt)

        liveSnapshot = compose(
            FireSnapshot(
                intensity: burnIntensity,
                fuel: fuel,
                emberHeat: ember,
                phase: .flame,
                sparkBurst: spark,
                tier: .hush,
                colorMix: displayedColorMix
            )
        )
    }

    /// Tokens/minute → intensity via uneven anchors (中火易、大火次之、烈火难).
    private func targetIntensity(now: Date) -> Double {
        pruneInflows(now: now)
        let window = max(1.0, tuning.intensityWindowSeconds)
        let credited = recentInflows.reduce(0.0) { $0 + credit(for: $1.tokens) }
        let tokensPerMinute = credited * (60.0 / window)
        return intensity(fromTPM: tokensPerMinute)
    }

    private func targetColorWeights(now: Date) -> [UsageSource: Double] {
        pruneInflows(now: now)
        var live: [UsageSource: Double] = [:]
        for item in recentInflows {
            guard let source = item.source else { continue }
            live[source, default: 0] += credit(for: item.tokens)
        }
        let liveTotal = live.values.reduce(0, +)
        if liveTotal > 50 {
            return live.mapValues { $0 / liveTotal }
        }
        // Quiet window → fall back to today’s share so 底火 still carries identity.
        let dayTotal = Double(todayBySource.values.reduce(0, +))
        guard dayTotal > 0 else { return [:] }
        var day: [UsageSource: Double] = [:]
        for (source, tokens) in todayBySource where tokens > 0 {
            day[source] = Double(tokens) / dayTotal
        }
        return day
    }

    private func smoothColorMix(dt: TimeInterval) {
        let target = targetColorWeights(now: .now)
        let tau = 2.8
        let alpha = 1.0 - exp(-dt / max(0.05, tau))
        var next = smoothedWeights
        for source in UsageSource.allCases {
            let goal = target[source] ?? 0
            let cur = next[source] ?? 0
            next[source] = cur + (goal - cur) * alpha
            if next[source]! < 0.004 { next[source] = 0 }
        }
        let sum = next.values.reduce(0, +)
        if sum > 0.02 {
            smoothedWeights = next.mapValues { $0 / sum }
        } else {
            smoothedWeights = [:]
        }
        displayedColorMix = FlameColorMix(weights: smoothedWeights)
    }

    private func intensity(fromTPM tpm: Double) -> Double {
        let anchors = tuning.tpmAnchors
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if tpm <= first.tpm { return first.intensity }
        if tpm >= last.tpm { return last.intensity }
        for i in 0..<(anchors.count - 1) {
            let a = anchors[i]
            let b = anchors[i + 1]
            if tpm <= b.tpm {
                let span = max(1.0, b.tpm - a.tpm)
                let t = (tpm - a.tpm) / span
                // Smoothstep so tier transitions don't feel linear-stepped.
                let s = t * t * (3 - 2 * t)
                return a.intensity + (b.intensity - a.intensity) * s
            }
        }
        return last.intensity
    }

    private func credit(for tokens: Double) -> Double {
        min(tokens, tuning.eventCreditTokens)
    }

    private func instantaneousRatePush(tokens: Double) -> Double {
        intensity(fromTPM: credit(for: tokens) * (60.0 / max(1.0, tuning.intensityWindowSeconds)))
    }

    /// Silent daily 底火: asymptotically approaches hush, never sells itself as a mode.
    private func dailyBaseIntensity() -> Double {
        let t = Double(todayTokens)
        guard t >= tuning.dailyBaseStartTokens else { return 0 }
        let x = (t - tuning.dailyBaseStartTokens) / tuning.dailyBaseHalfTokens
        let shaped = 1.0 - exp(-x)
        return tuning.dailyBaseMaxIntensity * shaped
    }

    private func compose(_ snap: FireSnapshot) -> FireSnapshot {
        var next = snap
        let base = dailyBaseIntensity()
        // Display = max(live burn, silent daily 底火). Never feed 底火 back into burnIntensity.
        let shown = max(burnIntensity, base)

        next.intensity = shown
        next.tier = FireTier.from(intensity: shown)
        next.colorMix = displayedColorMix

        if shown >= 0.035 {
            next.phase = .flame
            next.emberHeat = max(next.emberHeat, shown * 0.4)
        } else if next.emberHeat > 0.04 || next.fuel > 0.03 {
            next.phase = .ember
            next.intensity = 0
            next.tier = .hush
        } else if next.phase == .unlit {
            next.phase = .unlit
            next.intensity = 0
        } else {
            next.phase = .out
            next.intensity = 0
            next.fuel = 0
            next.emberHeat = 0
            next.sparkBurst = 0
        }
        return next
    }

    private func pruneInflows(now: Date) {
        let cutoff = now.addingTimeInterval(-tuning.intensityWindowSeconds)
        recentInflows.removeAll { $0.date < cutoff }
    }

    /// Mild compress for fuel gains only (intensity uses raw rate).
    static func softCompress(_ tokens: Double) -> Double {
        guard tokens > 0 else { return 0 }
        return tokens / (1.0 + tokens / 140_000.0)
    }

    static func compress(_ tokens: Double) -> Double { softCompress(tokens) }
}
