//
//  FireplaceAudioController.swift
//  tinyFire
//
//  Procedural hearth ambience.
//  Layers: warm air roar + mid hiss + irregular wood ticks/pops.
//  Crackles bypass the roar lowpass so snaps stay audible.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class FireplaceAudioController: ObservableObject {
    private static let enabledKey = "sound.enabled"
    private static let volumeKey = "sound.volume"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            applyTargets()
        }
    }

    /// Master loudness 0…1 (user-facing).
    @Published var volume: Double {
        didSet {
            let clamped = min(1, max(0, volume))
            if clamped != volume {
                volume = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
            applyTargets()
        }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var started = false

    private let state = AudioRenderState()
    private var lastSnapshot = FireSnapshot.extinguished
    private var panelAudible = true

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.volumeKey) == nil {
            volume = 0.48
        } else {
            volume = min(1, max(0, UserDefaults.standard.double(forKey: Self.volumeKey)))
        }
    }

    func start() {
        guard !started else {
            applyTargets()
            return
        }
        started = true
        installGraph()
        applyTargets()
        do {
            try engine.start()
        } catch {
            started = false
        }
    }

    func stop() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        started = false
    }

    func sync(snapshot: FireSnapshot, panelVisible: Bool) {
        lastSnapshot = snapshot
        panelAudible = panelVisible
        applyTargets()
        if !engine.isRunning, started {
            try? engine.start()
        }
    }

    private func installGraph() {
        let main = engine.mainMixerNode
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let shared = state

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = abl.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            shared.render(into: buf, frameCount: Int(frameCount))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: main, format: format)
        main.outputVolume = 1
        sourceNode = node
    }

    private func applyTargets() {
        let heat = Self.heat(for: lastSnapshot)
        let master = (isEnabled && panelAudible) ? Float(volume) : 0

        // Bed stays present; crackles stay occasional, not a constant tick track.
        let bed = master * (0.40 + heat * 0.60)
        // Mean seconds between crackles (higher = sparser).
        // hush ~5–6s · mid ~3s · blaze ~1.6s
        let tickGap = max(1.5, 5.8 - heat * 4.0)
        // Rare louder sap pops.
        let popBias = 0.04 + heat * 0.10
        let activity = heat

        state.setTargets(bedGain: bed, tickGapSeconds: tickGap, popBias: popBias, activity: activity)
    }

    private static func heat(for snap: FireSnapshot) -> Float {
        switch snap.phase {
        case .unlit, .out:
            return 0
        case .ember:
            return Float(0.08 + snap.emberHeat * 0.18)
        case .flame:
            let i = max(0, min(1, snap.intensity))
            return Float(0.18 + pow(i, 0.65) * 0.82)
        }
    }
}

// MARK: - Audio thread

