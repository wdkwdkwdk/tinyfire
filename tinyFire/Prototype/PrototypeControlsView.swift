//
//  PrototypeControlsView.swift
//  tinyFire
//

import Charts
import SwiftUI

struct PrototypeControlsView: View {
    @ObservedObject var store: AppModel
    @ObservedObject private var monitor: UsageMonitor
    @ObservedObject private var fire: FireStateMachine
    @ObservedObject private var languageStore = LanguageStore.shared
    @ObservedObject private var simulator: UsageSimulator
    @State private var colorDraftEpoch: Int = 0
    @State private var editingColor: UsageSource?
    @State private var showDebug = false
    @State private var versionTapCount = 0
    @State private var lastVersionTap: Date = .distantPast
    @State private var debugIntensity: Double = 0.45

    init(store: AppModel) {
        self.store = store
        self.monitor = store.monitor
        self.fire = store.fire
        self.simulator = store.simulator
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsSection
                colorsSection
                sourcesSection
                sizeSection
                if showDebug {
                    debugSection
                }
                Text(L10n.t("console.footnote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: L10n.t("console.version"), AppVersion.display))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
            }
            .padding(22)
        }
        .background(ConsoleBackground())
        .frame(minWidth: 460, minHeight: 680)
        .environment(\.locale, languageStore.language.locale ?? .autoupdatingCurrent)
        .id(languageStore.revision)
        .onDisappear {
            // Closing Console always re-hides debug for next open.
            showDebug = false
            versionTapCount = 0
            fire.returnToLive()
            simulator.setAutoBurn(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            HStack(alignment: .center, spacing: 12) {
                Image("MenuBarIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("app.name"))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(L10n.t("app.tagline"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { languageStore.language },
                set: { languageStore.set($0) }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(localizedPickerLabel(lang)).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 132)
        }
    }

    private func localizedPickerLabel(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: return L10n.t("language.system")
        case .english: return L10n.t("language.english")
        case .chinese: return L10n.t("language.chinese")
        case .japanese: return L10n.t("language.japanese")
        case .korean: return L10n.t("language.korean")
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        let bySource = UsageSource.allCases.compactMap { source -> (UsageSource, Int)? in
            let t = monitor.todayBySource[source] ?? 0
            return t > 0 ? (source, t) : nil
        }
        let hourly = monitor.todayHourly.filter {
            $0.hour <= Calendar.current.component(.hour, from: Date())
        }
        let parts = tokenParts()

        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle(L10n.t("stats.title"), trailing: fire.snapshot.tier.label)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shortTokens(monitor.todayTokens))
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                Text(L10n.t("hover.tokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Spacer()
            }

            if monitor.todayTokens == 0 {
                Text(L10n.t("stats.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                if !bySource.isEmpty {
                    stackedShareBar(bySource)
                    VStack(spacing: 8) {
                        ForEach(bySource, id: \.0) { source, tokens in
                            sourceStatRow(source: source, tokens: tokens, total: monitor.todayTokens)
                        }
                    }
                }

                if hourly.contains(where: { $0.tokens > 0 }) {
                    Text(L10n.t("stats.hourly"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Chart(hourly) { item in
                        AreaMark(
                            x: .value("h", item.hour),
                            y: .value("t", item.tokens)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("h", item.hour),
                            y: .value("t", item.tokens)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXScale(domain: 0...23)
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                            AxisValueLabel {
                                if let h = value.as(Int.self) {
                                    Text("\(h)h").font(.caption2)
                                }
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 88)
                }

                if !parts.isEmpty {
                    Text(L10n.t("stats.breakdown"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    breakdownBars(parts)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func stackedShareBar(_ items: [(UsageSource, Int)]) -> some View {
        let total = max(1, items.reduce(0) { $0 + $1.1 })
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(items, id: \.0) { source, tokens in
                    SourceFlameColors.color(for: source)
                        .frame(width: max(6, geo.size.width * CGFloat(tokens) / CGFloat(total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private func sourceStatRow(source: UsageSource, tokens: Int, total: Int) -> some View {
        let pct = total > 0 ? Double(tokens) / Double(total) : 0
        return HStack(spacing: 10) {
            Circle()
                .fill(SourceFlameColors.color(for: source))
                .frame(width: 8, height: 8)
            Text(source.displayName)
                .font(.subheadline)
            Spacer()
            Text(shortTokens(tokens))
                .font(.subheadline.monospacedDigit().weight(.medium))
            Text(String(format: "%.0f%%", pct * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func breakdownBars(_ parts: [(label: String, tokens: Int, color: Color)]) -> some View {
        let maxV = max(1, parts.map(\.tokens).max() ?? 1)
        return VStack(spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(part.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(shortTokens(part.tokens))
                            .font(.caption.monospacedDigit().weight(.medium))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(part.color.gradient)
                                .frame(width: max(4, geo.size.width * CGFloat(part.tokens) / CGFloat(maxV)))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }

    /// Prefer real breakdown fields; remainder of today total becomes "Other / estimated".
    private func tokenParts() -> [(label: String, tokens: Int, color: Color)] {
        let b = monitor.todayBreakdown
        let input = max(0, b.input ?? 0)
        let output = max(0, b.output ?? 0)
        let cacheRead = max(0, b.cacheRead ?? 0)
        let cacheWrite = max(0, b.cacheWrite ?? 0)
        let known = input + output + cacheRead + cacheWrite
        let other = max(0, monitor.todayTokens - known)

        var parts: [(String, Int, Color)] = []
        if input > 0 {
            parts.append((L10n.t("stats.input"), input, Color(red: 0.95, green: 0.58, blue: 0.28)))
        }
        if output > 0 {
            parts.append((L10n.t("stats.output"), output, Color(red: 0.92, green: 0.36, blue: 0.30)))
        }
        if cacheRead > 0 {
            parts.append((L10n.t("stats.cacheRead"), cacheRead, Color(red: 0.40, green: 0.68, blue: 0.95)))
        }
        if cacheWrite > 0 {
            parts.append((L10n.t("stats.cacheWrite"), cacheWrite, Color(red: 0.42, green: 0.78, blue: 0.58)))
        }
        // Only show "other" when it is meaningful (Cursor estimates often land here).
        if other > 0, Double(other) / Double(max(1, monitor.todayTokens)) > 0.03 {
            parts.append((L10n.t("stats.other"), other, Color.primary.opacity(0.35)))
        }
        return parts
    }

    // MARK: - Colors

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle(L10n.t("colors.title"))
                Spacer()
                Button(L10n.t("colors.reset")) {
                    SourceFlameColors.resetAll()
                    colorDraftEpoch &+= 1
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            mixPreview

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                spacing: 10
            ) {
                ForEach(UsageSource.allCases) { source in
                    colorChip(source)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .id(colorDraftEpoch)
    }

    private var mixPreview: some View {
        let mix = fire.displayedColorMix
        let parts = UsageSource.allCases.compactMap { source -> (UsageSource, Double)? in
            let w = mix.weights[source] ?? 0
            return w > 0.02 ? (source, w) : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(parts.isEmpty ? L10n.t("colors.mix.empty") : L10n.t("colors.mix.active"))
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if parts.isEmpty {
                        LinearGradient(
                            colors: [
                                Color(red: 0.90, green: 0.40, blue: 0.12),
                                Color(red: 1.0, green: 0.78, blue: 0.30)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else {
                        ForEach(parts, id: \.0) { source, weight in
                            SourceFlameColors.color(for: source)
                                .frame(width: max(8, geo.size.width * weight))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 14)
        }
    }

    private func colorChip(_ source: UsageSource) -> some View {
        let share = fire.displayedColorMix.weights[source] ?? 0
        return Button {
            editingColor = source
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(SourceFlameColors.color(for: source))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .shadow(color: SourceFlameColors.color(for: source).opacity(0.35), radius: 4, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(share > 0.01 ? String(format: "%.0f%%", share * 100) : "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { editingColor == source },
            set: { if !$0 { editingColor = nil } }
        )) {
            colorEditor(for: source)
        }
    }

    private func colorEditor(for source: UsageSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source.displayName)
                .font(.headline)
            ColorPicker(
                "",
                selection: Binding(
                    get: { SourceFlameColors.color(for: source) },
                    set: { newValue in
                        SourceFlameColors.setAccent(for: source, color: newValue)
                        colorDraftEpoch &+= 1
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 180, height: 120)
        }
        .padding(16)
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle(L10n.t("sources.title"))
                Spacer()
                Button(L10n.t("sources.rescan")) { store.monitor.rescan() }
                    .font(.caption)
                    .disabled(monitor.isScanning)
            }

            ForEach(monitor.statuses, id: \.source) { status in
                HStack(spacing: 10) {
                    Circle()
                        .fill(SourceFlameColors.color(for: status.source))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(status.source.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(status.state.label)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusChipColor(status.state).opacity(0.15), in: Capsule())
                                .foregroundStyle(statusChipColor(status.state))
                        }
                        Text(status.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if status.todayTokens > 0 {
                        Text(shortTokens(status.todayTokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let last = monitor.lastEvent {
                Text(
                    String(
                        format: L10n.t("sources.last"),
                        last.source.displayName,
                        "\(shortTokens(last.tokens)) · \(last.timestamp.formatted(date: .omitted, time: .shortened))"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L10n.t("size.title"))

            HStack(spacing: 16) {
                ForEach(FlamePanelController.FlameSize.allCases) { size in
                    Button {
                        store.panel.setSize(size)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(store.panel.flameSize == size ? 0.85 : 0.25))
                                .frame(
                                    width: 12 + size.pixelScale * 6,
                                    height: 14 + size.pixelScale * 7
                                )
                            Text(size.label)
                                .font(.caption2)
                                .foregroundStyle(store.panel.flameSize == size ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(store.panel.flameSize == size
                                      ? Color.orange.opacity(0.12)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            Text(L10n.t("size.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    // MARK: - Debug (10× version tap)

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L10n.t("debug.title"))
            Text(L10n.t("debug.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L10n.t("debug.intensity"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                spacing: 8
            ) {
                ForEach(FirePreviewStyle.allCases) { style in
                    Button {
                        fire.showPreview(style)
                        debugIntensity = style.snapshot.intensity
                    } label: {
                        Text(style.label)
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(fire.previewStyle == style
                                          ? Color.orange.opacity(0.85)
                                          : Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(fire.previewStyle == style ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: "%.0f%%", debugIntensity * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("debug.live")) {
                        fire.returnToLive()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Slider(
                    value: Binding(
                        get: { debugIntensity },
                        set: { value in
                            debugIntensity = value
                            applyDebugIntensity(value)
                        }
                    ),
                    in: 0...1
                )
                .tint(.orange)
            }

            Text(L10n.t("debug.inject"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(UsageSimulator.Preset.allCases) { preset in
                    Button(preset.label) { simulator.add(preset) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Toggle(L10n.t("debug.autoBurn"), isOn: Binding(
                get: { simulator.autoBurnEnabled },
                set: { simulator.setAutoBurn($0) }
            ))
            Toggle(L10n.t("debug.pause"), isOn: $fire.animationPaused)

            Text(L10n.t("colors.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                spacing: 8
            ) {
                ForEach(UsageSource.allCases) { source in
                    Button {
                        editingColor = source
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SourceFlameColors.color(for: source))
                                .frame(width: 14, height: 14)
                            Text(source.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { editingColor == source },
                        set: { if !$0 { editingColor = nil } }
                    )) {
                        colorEditor(for: source)
                    }
                }
            }
            Button(L10n.t("colors.reset")) {
                SourceFlameColors.resetAll()
                colorDraftEpoch &+= 1
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 1.2 {
            versionTapCount = 0
        }
        lastVersionTap = now
        versionTapCount += 1
        if versionTapCount >= 10 {
            showDebug = true
            versionTapCount = 0
            debugIntensity = fire.snapshot.intensity
        }
    }

    private func applyDebugIntensity(_ value: Double) {
        fire.showCustomPreview(intensity: value)
    }

    // MARK: - Chrome

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private func statusChipColor(_ state: SourceConnectionState) -> Color {
        switch state {
        case .ok: return .green
        case .notFound: return .secondary
        case .noPermission, .readError: return .red
        case .unsupported: return .orange
        }
    }

    private func shortTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
    }
}

private struct ConsoleBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.orange.opacity(0.06),
                    Color.clear,
                    Color.blue.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
