//
//  FireScene.swift
//  tinyFire
//
//  Pixel campfire: Doom-style heat field + nearest-neighbor sprites.
//

import SpriteKit

final class FireScene: SKScene {
    private let root = SKNode()
    private let logNode = SKSpriteNode()
    private let flameNode = SKSpriteNode()
    private var sparkNodes: [SKSpriteNode] = []

    private let engine = PixelFireEngine(
        width: PixelCampfireAtlas.fireW,
        height: PixelCampfireAtlas.fireH
    )

    /// Live display scale — S/M/L changes this, not just the panel frame.
    private(set) var pixelScale: CGFloat = 3.5

    private var flameBaseY: CGFloat {
        let logHalf = CGFloat(PixelCampfireAtlas.logH) * pixelScale * 0.5
        return logHalf - CGFloat(4) * pixelScale
    }

    private var current: FireSnapshot = .extinguished
    private var reduceMotion = false
    private var lastStepTime: TimeInterval = 0
    private var sparksReady = false
    private var displayTexture: SKTexture?
    private var accentEpoch: Int = 0

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        anchorPoint = CGPoint(x: 0.5, y: 0.28)
        scaleMode = .resizeFill

        if logNode.parent == nil {
            logNode.texture = PixelCampfireAtlas.logTexture()
            logNode.zPosition = 1
            logNode.texture?.filteringMode = .nearest

            flameNode.anchorPoint = CGPoint(x: 0.5, y: 0.0)
            flameNode.zPosition = 2
            flameNode.alpha = 0

            let sparkTex = PixelCampfireAtlas.sparkTexture()
            sparkNodes = (0..<12).map { _ in
                let s = SKSpriteNode(texture: sparkTex)
                s.zPosition = 3
                s.alpha = 0
                root.addChild(s)
                return s
            }
            sparksReady = true

            root.addChild(logNode)
            root.addChild(flameNode)
            addChild(root)
        }

