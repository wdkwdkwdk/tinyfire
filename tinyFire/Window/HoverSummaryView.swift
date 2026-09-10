//
//  HoverSummaryView.swift
//  tinyFire
//
//  Compact dark card for desktop hover — tokens + per-source rows only.
//

import AppKit

final class HoverSummaryView: NSView {
    struct Model {
        var todayTokens: Int
        var rows: [(source: UsageSource, tokens: Int, estimated: Bool)]
        var updatedAt: Date?
    }

    /// Fixed card width — independent of flame panel size.
    static let cardWidth: CGFloat = 220

    private var model = Model(todayTokens: 0, rows: [], updatedAt: nil)

    private let padX: CGFloat = 16
    private let padY: CGFloat = 14

    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    func apply(_ model: Model) {
        let same =
            self.model.todayTokens == model.todayTokens
            && self.model.rows.count == model.rows.count
            && zip(self.model.rows, model.rows).allSatisfy {
                $0.source == $1.source && $0.tokens == $1.tokens && $0.estimated == $1.estimated
            }
            && self.model.updatedAt == model.updatedAt
        if same { return }
        let sizeChanged = self.model.rows.count != model.rows.count
        self.model = model
        needsDisplay = true
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let rowH: CGFloat = CGFloat(model.rows.count) * 18
        let updatedH: CGFloat = model.updatedAt == nil ? 0 : 16
        // header tokens + rows + padding — width never follows flame size
        return NSSize(width: Self.cardWidth, height: padY * 2 + 34 + rowH + updatedH + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.74).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        let content = bounds.insetBy(dx: padX, dy: padY)
        var y = content.maxY - 18

        let token = formatTokens(model.todayTokens)
        drawText(
            token,
            at: NSPoint(x: content.minX, y: y - 2),
            font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            color: .white,
            width: content.width - 52
        )
        drawText(
            L10n.t("hover.tokens"),
            at: NSPoint(x: content.maxX - 48, y: y + 2),
            font: .systemFont(ofSize: 10, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.45),
            width: 48,
            align: .right
        )

        y -= 10
        for row in model.rows {
            y -= 18
            let dot = NSBezierPath(ovalIn: NSRect(x: content.minX, y: y + 4, width: 6, height: 6))
            SourceFlameColors.nsColor(for: row.source).withAlphaComponent(0.95).setFill()
            dot.fill()
            let suffix = row.estimated ? " · \(L10n.t("hover.estimated"))" : ""
            drawText(
                row.source.displayName + suffix,
                at: NSPoint(x: content.minX + 12, y: y),
                font: .systemFont(ofSize: 11, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.58),
                width: content.width * 0.55
            )
            drawText(
                formatTokens(row.tokens),
                at: NSPoint(x: content.midX, y: y),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.88),
                width: content.width * 0.5 - 4,
                align: .right
            )
        }

        if let updatedAt = model.updatedAt {
            y -= 18
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.resolvedLocale
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: updatedAt)
            drawText(
                String(format: L10n.t("hover.updated"), time),
                at: NSPoint(x: content.minX, y: y),
                font: .systemFont(ofSize: 9, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.34),
                width: content.width
            )
        }
    }

    private func drawText(
        _ string: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        align: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (string as NSString).draw(
            in: NSRect(x: point.x, y: point.y, width: width, height: font.pointSize + 6),
            withAttributes: attrs
        )
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return value.formatted()
    }
}
