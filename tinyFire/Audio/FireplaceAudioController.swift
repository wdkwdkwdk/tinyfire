//
//  FireplaceAudioController.swift
//  tinyFire
//
//  Procedural hearth ambience: soft brown roar + sparse crackles.
//  No bundled sample — parameters track FireSnapshot in real time.
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

    /// Shared with the audio render thread (lock-protected).
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
            volume = 0.42
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
            // Soft-fail: console still works without audio hardware.
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

    /// Call from the flame sync loop (~10 Hz).
    func sync(snapshot: FireSnapshot, panelVisible: Bool) {
        lastSnapshot = snapshot
        panelAudible = panelVisible
        applyTargets()
        if !engine.isRunning, started {
            try? engine.start()
        }
    }

    // MARK: - Graph

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
        let gain = master * heat

        // Crackle density rises with heat; keep hush almost crackle-free.
        let crackle = heat * heat * 9.0
        // Brighter hiss / pops when roaring.
        let bright = 0.22 + heat * 0.55

        state.setTargets(gain: gain, crackleRate: crackle, brightness: bright)
    }

    /// 0…1 psychoacoustic “how much fire is there”.
    private static func heat(for snap: FireSnapshot) -> Float {
        switch snap.phase {
        case .unlit, .out:
            return 0
        case .ember:
            return Float(0.06 + snap.emberHeat * 0.14)
        case .flame:
            // Ease-in so mid fire is already cozy; blaze fills the room.
            let i = max(0, min(1, snap.intensity))
            let shaped = pow(i, 0.72)
            return Float(0.12 + shaped * 0.88)
        }
    }
}

// MARK: - Audio thread state

private final class AudioRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var targetGain: Float = 0
    private var targetCrackle: Float = 0
    private var targetBright: Float = 0.3

    private var gain: Float = 0
    private var crackleRate: Float = 0
    private var brightness: Float = 0.3

    private var brown: Float = 0
    private var lp: Float = 0
    private var hp: Float = 0
    private var crackleEnv: Float = 0
    private var crackleNoise: Float = 0
    private var rngState: UInt64 = 0xC0FFEE_DEAD_BEEF

    func setTargets(gain: Float, crackleRate: Float, brightness: Float) {
        lock.lock()
        targetGain = gain
        targetCrackle = crackleRate
        targetBright = brightness
        lock.unlock()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock()
        let tg = targetGain
        let tc = targetCrackle
        let tb = targetBright
        lock.unlock()

        // ~30 ms smoothing at 44.1 kHz
        let smooth: Float = 1.0 - exp(-1.0 / (0.03 * 44_100))

        for i in 0..<frameCount {
            gain += (tg - gain) * smooth
            crackleRate += (tc - crackleRate) * smooth
            brightness += (tb - brightness) * smooth

            let white = nextFloat() * 2 - 1

            // Leaky brown noise — soft hearth roar.
            brown = brown * 0.985 + white * 0.015
            var roar = brown * 3.2

            // Gentle mid hush (filtered white).
            lp = lp * 0.92 + white * 0.08
            roar += lp * 0.35

            // Sparse crackles.
            let crackleChance = crackleRate / 44_100
            if nextFloat() < crackleChance {
                crackleEnv = 0.55 + nextFloat() * 0.7
                crackleNoise = nextFloat() * 2 - 1
            }
            crackleEnv *= 0.965
            crackleNoise = crackleNoise * 0.88 + (nextFloat() * 2 - 1) * 0.12
            // High-pass-ish crackle
            let crack = crackleNoise * crackleEnv * (0.35 + brightness)

            var sample = roar * (0.55 + (1 - brightness) * 0.25) + crack

            // Soft one-pole lowpass — never harsh.
            let cutoff = 0.12 + brightness * 0.18
            hp = hp + cutoff * (sample - hp)
            sample = hp

            // Soft clip
            sample = tanh(sample * 1.4) * gain * 0.55
            buffer[i] = sample
        }
    }

    private func nextFloat() -> Float {
        // xorshift64*
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let r = rngState &* 0x2545F4914F6CDD1D
        return Float(r >> 40) / Float(1 << 24)
    }
}
