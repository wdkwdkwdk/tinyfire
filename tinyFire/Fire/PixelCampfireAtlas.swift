//
//  PixelCampfireAtlas.swift
//  tinyFire
//
//  Minecraft-like pixel campfire: static log tiles + Doom-style heat fire.
//

import AppKit
import Darwin
import SpriteKit

enum PixelPalette {
    /// Heat 0…32 → RGBA. 0 is clear.
    static let fire: [(UInt8, UInt8, UInt8, UInt8)] = {
        var t: [(UInt8, UInt8, UInt8, UInt8)] = [(0, 0, 0, 0)]
        // Deep red
        for i in 1...4 { t.append((UInt8(80 + i * 20), UInt8(8 + i * 2), 0, 255)) }
        // Red
        for i in 0...5 { t.append((UInt8(180 + i * 10), UInt8(20 + i * 8), 0, 255)) }
        // Orange
        for i in 0...6 { t.append((255, UInt8(70 + i * 14), UInt8(i * 4), 255)) }
        // Yellow
        for i in 0...6 { t.append((255, UInt8(170 + i * 8), UInt8(20 + i * 12), 255)) }
        // Hot white-yellow
        for i in 0...5 { t.append((255, UInt8(230 + i * 4), UInt8(140 + i * 18), 255)) }
        while t.count < 33 { t.append((255, 252, 230, 255)) }
        return t
    }()

    static let logDark: (UInt8, UInt8, UInt8, UInt8) = (62, 34, 14, 255)
    static let logMid: (UInt8, UInt8, UInt8, UInt8) = (110, 68, 28, 255)
    static let logLight: (UInt8, UInt8, UInt8, UInt8) = (148, 98, 44, 255)
    static let logEnd: (UInt8, UInt8, UInt8, UInt8) = (186, 148, 88, 255)
    static let ash: (UInt8, UInt8, UInt8, UInt8) = (78, 74, 70, 255)
    static let coal: (UInt8, UInt8, UInt8, UInt8) = (28, 24, 20, 255)
    static let ember: (UInt8, UInt8, UInt8, UInt8) = (220, 48, 8, 255)
    static let spark: (UInt8, UInt8, UInt8, UInt8) = (255, 236, 120, 255)
}

/// Procedural pixel fire (Doom-style heat field).
final class PixelFireEngine {
    let width: Int
    let height: Int
    private var heat: [UInt8]
    private var rgba: [UInt8]
    private var mutableTexture: SKMutableTexture?
    private var rng = SystemRandomNumberGenerator()

    /// 0…1 — how wide/hot the bottom source is.
    var intensity: Double = 0.4
    /// Which visual tier shapes the silhouette mask.
    var tier: FireTier = .crackle
    var phase: FirePhase = .flame
    var emberHeat: Double = 0
    /// Soft multi-source tint; classic orange when empty.
    var colorMix: FlameColorMix = .classic

    private var cachedMix: FlameColorMix = .classic
    private var cachedAccentEpoch: Int = -1
    private var columnWeights: [[Double]] = []
    private var sourceRamps: [[(UInt8, UInt8, UInt8, UInt8)]] = []
    var accentEpoch: Int = 0

    init(width: Int = 28, height: Int = 36) {
        self.width = width
        self.height = height
        self.heat = Array(repeating: 0, count: width * height)
        self.rgba = Array(repeating: 0, count: width * height * 4)
        rebuildColorCaches()
    }

    func reset() {
        heat = Array(repeating: 0, count: width * height)
    }

    func step() {
        // Rise: each cell takes heat from below with wind + cooling.
        for y in 0..<(height - 1) {
            for x in 0..<width {
                let below = Int(heat[(y + 1) * width + x])
                let wind = Int.random(in: -1...1, using: &rng)
                let dstX = min(width - 1, max(0, x + wind))
                let cool: Int
                switch tier {
                case .hush: cool = Int.random(in: 2...4, using: &rng)
                case .glow: cool = Int.random(in: 1...3, using: &rng)
                case .crackle: cool = Int.random(in: 1...3, using: &rng)
                case .roar: cool = Int.random(in: 1...2, using: &rng)
                case .blaze: cool = Int.random(in: 0...2, using: &rng)
                }
                let next = max(0, below - cool)
                heat[y * width + dstX] = UInt8(next)
            }
        }

        // Bottom source row
        let bottom = (height - 1) * width
        for x in 0..<width { heat[bottom + x] = 0 }

        switch phase {
        case .unlit, .out:
            break
        case .ember:
            seedEmbers(bottom: bottom)
        case .flame:
            seedFlame(bottom: bottom)
        }

        // Soft height mask so hush stays short and blaze can climb.
        applyHeightCap()
    }

