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
    let audio = FireplaceAudioController()

    @Published var hasOpenedPrototypeOnce: Bool = false
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "onboarding.done")

    private var cancellables = Set<AnyCancellable>()

    init() {
        Self.sharedOptional = self
        simulator.attach(fire: fire)
        monitor.attach(fire: fire)
        fire.start()
        audio.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Panel + monitor + audio start in AppDelegate after NSApp is ready.
    }

    func startDataPipeline() {
        monitor.start()
        audio.start()
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
