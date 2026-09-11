//
//  FlamePanelController.swift
//  tinyFire
//
//  Borderless nonactivating floating panel hosting SKView directly
//  (no NSHostingView — it paints an opaque white backdrop).
//

import AppKit
import SpriteKit
import Combine

@MainActor
final class FlamePanelController: NSObject, ObservableObject {
    static let shared = FlamePanelController()

    @Published var isVisible: Bool = true
    @Published var flameSize: FlameSize = {
        if let raw = UserDefaults.standard.string(forKey: "flame.size"),
           let size = FlameSize(rawValue: raw) {
            return size
        }
        return .medium
    }()

    private var panel: NSPanel?
    private var skView: FireSKView?
    private var store: AppModel?
    private let positionKey = "flame.panel.origin"
    private let sizeKey = "flame.size"
    private var didBootstrap = false
    private var summaryView: HoverSummaryView?
    private var isHoveringFlame = false
    private var lastSummaryRefresh: TimeInterval = 0
    private var lastAppliedSnapshot: FireSnapshot?

    enum FlameSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }

        var label: String {
            switch self {
            case .small: return L10n.t("size.small")
            case .medium: return L10n.t("size.medium")
            case .large: return L10n.t("size.large")
            }
        }

        /// Pixel scale for the campfire sprites — this is what users actually see.
        var pixelScale: CGFloat {
            switch self {
            case .small: return 2.0
            case .medium: return 3.5
            case .large: return 5.5
            }
        }

        var panelSize: CGSize {
            let px = pixelScale
            let contentW = CGFloat(PixelCampfireAtlas.fireW) * px
            let contentH = CGFloat(PixelCampfireAtlas.fireH + PixelCampfireAtlas.logH) * px
            return CGSize(
                width: ceil(contentW + 28),
                height: ceil(contentH + 36)
            )
        }
    }

    func bootstrap(store: AppModel) {
        self.store = store
        // Drop obsolete island placement preference if present.
        UserDefaults.standard.removeObject(forKey: "flame.placement")

        if didBootstrap {
            showFront()
            syncScene()
            return
        }
        didBootstrap = true

        let size = flameSize.panelSize
        let container = TrackingContainerView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizingMask = [.width, .height]

        let sk = FireSKView(frame: container.bounds)
        sk.autoresizingMask = [.width, .height]
        sk.allowsTransparency = true
        sk.wantsLayer = true
        sk.layer?.backgroundColor = NSColor.clear.cgColor
        sk.fireScene.setPixelScale(flameSize.pixelScale)
        container.addSubview(sk)
        skView = sk

        let summary = HoverSummaryView(frame: NSRect(
            x: 0, y: 0,
            width: HoverSummaryView.cardWidth,
            height: 88
        ))
        summary.isHidden = true
        summary.autoresizingMask = []
        container.addSubview(summary)
        summaryView = summary

        container.onHover = { [weak self] hovering in
            guard let self else { return }
            self.setFlameHovering(hovering)
        }
        container.onDrag = { [weak self] delta in
            self?.moveBy(delta: delta)
        }
        container.menu = makeContextMenu()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none

        self.panel = panel
        placeOnMainScreenBottomTrailing(force: true)
        syncScene()
        showFront()

        Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncScene()
            }
        }
    }

    private func syncScene() {
        guard let store, let skView else { return }
        let snap = store.fire.snapshot
        skView.apply(
            snapshot: snap,
            reduceMotion: store.fire.reduceMotion,
            paused: store.fire.animationPaused,
            accentEpoch: store.fire.colorPaletteEpoch
        )
        store.audio.sync(snapshot: snap, panelVisible: isVisible)
        lastAppliedSnapshot = snap
        if isHoveringFlame {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSummaryRefresh >= 0.5 {
                lastSummaryRefresh = now
                refreshSummary()
            }
        }
    }

    private func setFlameHovering(_ hovering: Bool) {
        isHoveringFlame = hovering
        summaryView?.isHidden = !hovering
        if hovering {
            refreshSummary()
        } else {
            layoutFlameChrome(hovering: false)
        }
    }

    /// Flame size drives the campfire; hover card sits just above the visible fire, not the panel ceiling.
    private func layoutFlameChrome(hovering: Bool) {
        guard let panel, let skView, let summaryView else { return }
        let flame = flameSize.panelSize
        let cardW = HoverSummaryView.cardWidth
        let cardH = max(summaryView.intrinsicContentSize.height, 72)
        let pad: CGFloat = 8
        let gap: CGFloat = 8
        let px = flameSize.pixelScale

        // FireScene anchors the campfire near the bottom (anchorPoint.y = 0.28).
        // A full fireH sprite tip estimate — card hugs that, instead of jumping to the panel top
        // and leaving a huge empty gap above the visible flame.
        let anchorY = flame.height * 0.28
        let flameBaseY = CGFloat(PixelCampfireAtlas.logH) * px * 0.5 - 4 * px
        let visualTipY = anchorY + max(0, flameBaseY) + CGFloat(PixelCampfireAtlas.fireH) * px * 0.62
        let cardY = min(visualTipY + gap, flame.height + gap)

        let bottomCenterX = panel.frame.midX
        let bottomY = panel.frame.origin.y

        let width: CGFloat
        let height: CGFloat
        if hovering {
            width = max(flame.width, cardW + pad * 2)
            height = max(flame.height, cardY + cardH + pad)
        } else {
            width = flame.width
            height = flame.height
        }

        var frame = panel.frame
        frame.size = CGSize(width: width, height: height)
        frame.origin.x = bottomCenterX - width / 2
        frame.origin.y = bottomY
        panel.setFrame(frame, display: true)

        skView.autoresizingMask = []
        skView.frame = NSRect(
            x: (width - flame.width) / 2,
            y: 0,
            width: flame.width,
            height: flame.height
        )
        skView.fireScene.size = skView.bounds.size

        if hovering {
            summaryView.frame = NSRect(
                x: (width - cardW) / 2,
                y: cardY,
                width: cardW,
                height: cardH
            )
        }

        constrainToVisibleScreen(persist: false)
    }

    private func refreshSummary() {
        guard let store, let summaryView, isHoveringFlame else { return }
        let rows: [(UsageSource, Int, Bool)] = UsageSource.allCases.compactMap { source in
            let tokens = store.monitor.todayBySource[source] ?? 0
            guard tokens > 0 else { return nil }
            let estimated = source == .cursor
                && (store.monitor.statuses.first { $0.source == .cursor }?.detail
                    .localizedCaseInsensitiveContains("estimate") == true)
            return (source, tokens, estimated)
        }

        summaryView.apply(
            HoverSummaryView.Model(
                todayTokens: store.monitor.todayTokens,
                rows: rows.map { (source: $0.0, tokens: $0.1, estimated: $0.2) },
                updatedAt: store.monitor.statuses.compactMap(\.lastReadAt).max()
            )
        )
        layoutFlameChrome(hovering: true)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "重置火焰位置", action: #selector(resetPositionAction), keyEquivalent: "")
        menu.addItem(withTitle: "暂停/恢复动画", action: #selector(togglePauseAction), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏火焰", action: #selector(hideAction), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func resetPositionAction() {
        resetPositionToDefault()
        store?.igniteDemoFlameIfNeeded()
    }

    @objc private func togglePauseAction() {
        store?.fire.animationPaused.toggle()
        syncScene()
    }

    @objc private func hideAction() {
        setVisible(false)
    }

    func showFront() {
        isVisible = true
        guard let panel else { return }
        constrainToVisibleScreen()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        guard let panel else { return }
        if visible {
            if isHoveringFlame {
                layoutFlameChrome(hovering: true)
            } else {
                constrainToVisibleScreen()
            }
            panel.orderFrontRegardless()
        } else {
            isHoveringFlame = false
            summaryView?.isHidden = true
            layoutFlameChrome(hovering: false)
            panel.orderOut(nil)
        }
    }

    func toggleVisible() {
        setVisible(!isVisible)
    }

    func resetPositionToDefault() {
        UserDefaults.standard.removeObject(forKey: positionKey)
        placeOnMainScreenBottomTrailing(force: true)
        showFront()
    }

    func setSize(_ size: FlameSize) {
        flameSize = size
        UserDefaults.standard.set(size.rawValue, forKey: sizeKey)
        skView?.fireScene.setPixelScale(size.pixelScale)
        guard panel != nil else { return }
        layoutFlameChrome(hovering: isHoveringFlame)
        persistOrigin()
        syncScene()
    }

    func moveBy(delta: CGPoint) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        panel.setFrame(frame, display: true)
        constrainToVisibleScreen()
        persistOrigin()
    }

    private func placeOnMainScreenBottomTrailing(force: Bool) {
        guard let panel else { return }
        let size = flameSize.panelSize

        if !force,
           let saved = UserDefaults.standard.string(forKey: positionKey),
           let origin = Self.decodeOrigin(saved),
           Self.isOriginOnAnyScreen(origin, size: size) {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            constrainToVisibleScreen()
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.maxX - size.width - 36,
            y: visible.minY + 36
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        persistOrigin()
    }

    private func constrainToVisibleScreen(persist: Bool = true) {
        guard let panel else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var frame = panel.frame
        if frame.width < 10 || frame.height < 10 {
            frame.size = flameSize.panelSize
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first { $0.frame.insetBy(dx: -40, dy: -40).contains(center) }
            ?? NSScreen.main
            ?? screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)

        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
        if persist { persistOrigin() }
    }

    private func persistOrigin() {
        guard let panel else { return }
        UserDefaults.standard.set(Self.encodeOrigin(panel.frame.origin), forKey: positionKey)
    }

    private static func isOriginOnAnyScreen(_ origin: CGPoint, size: CGSize) -> Bool {
        let probe = CGRect(origin: origin, size: size).insetBy(dx: 20, dy: 20)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
    }

    private static func encodeOrigin(_ point: CGPoint) -> String {
        "\(point.x),\(point.y)"
    }

    private static func decodeOrigin(_ value: String) -> CGPoint? {
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }
}

/// Clear container with hover + drag; no SwiftUI hosting.
final class TrackingContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    private var lastDragPoint: CGPoint?

    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let bed = NSRect(
            x: bounds.midX - 48,
            y: 2,
            width: 96,
            height: bounds.height - 4
        )
        return bed.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        if let last = lastDragPoint {
            onDrag?(CGPoint(x: point.x - last.x, y: point.y - last.y))
        }
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // Intentionally empty — fully transparent.
    }
}