        layoutSprites()
        engine.reset()
        apply(.extinguished, reduceMotion: false, accentEpoch: 0, force: true)
        refreshFlameTexture()
    }

    func setPixelScale(_ scale: CGFloat) {
        let next = max(1.5, scale)
        guard abs(next - pixelScale) > 0.01 else {
            layoutSprites()
            return
        }
        pixelScale = next
        layoutSprites()
    }

    private func layoutSprites() {
        let px = pixelScale
        logNode.size = CGSize(
            width: CGFloat(PixelCampfireAtlas.logW) * px,
            height: CGFloat(PixelCampfireAtlas.logH) * px
        )
        logNode.position = .zero

        flameNode.size = CGSize(
            width: CGFloat(PixelCampfireAtlas.fireW) * px,
            height: CGFloat(PixelCampfireAtlas.fireH) * px
        )
        flameNode.position = CGPoint(x: 0, y: flameBaseY - px)

        for spark in sparkNodes {
            spark.size = CGSize(width: px, height: px * 2)
        }
    }

    func apply(_ snapshot: FireSnapshot, reduceMotion: Bool, accentEpoch: Int = 0, force: Bool = false) {
        self.reduceMotion = reduceMotion
        let mixChanged = snapshot.colorMix != current.colorMix || accentEpoch != self.accentEpoch
        let tierChanged = snapshot.tier != current.tier || snapshot.phase != current.phase
        current = snapshot
        self.accentEpoch = accentEpoch
        engine.intensity = snapshot.intensity
        engine.tier = snapshot.tier
        engine.phase = snapshot.phase
        engine.emberHeat = snapshot.emberHeat
        engine.colorMix = snapshot.colorMix
        engine.accentEpoch = accentEpoch
        if mixChanged {
            engine.rebuildColorCaches()
        }
        if force || tierChanged {
            switch snapshot.phase {
            case .unlit, .out:
                flameNode.alpha = 0
                engine.reset()
            case .ember:
                flameNode.alpha = 0.85
            case .flame:
                flameNode.alpha = 1
            }
        } else {
            switch snapshot.phase {
            case .unlit, .out:
                flameNode.alpha = max(0, flameNode.alpha - 0.2)
            case .ember:
                flameNode.alpha = 0.7 + 0.3 * CGFloat(snapshot.emberHeat)
            case .flame:
                flameNode.alpha = 1
            }
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard !isPaused else { return }

        let stepFPS: TimeInterval = reduceMotion ? 6 : 12
        if lastStepTime == 0 { lastStepTime = currentTime }
        if currentTime - lastStepTime >= 1.0 / stepFPS {
            lastStepTime = currentTime
            if current.phase == .flame || current.phase == .ember {
                engine.step()
                refreshFlameTexture()
            } else if flameNode.alpha > 0 {
                engine.step()
                refreshFlameTexture()
            }
        }

        animateSparks(at: currentTime)

        let baseY = flameBaseY - pixelScale
        if current.phase == .flame, !reduceMotion {
            let amp: CGFloat = {
                switch current.tier {
                case .hush: return 0
                case .glow: return 0.5 * pixelScale / 3.5
                case .crackle: return 1 * pixelScale / 3.5
                case .roar: return 1.5 * pixelScale / 3.5
                case .blaze: return 2 * pixelScale / 3.5
                }
            }()
            let j = (CGFloat(sin(currentTime * 2.2)) * amp).rounded()
            flameNode.position = CGPoint(x: j, y: baseY)
        } else {
            flameNode.position = CGPoint(x: 0, y: baseY)
        }
    }

    private func refreshFlameTexture() {
        let tex = engine.updateTexture()
        displayTexture = tex
        if flameNode.texture !== tex {
            flameNode.texture = tex
        }
    }

    private func animateSparks(at time: TimeInterval) {
        guard sparksReady else { return }
        let active: Int
        switch current.phase {
        case .flame:
            let base: Int = {
                switch current.tier {
                case .hush: return 0
                case .glow: return 1
                case .crackle: return 3
                case .roar: return 6
                case .blaze: return 10
                }
            }()
            active = reduceMotion ? max(0, base / 2) : min(sparkNodes.count, base + Int(current.sparkBurst * 2))
        case .ember:
            active = current.emberHeat > 0.55 ? 1 : 0
        case .unlit, .out:
            for s in sparkNodes { s.alpha = 0 }
            return
        }

        let px = pixelScale
        let riseMax: CGFloat = {
            switch current.tier {
            case .hush: return 10 * px
            case .glow: return 14 * px
            case .crackle: return 20 * px
            case .roar: return 26 * px
            case .blaze: return 32 * px
            }
        }()

        for (i, spark) in sparkNodes.enumerated() {
            guard i < active else {
                spark.alpha = 0
                continue
            }
            let seed = Double(i) * 1.7 + Double(current.tier.rawValue.count)
            let speed = 12.0 + current.intensity * 14.0
            let t = time * speed * 0.07 + seed
            let rise = CGFloat((t * 9).truncatingRemainder(dividingBy: Double(max(1, riseMax))))
            let sway = (CGFloat(sin(t * 2.1 + seed)) * px * 0.5).rounded()
            let spread = CGFloat(i - active / 2) * px
            spark.position = CGPoint(
                x: sway + spread,
                y: (flameBaseY + 4 + rise).rounded()
            )
            let life = 1 - rise / max(1, riseMax)
            spark.alpha = max(0, life * (0.5 + current.intensity * 0.5))
            if !current.colorMix.isClassic {
                spark.color = sparkTint(for: i)
                spark.colorBlendFactor = 0.65
            } else {
                spark.colorBlendFactor = 0
            }
        }
    }

    private func sparkTint(for index: Int) -> SKColor {
        let weights = current.colorMix.weights
        let sources = UsageSource.allCases.filter { (weights[$0] ?? 0) > 0.02 }
        guard !sources.isEmpty else { return .orange }
        let source = sources[index % sources.count]
        return SourceFlameColors.nsColor(for: source)
    }
}
