//
//  UpdateChecker.swift
//  tinyFire
//
//  Sparkle-powered in-app updates (Release). Debug builds skip checks.
//

import AppKit
import Foundation
import Sparkle

@MainActor
enum UpdateChecker {
    private static var controller: SPUStandardUpdaterController?
    private static let userDriverDelegate = SparkleUserDriverDelegate()

    /// Start Sparkle automatic checks (once per process). No-op in Debug.
    static func checkOnLaunch() {
        #if DEBUG
        return
        #else
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriverDelegate
        )
        controller = c
        #endif
    }

    /// Menu / Console triggered check.
    static func checkForUpdates() {
        #if DEBUG
        let alert = NSAlert()
        alert.messageText = L10n.t("update.debugTitle")
        alert.informativeText = L10n.t("update.debugBody")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("update.later"))
        alert.runModal()
        #else
        if controller == nil {
            checkOnLaunch()
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
        #endif
    }
}

/// Menu-bar accessory apps need activation when Sparkle shows UI.
private final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Stay accessory; don't steal Dock permanent presence.
        NSApp.setActivationPolicy(.accessory)
    }
}