    private func seedFlame(bottom: Int) {
        let cx = width / 2
        let half: Int = {
            switch tier {
            case .hush: return 2
            case .glow: return 3
            case .crackle: return 5
            case .roar: return 7
            case .blaze: return 10
            }
        }()
        let peak: UInt8 = {
            let base: Int = {
                switch tier {
                case .hush: return 18
                case .glow: return 22
                case .crackle: return 26
                case .roar: return 30
                case .blaze: return 32
                }
            }()
            return UInt8(min(32, Int(Double(base) * (0.55 + intensity * 0.55))))
        }()

        for dx in -half...half {
            let x = cx + dx
            guard x >= 0, x < width else { continue }
            let edge = abs(dx) == half
            var v = Int(peak) - abs(dx) * 2 - (edge ? 4 : 0)
            v += Int.random(in: -2...2, using: &rng)
            // Occasional spit for hotter tiers
            if tier == .blaze || tier == .roar, Int.random(in: 0...8, using: &rng) == 0 {
                v = min(32, v + 6)
            }
            heat[bottom + x] = UInt8(clamping: max(0, v))
        }

        // Second row kick so flame has a thick base
        if height >= 2 {
            let row = (height - 2) * width
            for dx in -(half - 1)...(half - 1) where half > 1 {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let cur = Int(heat[row + x])
                let boost = Int(peak) / 2 - abs(dx)
                heat[row + x] = UInt8(clamping: max(cur, boost))
            }
        }
    }

    private func seedEmbers(bottom: Int) {
        let cx = width / 2
        let n = 3 + Int(emberHeat * 4)
        for i in 0..<n {
            let x = cx - n / 2 + i
            guard x >= 0, x < width else { continue }
            let pulse = Int(10 + emberHeat * 12) + Int.random(in: -3...3, using: &rng)
            if Int.random(in: 0...2, using: &rng) == 0 {
                heat[bottom + x] = UInt8(clamping: pulse)
            }
        }
    }

    private func applyHeightCap() {
        let maxRows: Int = {
            switch phase {
            case .unlit, .out: return 0
            case .ember: return 4
            case .flame:
                switch tier {
                case .hush: return 8
                case .glow: return 14
                case .crackle: return 22
                case .roar: return 30
                case .blaze: return height
                }
            }
        }()
        let cut = height - maxRows
        guard cut > 0 else { return }
        for y in 0..<cut {
            for x in 0..<width {
                // Fade rather than hard clip near the cap
                let dist = cut - y
                if dist > 2 {
                    heat[y * width + x] = 0
                } else {
                    let h = Int(heat[y * width + x])
                    heat[y * width + x] = UInt8(clamping: h / (4 - dist))
                }
            }
        }
    }

    func refreshPaletteIfNeeded() {
        if colorMix != cachedMix || sourceRamps.isEmpty || accentEpoch != cachedAccentEpoch {
            rebuildColorCaches()
        }
    }

    func rebuildColorCaches() {
        cachedMix = colorMix
        cachedAccentEpoch = accentEpoch
        let sources = UsageSource.allCases
        sourceRamps = FlamePaletteBuilder.ramps(for: sources)
        columnWeights = colorMix.columnWeights(width: width)
    }

    /// Reuse one GPU texture — allocating NSImage/SKTexture every frame was a memory leak.
    @discardableResult
    func updateTexture() -> SKTexture {
        refreshPaletteIfNeeded()
        let count = width * height
        let classic = colorMix.isClassic
        let sources = UsageSource.allCases
        for i in 0..<count {
            let h = min(32, Int(heat[i]))
            let o = i * 4
            if h == 0 {
                rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 0
                continue
            }
            let c: (UInt8, UInt8, UInt8, UInt8)
            if classic {
                c = PixelPalette.fire[h]
            } else {
                let x = i % width
                c = blendedPixel(heat: h, column: x, sources: sources)
            }
            rgba[o] = c.0
            rgba[o + 1] = c.1
            rgba[o + 2] = c.2
            rgba[o + 3] = c.3
        }

        let texture: SKMutableTexture
        if let existing = mutableTexture {
            texture = existing
        } else {
            let created = SKMutableTexture(size: CGSize(width: width, height: height))
            mutableTexture = created
            texture = created
        }

        let w = width
        let h = height
        rgba.withUnsafeBytes { src in
            texture.modifyPixelData { dest, _ in
                guard let dest, let base = src.baseAddress else { return }
                let rowBytes = w * 4
                // SpriteKit mutable textures are bottom-up; heat[0] is the tip (top).
                for y in 0..<h {
                    memcpy(
                        dest.advanced(by: (h - 1 - y) * rowBytes),
                        base.advanced(by: y * rowBytes),
                        rowBytes
                    )
                }
            }
        }
        texture.filteringMode = .nearest
        return texture
    }

