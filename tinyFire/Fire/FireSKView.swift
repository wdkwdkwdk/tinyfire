//
//  FireSKView.swift
//  tinyFire
//

import AppKit
import SpriteKit
import SwiftUI

final class FireSKView: SKView {
    let fireScene = FireScene(size: CGSize(width: 200, height: 240))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        allowsTransparency = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        ignoresSiblingOrder = true
        preferredFramesPerSecond = 20
        presentScene(fireScene)
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        if bounds.size.width > 1, bounds.size.height > 1 {
            fireScene.size = bounds.size
        }
    }

    func apply(snapshot: FireSnapshot, reduceMotion: Bool, paused: Bool, accentEpoch: Int = 0) {
        isPaused = paused
        if paused {
            preferredFramesPerSecond = 1
        } else if snapshot.phase == .out || snapshot.phase == .unlit {
            preferredFramesPerSecond = 8
        } else if reduceMotion {
            preferredFramesPerSecond = 12
        } else {
            preferredFramesPerSecond = 20
        }
        if bounds.size.width > 1, bounds.size.height > 1 {
            fireScene.size = bounds.size
        }
        fireScene.apply(snapshot, reduceMotion: reduceMotion, accentEpoch: accentEpoch)
    }
}

struct FireCanvas: NSViewRepresentable {
    var snapshot: FireSnapshot
    var reduceMotion: Bool
    var paused: Bool
    var accentEpoch: Int = 0

    func makeNSView(context: Context) -> FireSKView {
        FireSKView(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
    }

    func updateNSView(_ nsView: FireSKView, context: Context) {
        nsView.apply(snapshot: snapshot, reduceMotion: reduceMotion, paused: paused, accentEpoch: accentEpoch)
    }
}
