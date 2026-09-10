//
//  UsageSimulator.swift
//  tinyFire
//
//  Prototype-only token inflow generator. No real logs yet.
//

import Foundation
import Combine

@MainActor
final class UsageSimulator: ObservableObject {
    @Published private(set) var todayTokens: Int = 0
    @Published private(set) var lastEventTokens: Int = 0
    @Published private(set) var lastEventAt: Date?
    @Published var autoBurnEnabled: Bool = false

    private weak var fire: FireStateMachine?
    private var autoTimer: Timer?

    enum Preset: String, CaseIterable, Identifiable {
        case low, medium, high, surge

        var id: String { rawValue }

        var label: String {
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            case .surge: return "爆发"
            }
        }

        var tokens: Double {
            switch self {
            case .low: return 2_500
            case .medium: return 12_000
            case .high: return 45_000
            case .surge: return 180_000
            }
        }
    }

    func attach(fire: FireStateMachine) {
        self.fire = fire
    }

    func add(_ preset: Preset) {
        ingest(tokens: preset.tokens)
    }

    func ingest(tokens: Double) {
        guard tokens > 0, let fire else { return }
        todayTokens += Int(tokens.rounded())
        lastEventTokens = Int(tokens.rounded())
        lastEventAt = .now
        fire.ingest(tokens: tokens, animate: true)
    }

    func setAutoBurn(_ enabled: Bool) {
        autoBurnEnabled = enabled
        autoTimer?.invalidate()
        autoTimer = nil
        guard enabled else { return }

        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.add(.low)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    func resetDay() {
        todayTokens = 0
        lastEventTokens = 0
        lastEventAt = nil
        fire?.resetToUnlit()
    }
}
