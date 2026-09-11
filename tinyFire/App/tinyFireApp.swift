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
            // Flat menu + Environment(\.openWindow). Avoid Group/.id wrappers (they gray items out).
            MenuBarCommands(store: store)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .accessibilityLabel(L10n.t("app.name"))
                .background(OpenWindowBinder())
        }
        .menuBarExtraStyle(.menu)

        Window(L10n.t("console.title"), id: "prototype") {
            PrototypeControlsView(store: store)
                .environment(\.locale, languageStore.language.locale ?? .autoupdatingCurrent)
                .id(languageStore.revision)
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
                Toggle(L10n.t("sound.enabled"), isOn: Binding(
                    get: { store.audio.isEnabled },
                    set: { store.audio.isEnabled = $0 }
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

// MARK: - Menu bar

private struct MenuBarCommands: View {
    @ObservedObject var store: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(store.panel.isVisible ? L10n.t("menu.hideFlame") : L10n.t("menu.showFlame")) {
            store.panel.toggleVisible()
        }
        Button(L10n.t("menu.resetPosition")) {
            store.panel.resetPositionToDefault()
            store.igniteDemoFlameIfNeeded()
        }
        Button(L10n.t("menu.openConsole")) {
            ConsoleWindowOpener.open(using: openWindow)
        }
        Button(L10n.t("menu.checkUpdates")) {
            UpdateChecker.checkForUpdates()
        }
        Divider()
        Button(store.fire.animationPaused ? L10n.t("menu.resumeAnimation") : L10n.t("menu.pauseAnimation")) {
            store.fire.animationPaused.toggle()
        }
        Divider()
        Button(L10n.t("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}

/// Lives on the always-visible menu bar label so `openWindow` is bound at launch.
private struct OpenWindowBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { ConsoleWindowOpener.bind(openWindow) }
    }
}

// MARK: - Console window opening

@MainActor
enum ConsoleWindowOpener {
    private static var openWindowAction: ((String) -> Void)?

    static func bind(_ openWindow: OpenWindowAction) {
        openWindowAction = { id in
            openWindow(id: id)
        }
    }

    /// Opens or focuses the console. Prefers an explicit `openWindow` from a View.
    @discardableResult
    static func open(using openWindow: OpenWindowAction? = nil) -> Bool {
        // Menu-bar (accessory) apps need an explicit activation or SwiftUI windows
        // often never order front after the status-item menu dismisses.
        NSApp.activate(ignoringOtherApps: true)

        if let existing = usableConsoleWindow() {
            present(existing)
            return true
        }

        var didRequest = false
        if let openWindow {
            openWindow(id: "prototype")
            didRequest = true
        } else if let openWindowAction {
            openWindowAction("prototype")
            didRequest = true
        }

        guard didRequest else { return false }

        // SwiftUI creates the NSWindow asynchronously — chase it onto the screen.
        DispatchQueue.main.async {
            if let window = usableConsoleWindow() ?? findConsoleWindow() {
                present(window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let window = usableConsoleWindow() ?? findConsoleWindow() {
                present(window)
            }
        }
        return true
    }

    private static func present(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Windows SwiftUI left behind after close are still in `NSApp.windows`
    /// but not visible — reusing those makes "Open Console" look like a no-op.
    private static func usableConsoleWindow() -> NSWindow? {
        findConsoleWindow().flatMap { window in
            if window.isVisible || window.isMiniaturized { return window }
            return nil
        }
    }

    static func findConsoleWindow() -> NSWindow? {
        NSApp.windows.first { window in
            if window.identifier?.rawValue == "prototype" { return true }
            let title = window.title
            return title == "Console"
                || title == "控制台"
                || title == "コンソール"
                || title == "콘솔"
        }
    }
}

@MainActor
func openConsoleWindow() {
    ConsoleWindowOpener.open()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug + Release share the same bundle id. Two copies → two menu icons
        // and "Open Console" appears to do nothing when the other instance owns focus.
        if activateExistingInstanceIfNeeded() {
            return
        }

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

            // First-run: open console once MenuBarCommands has bound openWindow.
            if !store.hasOpenedPrototypeOnce {
                store.hasOpenedPrototypeOnce = true
                self.attemptFirstConsoleOpen(attempt: 0)
            }
        }
    }

    /// Returns true if this launch should abort (another TinyFire is already running).
    private func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        // Best-effort: Apple Events won't open our SwiftUI window; user can use the
        // already-running menu item. Just avoid a zombie second copy.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return true
    }

    private func attemptFirstConsoleOpen(attempt: Int) {
        if ConsoleWindowOpener.open() {
            return
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attemptFirstConsoleOpen(attempt: attempt + 1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