private final class AudioRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var targetBed: Float = 0
    private var targetTickGap: Float = 1.2
    private var targetPopBias: Float = 0.12
    private var targetActivity: Float = 0

    private var bedGain: Float = 0
    private var tickGap: Float = 1.2
    private var popBias: Float = 0.12
    private var activity: Float = 0

    // Noise / filter memory
    private var brown: Float = 0
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var roarLP: Float = 0
    private var hissLP: Float = 0
    private var flutterPhase: Float = 0

    // Event scheduler (samples until next crackle attempt)
    private var samplesUntilEvent: Int = 22_050
    private var followUpsLeft: Int = 0

    // Active transient voices (up to 3 overlapping snaps)
    private var voices: [CrackleVoice] = [
        CrackleVoice(), CrackleVoice(), CrackleVoice()
    ]

    private var rngState: UInt64 = 0xA5A5_F1A5_C0DE_BEEF

    func setTargets(bedGain: Float, tickGapSeconds: Float, popBias: Float, activity: Float) {
        lock.lock()
        targetBed = bedGain
        targetTickGap = tickGapSeconds
        targetPopBias = popBias
        targetActivity = activity
        lock.unlock()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock()
        let tgBed = targetBed
        let tgGap = targetTickGap
        let tgPop = targetPopBias
        let tgAct = targetActivity
        lock.unlock()

        let smooth: Float = 1.0 - expf(-1.0 / (0.04 * 44_100))

        for i in 0..<frameCount {
            bedGain += (tgBed - bedGain) * smooth
            tickGap += (tgGap - tickGap) * smooth
            popBias += (tgPop - popBias) * smooth
            activity += (tgAct - activity) * smooth

            let white = nextWhite()

            // --- Bed: combustion air (brown) + soft hiss (pink) ---
            brown = brown * 0.996 + white * 0.004
            // Paul Kellet pink-ish
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            let pink = pink0 + pink1 + pink2 + white * 0.1848

            // Slow amplitude flutter (flame breathing), ~0.15–0.4 Hz
            flutterPhase += (0.00002 + activity * 0.00003)
            if flutterPhase > 1 { flutterPhase -= 1 }
            let flutter = 0.88 + 0.12 * sinf(flutterPhase * 2 * .pi)

            var roar = brown * 4.5
            roarLP = roarLP * 0.97 + roar * 0.03
            roar = roarLP

            var hiss = pink * 0.08
            hissLP = hissLP * 0.86 + hiss * 0.14
            hiss = hissLP * (0.35 + activity * 0.65)

            let bed = (roar * 0.72 + hiss) * flutter * bedGain

            // --- Scheduler: sparse, irregular crackles (quiet spells matter) ---
            if activity > 0.02 {
                samplesUntilEvent -= 1
                if samplesUntilEvent <= 0 {
                    triggerCrackle(isFollowUp: followUpsLeft > 0)
                    if followUpsLeft > 0 {
                        followUpsLeft -= 1
                        // Loose double-tap only: 220–500 ms
                        samplesUntilEvent = Int(9_700 + nextFloat() * 12_000)
                    } else {
                        scheduleNextGap()
                        // Rare short echo (one follow-up), not a burst train.
                        if nextFloat() < 0.06 + activity * 0.06 {
                            followUpsLeft = 1
                        }
                    }
                }
            } else {
                samplesUntilEvent = max(samplesUntilEvent, 20_000)
                followUpsLeft = 0
            }

            var crackle: Float = 0
            for v in 0..<voices.count {
                crackle += voices[v].tick(white: white)
            }
            // Soften residual edge before the bed mix.
            crackle = crackle * 0.72

            var sample = bed + crackle * (0.28 + activity * 0.22)
            sample = tanhf(sample * 1.1)
            buffer[i] = sample
        }
    }

    private func scheduleNextGap() {
        // Exponential waits with a longer floor so it never machine-guns.
        let mean = max(1.4, tickGap)
        let u = max(0.0001, nextFloat())
        let seconds = -logf(u) * mean
        let clamped = min(14.0, max(0.9, seconds))
        samplesUntilEvent = Int(clamped * 44_100)
    }

    private func triggerCrackle(isFollowUp: Bool) {
        guard let idx = voices.firstIndex(where: { !$0.active })
                ?? voices.indices.min(by: { voices[$0].env < voices[$1].env })
        else { return }

        let bigPop = !isFollowUp && nextFloat() < popBias
        if bigPop {
            // Soft low thump — muted, woody, not a slap.
            voices[idx].trigger(
                amplitude: 0.35 + nextFloat() * 0.25,
                decay: 0.994 + nextFloat() * 0.003,
                brightness: 0.18 + nextFloat() * 0.14,
                thump: 0.65 + nextFloat() * 0.25
            )
        } else {
            // Soft ember tick — mid warmth, little HF bite.
            voices[idx].trigger(
                amplitude: 0.16 + nextFloat() * 0.22,
                decay: 0.978 + nextFloat() * 0.012,
                brightness: 0.22 + nextFloat() * 0.18,
                thump: 0.15 + nextFloat() * 0.20
            )
        }
    }

    private func nextWhite() -> Float {
        nextFloat() * 2 - 1
    }

    private func nextFloat() -> Float {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let r = rngState &* 0x2545F4914F6CDD1D
        return Float(r >> 40) / Float(1 << 24)
    }
}

/// One overlapping wood snap / pop.
private struct CrackleVoice {
    var active = false
    var env: Float = 0
    var decay: Float = 0.97
    var brightness: Float = 0.7
    var thump: Float = 0
    var hp: Float = 0
    var lp: Float = 0
    var amp: Float = 0

    mutating func trigger(amplitude: Float, decay: Float, brightness: Float, thump: Float) {
        active = true
        env = 1
        self.decay = decay
        self.brightness = brightness
        self.thump = thump
        amp = amplitude
        hp = 0
        lp = 0
    }

    mutating func tick(white: Float) -> Float {
        guard active else { return 0 }
        env *= decay
        if env < 0.001 {
            active = false
            env = 0
            return 0
        }

        // Warm burst: mostly mid/low body, gentle high-pass (no needle snap).
        let one: Float = 1
        let shaped: Float = white * brightness + (one - brightness) * lp
        lp = lp * 0.88 + white * 0.12
        let prev: Float = hp
        hp = shaped
        // Weaker differentiator → less sizzle.
        let high: Float = (hp - prev * 0.55) * 0.45

        let body: Float = lp * (0.55 + thump * 1.2)
        // Soft attack — no hard transient spike.
        let attack: Float = env > 0.85 ? 1.08 : 1.0
        let snap: Float = high + body
        let out: Float = snap * env * amp * attack
        return out
    }
}
