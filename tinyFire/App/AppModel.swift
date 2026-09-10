//
//  AppModel.swift
//  tinyFire
//

import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    static private(set) var sharedOptional: AppModel?

    let fire = FireStateMachine()
    let simulator = UsageSimulator()
    let monitor = UsageMonitor()
    let panel = FlamePanelController.shared

    @Published var hasOpenedPrototypeOnce: Bool = false
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "onboarding.done")

    init() {
        Self.sharedOptional = self
        simulator.attach(fire: fire)
        monitor.attach(fire: fire)
        fire.start()
        // Panel + monitor start in AppDelegate after NSApp is ready.
    }

    func startDataPipeline() {
        monitor.start()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "onboarding.done")
    }

    /// Manual spark only when no real sources are producing heat.
    func igniteDemoFlameIfNeeded() {
        guard fire.snapshot.phase == .unlit || fire.snapshot.phase == .out else { return }
        simulator.add(.medium)
    }
}
