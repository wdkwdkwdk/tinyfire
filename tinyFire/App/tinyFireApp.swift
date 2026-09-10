//
//  tinyFireApp.swift
//  tinyFire
//

import SwiftUI
import AppKit

@main
struct tinyFireApp: App {
    @StateObject private var store = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some Scene {
        MenuBarExtra {
            // Keep menu content flat — Group / .id / heavy modifiers can gray-out items.
            Button(store.panel.isVisible ? L10n.t("menu.hideFlame") : L10n.t("menu.showFlame")) {
                store.panel.toggleVisible()
            }
            Button(L10n.t("menu.resetPosition")) {
                store.panel.resetPositionToDefault()
                store.igniteDemoFlameIfNeeded()
            }
            Button(L10n.t("menu.openConsole")) {
                openConsoleWindow()
            }
            Divider()
            Button(store.fire.animationPaused ? L10n.t("menu.resumeAnimation") : L10n.t("menu.pauseAnimation")) {
                store.fire.animationPaused.toggle()
            }
            Divider()
            Button(L10n.t("menu.quit")) {
                NSApp.terminate(nil)
            }
        } label: {
            Image("MenuBarIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .accessibilityLabel(L10n.t("app.name"))
        }
        .menuBarExtraStyle(.menu)

        Window(L10n.t("console.title"), id: "prototype") {
            PrototypeControlsView(store: store)
                .environment(\.locale, languageStore.language.locale ?? .autoupdatingCurrent)
                .id(languageStore.revision)
                .background(ConsoleOpenBridge(store: store))
        }
        .defaultSize(width: 460, height: 720)

        Settings {
            Form {
                Picker(L10n.t("language"), selection: Binding(
                    get: { languageStore.language },
                    set: { languageStore.set($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(localizedPickerLabel(lang)).tag(lang)
                    }
                }
                Toggle(L10n.t("settings.reduceMotion"), isOn: Binding(
                    get: { store.fire.reduceMotion },
                    set: { store.fire.reduceMotion = $0 }
                ))
                Text(L10n.t("settings.privacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 380)
            .environment(\.locale, languageStore.language.locale ?? .autoupdatingCurrent)
            .id(languageStore.revision)
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
}

@MainActor
func openConsoleWindow() {
    NSApp.activate(ignoringOtherApps: true)
    // Prefer existing console window; otherwise ask SwiftUI to open it.
    if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "prototype" || $0.title.contains("Console") || $0.title.contains("控制台") || $0.title.contains("コンソール") || $0.title.contains("콘솔") }) {
        existing.makeKeyAndOrderFront(nil)
        return
    }
    NotificationCenter.default.post(name: .openTinyFireConsole, object: nil)
}

extension Notification.Name {
    static let openTinyFireConsole = Notification.Name("tinyFire.openConsole")
}

/// Bridges notification → SwiftUI openWindow for MenuBarExtra (no Environment needed).
private struct ConsoleOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openTinyFireConsole)) { _ in
                openWindow(id: "prototype")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onAppear {
                if !store.hasOpenedPrototypeOnce {
                    store.hasOpenedPrototypeOnce = true
                    openWindow(id: "prototype")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Clear a previously saved off-screen origin from early prototypes.
        if let saved = UserDefaults.standard.string(forKey: "flame.panel.origin"),
           saved.contains("1010") || saved.hasPrefix("1476") {
            UserDefaults.standard.removeObject(forKey: "flame.panel.origin")
        }

        // Default language is English unless the user already chose.
        if UserDefaults.standard.object(forKey: "app.language") == nil {
            AppLanguage.current = .english
        }

        DispatchQueue.main.async {
            guard let store = AppModel.sharedOptional else { return }
            store.panel.bootstrap(store: store)
            store.startDataPipeline()
            store.panel.showFront()
            UpdateChecker.checkOnLaunch()
            // Open console once via notification after scenes are ready.
            if !store.hasOpenedPrototypeOnce {
                store.hasOpenedPrototypeOnce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .openTinyFireConsole, object: nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
