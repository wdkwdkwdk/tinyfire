//
//  UsageEvent.swift
//  tinyFire
//

import Foundation

enum UsageSource: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude_code"
    case codex = "codex"
    case cursor = "cursor"
    case grok = "grok"
    case pi = "pi"
    case amp = "amp"

    var id: String { rawValue }

    /// Stable English product names (not localized).
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .pi: return "Pi"
        case .amp: return "Amp"
        }
    }
}

enum SourceConnectionState: String {
    case ok
    case notFound
    case noPermission
    case unsupported
    case readError

    var labelKey: String {
        switch self {
        case .ok: return "source.state.ok"
        case .notFound: return "source.state.notFound"
        case .noPermission: return "source.state.noPermission"
        case .unsupported: return "source.state.unsupported"
        case .readError: return "source.state.readError"
        }
    }

    var label: String { L10n.t(labelKey) }
}

struct UsageBreakdown: Equatable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?

    var billableTotal: Int {
        (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }
}

struct UsageEvent: Identifiable, Equatable {
    let id: String
    let source: UsageSource
    let timestamp: Date
    let tokens: Int
    let breakdown: UsageBreakdown
    let filePath: String
    var isEstimated: Bool = false
}

struct SourceStatus: Equatable {
    var source: UsageSource
    var state: SourceConnectionState
    var detail: String
    var lastReadAt: Date?
    var todayTokens: Int
}

struct HourlyUsage: Identifiable, Equatable {
    var id: Int { hour }
    var hour: Int
    var tokens: Int
}

struct BreakdownSlice: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var tokens: Int
    var colorKey: String
}