    private func blendedPixel(
        heat h: Int,
        column x: Int,
        sources: [UsageSource]
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        guard x >= 0, x < columnWeights.count else {
            return PixelPalette.fire[h]
        }
        let ws = columnWeights[x]
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        var used = 0.0
        for i in 0..<sources.count {
            let w = i < ws.count ? ws[i] : 0
            guard w > 0.001, i < sourceRamps.count else { continue }
            let c = sourceRamps[i][h]
            r += Double(c.0) * w
            g += Double(c.1) * w
            b += Double(c.2) * w
            a += Double(c.3) * w
            used += w
        }
        guard used > 0.001 else { return PixelPalette.fire[h] }

        // Tip converges to shared white-hot so multi-hue flames still read as one fire.
        if h >= 26 {
            let k = Double(h - 26) / 6.0
            let tip = PixelPalette.fire[h]
            r = r * (1 - k) + Double(tip.0) * k
            g = g * (1 - k) + Double(tip.1) * k
            b = b * (1 - k) + Double(tip.2) * k
        }

        return (
            UInt8(clamping: Int(r.rounded())),
            UInt8(clamping: Int(g.rounded())),
            UInt8(clamping: Int(b.rounded())),
            UInt8(clamping: Int(a.rounded()))
        )
    }
}

enum PixelCampfireAtlas {
    static let pixelScale: CGFloat = 3
    static let fireW = 28
    static let fireH = 36
    static let logW = 28
    static let logH = 12

    static func makeNearestTexture(from image: NSImage) -> SKTexture {
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }

    static func makeNearestTexture(width: Int, height: Int, plot: (inout [[(UInt8, UInt8, UInt8, UInt8)]]) -> Void) -> SKTexture {
        var grid = Array(
            repeating: Array(repeating: (UInt8(0), UInt8(0), UInt8(0), UInt8(0)), count: width),
            count: height
        )
        plot(&grid)
        return makeNearestTexture(from: image(from: grid))
    }

    static func logTexture() -> SKTexture {
        makeNearestTexture(width: logW, height: logH) { g in
            // Flat bed: ash + two logs, no protruding cross-stick.
            stamp(&g, row: 8, cols: 4...23, PixelPalette.ash)
            stamp(&g, row: 9, cols: 3...24, PixelPalette.coal)
            stamp(&g, row: 10, cols: 5...22, PixelPalette.ash)
            stamp(&g, row: 11, cols: 7...20, PixelPalette.coal)
            put(&g, 8, 9, PixelPalette.ember)
            put(&g, 14, 9, PixelPalette.ember)
            put(&g, 19, 9, PixelPalette.ember)

            // Back log (lower tier)
            stamp(&g, row: 6, cols: 2...25, PixelPalette.logDark)
            stamp(&g, row: 7, cols: 2...25, PixelPalette.logMid)
            put(&g, 2, 6, PixelPalette.logEnd); put(&g, 2, 7, PixelPalette.logEnd)
            put(&g, 25, 6, PixelPalette.logEnd); put(&g, 25, 7, PixelPalette.logLight)

            // Front log — flat top where the flame sits
            stamp(&g, row: 4, cols: 3...24, PixelPalette.logLight)
            stamp(&g, row: 5, cols: 3...24, PixelPalette.logMid)
            put(&g, 3, 4, PixelPalette.logEnd); put(&g, 3, 5, PixelPalette.logEnd)
            put(&g, 24, 4, PixelPalette.logEnd); put(&g, 24, 5, PixelPalette.logLight)
        }
    }

    static func sparkTexture() -> SKTexture {
        makeNearestTexture(width: 3, height: 3) { g in
            put(&g, 1, 1, PixelPalette.spark)
            put(&g, 1, 0, PixelPalette.spark)
            put(&g, 0, 1, (255, 180, 40, 200))
            put(&g, 2, 1, (255, 180, 40, 180))
        }
    }

    // MARK: - Grid helpers

    private static func image(from grid: [[(UInt8, UInt8, UInt8, UInt8)]]) -> NSImage {
        let h = grid.count
        let w = grid.first?.count ?? 0
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: w, height: h))
        }
        for y in 0..<h {
            for x in 0..<w {
                let c = grid[y][x]
                let i = (y * w + x) * 4
                data[i] = c.0; data[i + 1] = c.1; data[i + 2] = c.2; data[i + 3] = c.3
            }
        }
        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    private static func put(
        _ g: inout [[(UInt8, UInt8, UInt8, UInt8)]],
        _ x: Int,
        _ y: Int,
        _ c: (UInt8, UInt8, UInt8, UInt8)
    ) {
        guard y >= 0, y < g.count, x >= 0, x < g[y].count else { return }
        g[y][x] = c
    }

    private static func stamp(
        _ g: inout [[(UInt8, UInt8, UInt8, UInt8)]],
        row: Int,
        cols: ClosedRange<Int>,
        _ c: (UInt8, UInt8, UInt8, UInt8)
    ) {
        for x in cols { put(&g, x, row, c) }
    }
}
