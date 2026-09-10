//
//  SourceFlameColors.swift
//  tinyFire
//
//  Per-tool flame accents + soft spatial mix (no muddy average of complements).
//

import AppKit
import SwiftUI

/// User-tunable accent for each coding tool’s contribution to the campfire.
enum SourceFlameColors {
    private static let defaultsKey = "flame.sourceColors.v1"

    /// Fire-friendly defaults: warm, slightly muted — mix stays campfire, not neon.
    static let builtIn: [UsageSource: (r: Double, g: Double, b: Double)] = [
        .claudeCode: (0.91, 0.47, 0.18), // orange
        .codex: (0.28, 0.72, 0.42),      // green
        .cursor: (0.32, 0.56, 0.92),     // blue
        .grok: (0.72, 0.42, 0.95),       // violet
        .pi: (0.95, 0.62, 0.22),         // amber
        .amp: (0.20, 0.78, 0.78),        // teal
    ]

    static func accent(for source: UsageSource) -> (r: Double, g: Double, b: Double) {
        if let stored = load()[source.rawValue], stored.count == 3 {
            return (stored[0], stored[1], stored[2])
        }
        return builtIn[source] ?? (0.95, 0.55, 0.2)
    }

    static func nsColor(for source: UsageSource) -> NSColor {
        let c = accent(for: source)
        return NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func color(for source: UsageSource) -> Color {
        Color(nsColor: nsColor(for: source))
    }

    static func setAccent(for source: UsageSource, color: Color) {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return }
        var map = load()
        map[source.rawValue] = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        UserDefaults.standard.set(map, forKey: defaultsKey)
        NotificationCenter.default.post(name: .sourceFlameColorsDidChange, object: nil)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .sourceFlameColorsDidChange, object: nil)
    }

    private static func load() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]] ?? [:]
    }
}

extension Notification.Name {
    static let sourceFlameColorsDidChange = Notification.Name("tinyFire.sourceFlameColorsDidChange")
}

/// Live burn mix — weights in the intensity window (and optional daily fallback).
struct FlameColorMix: Equatable {
    /// Normalized contributions; empty → classic orange fire.
    var weights: [UsageSource: Double]

    static let classic = FlameColorMix(weights: [:])

    var isClassic: Bool { weights.values.reduce(0, +) < 0.02 }

    /// Soft horizontal bands by source order (stable sides), feathered so edges melt.
    func columnWeights(width: Int) -> [[Double]] {
        let sources = UsageSource.allCases
        let raw = sources.map { max(0, weights[$0] ?? 0) }
        let total = raw.reduce(0, +)
        guard total > 0.02, width > 0 else {
            return Array(repeating: Array(repeating: 0, count: sources.count), count: max(width, 0))
        }
        let norm = raw.map { $0 / total }

        // Cumulative band centers on [0,1].
        var edges: [Double] = [0]
        var cum = 0.0
        for w in norm {
            cum += w
            edges.append(cum)
        }

        var out = Array(repeating: Array(repeating: 0.0, count: sources.count), count: width)
        let feather = 0.14 // soft zone — readable proportions, no hard stripes
        for x in 0..<width {
            let u = (Double(x) + 0.5) / Double(width)
            var row = Array(repeating: 0.0, count: sources.count)
            for i in 0..<sources.count {
                guard norm[i] > 0.001 else { continue }
                let start = edges[i]
                let end = edges[i + 1]
                let center = (start + end) * 0.5
                let half = max(0.06, (end - start) * 0.5 + feather * 0.5)
                let d = abs(u - center)
                let t = max(0, 1 - d / half)
                // Smoothstep for butter edges
                row[i] = t * t * (3 - 2 * t)
            }
            let s = row.reduce(0, +)
            if s > 0 {
                for i in 0..<row.count { row[i] /= s }
            }
            out[x] = row
        }
        return out
    }
}

enum FlamePaletteBuilder {
    /// Classic Doom ramp (unchanged look when mix is empty).
    static let classic: [(UInt8, UInt8, UInt8, UInt8)] = PixelPalette.fire

    /// Accent-tinted heat ramp: keeps fire luminance curve, swaps mid hue.
    static func ramp(accent: (r: Double, g: Double, b: Double)) -> [(UInt8, UInt8, UInt8, UInt8)] {
        var table: [(UInt8, UInt8, UInt8, UInt8)] = [(0, 0, 0, 0)]
        let ar = accent.r, ag = accent.g, ab = accent.b
        for h in 1...32 {
            let u = Double(h) / 32.0
            let rgb: (Double, Double, Double)
            if u < 0.32 {
                let k = u / 0.32
                let deep = (ar * 0.22, ag * 0.14, ab * 0.10)
                let mid = (ar * 0.55, ag * 0.38, ab * 0.28)
                rgb = lerp(deep, mid, k)
            } else if u < 0.58 {
                let k = (u - 0.32) / 0.26
                let mid = (ar * 0.55, ag * 0.38, ab * 0.28)
                let full = (ar, ag, ab)
                rgb = lerp(mid, full, k)
            } else if u < 0.82 {
                let k = (u - 0.58) / 0.24
                // Lift toward warm white-yellow while keeping a hint of accent.
                let hot = (
                    min(1, ar * 0.35 + 0.65),
                    min(1, ag * 0.25 + 0.72),
                    min(1, ab * 0.12 + 0.28)
                )
                rgb = lerp((ar, ag, ab), hot, k)
            } else {
                let k = (u - 0.82) / 0.18
                let tip = (1.0, 0.96, 0.82)
                let white = (1.0, 0.99, 0.94)
                rgb = lerp(tip, white, k)
            }
            table.append(byte(rgb, alpha: 255))
        }
        return table
    }

    static func ramps(for sources: [UsageSource]) -> [[(UInt8, UInt8, UInt8, UInt8)]] {
        sources.map { ramp(accent: SourceFlameColors.accent(for: $0)) }
    }

    private static func lerp(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double),
        _ t: Double
    ) -> (Double, Double, Double) {
        let u = max(0, min(1, t))
        return (
            a.0 + (b.0 - a.0) * u,
            a.1 + (b.1 - a.1) * u,
            a.2 + (b.2 - a.2) * u
        )
    }

    private static func byte(_ rgb: (Double, Double, Double), alpha: UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
        (
            UInt8(clamping: Int((rgb.0 * 255).rounded())),
            UInt8(clamping: Int((rgb.1 * 255).rounded())),
            UInt8(clamping: Int((rgb.2 * 255).rounded())),
            alpha
        )
    }
}
