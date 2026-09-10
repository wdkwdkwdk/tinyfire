//
//  UpdateChecker.swift
//  tinyFire
//
//  On each launch, ask the Cloudflare Worker for the latest version.
//  If newer, show an alert once for this process lifetime.
//

import AppKit
import Foundation

struct RemoteVersionInfo: Decodable {
    var version: String
    var build: Int?
    var downloadURL: String?
    var notes: [String: String]?
}

enum UpdateChecker {
    /// Prefer `TINYFIRE_UPDATE_URL`, else local `UpdateEndpoint.plist` (gitignored).
    static var endpoint: URL? {
        if let env = ProcessInfo.processInfo.environment["TINYFIRE_UPDATE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty,
           let url = URL(string: env) {
            return url
        }
        if let plistURL = Bundle.main.url(forResource: "UpdateEndpoint", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
           let raw = dict["url"] as? String,
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return nil
    }

    @MainActor
    private static var didPromptThisLaunch = false

    @MainActor
    static func checkOnLaunch() {
        guard endpoint != nil else { return }
        guard !didPromptThisLaunch else { return }
        Task.detached(priority: .utility) {
            guard let info = await fetchRemote() else { return }
            await MainActor.run {
                presentIfNeeded(info)
            }
        }
    }

    private static func fetchRemote() async -> RemoteVersionInfo? {
        guard let endpoint else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TinyFire/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(RemoteVersionInfo.self, from: data)
        } catch {
            return nil
        }
    }

    @MainActor
    private static func presentIfNeeded(_ info: RemoteVersionInfo) {
        guard !didPromptThisLaunch else { return }
        guard isRemoteNewer(info) else { return }
        didPromptThisLaunch = true

        let notesKey = AppLanguage.notesKey
        let notes =
            info.notes?[notesKey]
            ?? info.notes?["en"]
            ?? ""

        let alert = NSAlert()
        alert.messageText = L10n.t("update.title")
        alert.informativeText = String(
            format: L10n.t("update.message"),
            info.version,
            AppVersion.display,
            notes
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("update.download"))
        alert.addButton(withTitle: L10n.t("update.later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let raw = info.downloadURL,
           let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Prefer marketing version; fall back to build number when versions equal.
    static func isRemoteNewer(_ info: RemoteVersionInfo) -> Bool {
        let local = AppVersion.short
        let remote = info.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmp = compareVersions(remote, local)
        if cmp == .orderedDescending { return true }
        if cmp == .orderedAscending { return false }
        guard let remoteBuild = info.build,
              let localBuild = Int(AppVersion.build)
        else { return false }
        return remoteBuild > localBuild
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").compactMap { Int($0) }
        let right = b.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for i in 0..<count {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }
}
