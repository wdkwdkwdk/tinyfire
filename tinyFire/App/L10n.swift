//
//  L10n.swift
//  tinyFire
//
//  Forced language catalogs — Bundle locale alone is unreliable on macOS.
//

import Foundation
import SwiftUI
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese
    case japanese
    case korean

    var id: String { rawValue }

    /// Stable picker labels (do not depend on current UI language).
    var pickerLabel: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .english: return Locale(identifier: "en")
        case .chinese: return Locale(identifier: "zh-Hans")
        case .japanese: return Locale(identifier: "ja")
        case .korean: return Locale(identifier: "ko")
        }
    }

    /// Notes key for update API payload.
    static var notesKey: String {
        switch effective {
        case .chinese: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .english, .system: return "en"
        }
    }

    static var current: AppLanguage {
        get {
            AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "") ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "app.language")
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    /// Effective language for copy.
    static var effective: AppLanguage {
        switch current {
        case .english, .chinese, .japanese, .korean:
            return current
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            if pref.hasPrefix("zh") { return .chinese }
            if pref.hasPrefix("ja") { return .japanese }
            if pref.hasPrefix("ko") { return .korean }
            return .english
        }
    }

    static var resolvedLocale: Locale {
        switch effective {
        case .chinese: return Locale(identifier: "zh-Hans")
        case .japanese: return Locale(identifier: "ja")
        case .korean: return Locale(identifier: "ko")
        case .english, .system: return Locale(identifier: "en")
        }
    }
}

/// Single source of truth for UI language.
@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    @Published private(set) var language: AppLanguage
    @Published private(set) var revision: Int = 0

    private var bag = Set<AnyCancellable>()

    private init() {
        language = AppLanguage.current
        NotificationCenter.default.publisher(for: .appLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFromDefaults()
            }
            .store(in: &bag)
    }

    func set(_ language: AppLanguage) {
        guard language != self.language else { return }
        AppLanguage.current = language
        self.language = language
        revision &+= 1
    }

    private func syncFromDefaults() {
        let next = AppLanguage.current
        if next != language {
            language = next
        }
        revision &+= 1
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("tinyFire.appLanguageDidChange")
}

enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var display: String {
        "\(short) (\(build))"
    }
}

enum L10n {
    static func t(_ key: String) -> String {
        let table: [String: String]
        switch AppLanguage.effective {
        case .chinese: table = zh
        case .japanese: table = ja
        case .korean: table = ko
        case .english, .system: table = en
        }
        return table[key] ?? en[key] ?? key
    }

    // MARK: - English (default)

    private static let en: [String: String] = [
        "app.name": "TinyFire",
        "app.tagline": "If you're burning tokens anyway, light a real fire.",
        "console.title": "Console",
        "console.footnote": "Local usage logs only — nothing is uploaded.",
        "console.version": "Version %@",
        "debug.title": "Debug",
        "debug.hint": "Force flame look. Closing Console hides this again.",
        "debug.live": "Live",
        "debug.inject": "Inject tokens",
        "debug.autoBurn": "Auto burn",
        "debug.pause": "Pause animation",
        "debug.intensity": "Force intensity",
        "language": "Language",
        "language.system": "System",
        "language.english": "English",
        "language.chinese": "中文",
        "language.japanese": "日本語",
        "language.korean": "한국어",
        "sources.title": "Sources",
        "sources.rescan": "Rescan",
        "sources.last": "Latest: %@ %@",
        "source.state.ok": "Connected",
        "source.state.notFound": "Not found",
        "source.state.noPermission": "No permission",
        "source.state.unsupported": "Unsupported",
        "source.state.readError": "Read error",
        "colors.title": "Flame colors",
        "colors.reset": "Reset",
        "colors.mix.empty": "Classic orange — waiting for live usage",
        "colors.mix.active": "Live mix",
        "stats.title": "Today",
        "stats.total": "Total",
        "stats.bySource": "By tool",
        "stats.hourly": "Through the day",
        "stats.breakdown": "Where tokens went",
        "stats.input": "Input",
        "stats.output": "Output",
        "stats.cacheRead": "Cache read",
        "stats.cacheWrite": "Cache write",
        "stats.other": "Other / estimated",
        "stats.empty": "No usage recorded yet today.",
        "stats.tier": "Flame",
        "size.title": "Flame size",
        "size.small": "S",
        "size.medium": "M",
        "size.large": "L",
        "size.hint": "Scales the desktop campfire, not just the window.",
        "menu.hideFlame": "Hide Flame",
        "menu.showFlame": "Show Flame",
        "menu.resetPosition": "Reset Position",
        "menu.openConsole": "Open Console",
        "menu.pauseAnimation": "Pause Animation",
        "menu.resumeAnimation": "Resume Animation",
        "menu.quit": "Quit TinyFire",
        "settings.reduceMotion": "Reduce motion",
        "settings.privacy": "Reads local Codex, Claude Code, Cursor, Grok, Pi, and Amp usage. Nothing is uploaded.",
        "tier.hush": "Hush",
        "tier.glow": "Glow",
        "tier.crackle": "Crackle",
        "tier.roar": "Roar",
        "tier.blaze": "Blaze",
        "phase.unlit": "Unlit",
        "phase.flame": "Flame",
        "phase.ember": "Ember",
        "phase.out": "Out",
        "hover.tokens": "tokens",
        "hover.intensity": "Heat",
        "hover.fuel": "Fuel",
        "hover.estimated": "est.",
        "hover.updated": "Updated %@",
        "update.title": "Update Available",
        "update.message": "TinyFire %@ is available.\nYou have %@.\n\n%@",
        "update.later": "Later",
        "update.download": "Download",
    ]

    // MARK: - Chinese

    private static let zh: [String: String] = [
        "app.name": "TinyFire",
        "app.tagline": "既然都在烧 token，不如真的生一把火。",
        "console.title": "控制台",
        "console.footnote": "仅读取本机用量日志，不上传。",
        "console.version": "版本 %@",
        "debug.title": "调试",
        "debug.hint": "强制预览火势。关闭控制台后再次打开会重新隐藏。",
        "debug.live": "恢复实时",
        "debug.inject": "注入用量",
        "debug.autoBurn": "自动添柴",
        "debug.pause": "暂停动画",
        "debug.intensity": "强制火势",
        "language": "语言",
        "language.system": "跟随系统",
        "language.english": "English",
        "language.chinese": "中文",
        "language.japanese": "日本語",
        "language.korean": "한국어",
        "sources.title": "数据源",
        "sources.rescan": "重新扫描",
        "sources.last": "最近：%@ %@",
        "source.state.ok": "正常",
        "source.state.notFound": "未发现",
        "source.state.noPermission": "无权限",
        "source.state.unsupported": "格式不支持",
        "source.state.readError": "读取异常",
        "colors.title": "火焰颜色",
        "colors.reset": "恢复默认",
        "colors.mix.empty": "经典橙火 — 尚无实时比例",
        "colors.mix.active": "实时燃烧比例",
        "stats.title": "今日",
        "stats.total": "总量",
        "stats.bySource": "按工具",
        "stats.hourly": "今日节奏",
        "stats.breakdown": "用量去向",
        "stats.input": "输入",
        "stats.output": "输出",
        "stats.cacheRead": "缓存读",
        "stats.cacheWrite": "缓存写",
        "stats.other": "其他 / 估算",
        "stats.empty": "今天还没有用量记录。",
        "stats.tier": "火焰",
        "size.title": "火焰尺寸",
        "size.small": "小",
        "size.medium": "中",
        "size.large": "大",
        "size.hint": "会真正缩放桌面篝火，不只改窗口。",
        "menu.hideFlame": "隐藏火焰",
        "menu.showFlame": "显示火焰",
        "menu.resetPosition": "重置到右下角",
        "menu.openConsole": "打开控制台",
        "menu.pauseAnimation": "暂停动画",
        "menu.resumeAnimation": "恢复动画",
        "menu.quit": "退出 TinyFire",
        "settings.reduceMotion": "减少动态效果",
        "settings.privacy": "读取本机 Codex / Claude Code / Cursor / Grok / Pi / Amp 用量；不上传。",
        "tier.hush": "微火",
        "tier.glow": "小火",
        "tier.crackle": "中火",
        "tier.roar": "旺火",
        "tier.blaze": "烈火",
        "phase.unlit": "未点燃",
        "phase.flame": "明火",
        "phase.ember": "余烬",
        "phase.out": "已熄灭",
        "hover.tokens": "tokens",
        "hover.intensity": "火势",
        "hover.fuel": "燃料",
        "hover.estimated": "估",
        "hover.updated": "%@ 更新",
        "update.title": "发现新版本",
        "update.message": "TinyFire %@ 已发布。\n当前版本 %@。\n\n%@",
        "update.later": "稍后",
        "update.download": "去下载",
    ]

    // MARK: - Japanese

    private static let ja: [String: String] = [
        "app.name": "TinyFire",
        "app.tagline": "どうせトークンを燃やすなら、本物の火を灯そう。",
        "console.title": "コンソール",
        "console.footnote": "ローカルの利用ログのみ読み取ります。アップロードしません。",
        "console.version": "バージョン %@",
        "debug.title": "デバッグ",
        "debug.hint": "炎を強制プレビュー。コンソールを閉じると再表示時は隠れます。",
        "debug.live": "ライブに戻す",
        "debug.inject": "トークン注入",
        "debug.autoBurn": "自動燃焼",
        "debug.pause": "アニメ一時停止",
        "debug.intensity": "強制火勢",
        "language": "言語",
        "language.system": "システム",
        "language.english": "English",
        "language.chinese": "中文",
        "language.japanese": "日本語",
        "language.korean": "한국어",
        "sources.title": "データソース",
        "sources.rescan": "再スキャン",
        "sources.last": "最新: %@ %@",
        "source.state.ok": "接続済み",
        "source.state.notFound": "未検出",
        "source.state.noPermission": "権限なし",
        "source.state.unsupported": "非対応",
        "source.state.readError": "読み取りエラー",
        "colors.title": "炎の色",
        "colors.reset": "リセット",
        "colors.mix.empty": "クラシック橙 — 利用データ待ち",
        "colors.mix.active": "ライブ混合",
        "stats.title": "今日",
        "stats.total": "合計",
        "stats.bySource": "ツール別",
        "stats.hourly": "一日の推移",
        "stats.breakdown": "トークンの内訳",
        "stats.input": "入力",
        "stats.output": "出力",
        "stats.cacheRead": "キャッシュ読取",
        "stats.cacheWrite": "キャッシュ書込",
        "stats.other": "その他 / 推定",
        "stats.empty": "今日の利用はまだありません。",
        "stats.tier": "炎",
        "size.title": "炎のサイズ",
        "size.small": "S",
        "size.medium": "M",
        "size.large": "L",
        "size.hint": "ウィンドウだけでなく、デスクトップの焚き火自体を拡大縮小します。",
        "menu.hideFlame": "炎を隠す",
        "menu.showFlame": "炎を表示",
        "menu.resetPosition": "位置をリセット",
        "menu.openConsole": "コンソールを開く",
        "menu.pauseAnimation": "アニメ一時停止",
        "menu.resumeAnimation": "アニメ再開",
        "menu.quit": "TinyFire を終了",
        "settings.reduceMotion": "動きを減らす",
        "settings.privacy": "Codex / Claude Code / Cursor / Grok / Pi / Amp のローカル利用を読み取ります。アップロードしません。",
        "tier.hush": "静火",
        "tier.glow": "ほのか",
        "tier.crackle": "ぱちぱち",
        "tier.roar": "ごうごう",
        "tier.blaze": "烈火",
        "phase.unlit": "未点火",
        "phase.flame": "炎",
        "phase.ember": "残り火",
        "phase.out": "消火",
        "hover.tokens": "tokens",
        "hover.intensity": "熱量",
        "hover.fuel": "燃料",
        "hover.estimated": "推定",
        "hover.updated": "%@ 更新",
        "update.title": "アップデートがあります",
        "update.message": "TinyFire %@ が利用可能です。\n現在のバージョンは %@ です。\n\n%@",
        "update.later": "あとで",
        "update.download": "ダウンロード",
    ]

    // MARK: - Korean

    private static let ko: [String: String] = [
        "app.name": "TinyFire",
        "app.tagline": "어차피 토큰을 태울 거라면, 진짜 불을 피우자.",
        "console.title": "콘솔",
        "console.footnote": "로컬 사용 로그만 읽습니다. 업로드하지 않습니다.",
        "console.version": "버전 %@",
        "debug.title": "디버그",
        "debug.hint": "불꽃을 강제 미리보기. 콘솔을 닫으면 다시 열 때 숨겨집니다.",
        "debug.live": "실시간으로",
        "debug.inject": "토큰 주입",
        "debug.autoBurn": "자동 연소",
        "debug.pause": "애니메이션 일시정지",
        "debug.intensity": "강제 세기",
        "language": "언어",
        "language.system": "시스템",
        "language.english": "English",
        "language.chinese": "中文",
        "language.japanese": "日本語",
        "language.korean": "한국어",
        "sources.title": "데이터 소스",
        "sources.rescan": "다시 스캔",
        "sources.last": "최근: %@ %@",
        "source.state.ok": "연결됨",
        "source.state.notFound": "없음",
        "source.state.noPermission": "권한 없음",
        "source.state.unsupported": "지원 안 함",
        "source.state.readError": "읽기 오류",
        "colors.title": "불꽃 색",
        "colors.reset": "초기화",
        "colors.mix.empty": "클래식 오렌지 — 사용량 대기 중",
        "colors.mix.active": "실시간 혼합",
        "stats.title": "오늘",
        "stats.total": "합계",
        "stats.bySource": "도구별",
        "stats.hourly": "하루 흐름",
        "stats.breakdown": "토큰 구성",
        "stats.input": "입력",
        "stats.output": "출력",
        "stats.cacheRead": "캐시 읽기",
        "stats.cacheWrite": "캐시 쓰기",
        "stats.other": "기타 / 추정",
        "stats.empty": "오늘 아직 사용량이 없습니다.",
        "stats.tier": "불꽃",
        "size.title": "불꽃 크기",
        "size.small": "S",
        "size.medium": "M",
        "size.large": "L",
        "size.hint": "창만이 아니라 데스크톱 캠프파이어 자체를 확대·축소합니다.",
        "menu.hideFlame": "불꽃 숨기기",
        "menu.showFlame": "불꽃 보이기",
        "menu.resetPosition": "위치 초기화",
        "menu.openConsole": "콘솔 열기",
        "menu.pauseAnimation": "애니메이션 일시정지",
        "menu.resumeAnimation": "애니메이션 재개",
        "menu.quit": "TinyFire 종료",
        "settings.reduceMotion": "움직임 줄이기",
        "settings.privacy": "Codex / Claude Code / Cursor / Grok / Pi / Amp 로컬 사용량을 읽습니다. 업로드하지 않습니다.",
        "tier.hush": "고요",
        "tier.glow": "은은",
        "tier.crackle": "타닥",
        "tier.roar": "활활",
        "tier.blaze": "맹렬",
        "phase.unlit": "미점화",
        "phase.flame": "불꽃",
        "phase.ember": "잔불",
        "phase.out": "꺼짐",
        "hover.tokens": "tokens",
        "hover.intensity": "열기",
        "hover.fuel": "연료",
        "hover.estimated": "추정",
        "hover.updated": "%@ 업데이트",
        "update.title": "업데이트 가능",
        "update.message": "TinyFire %@ 을(를) 사용할 수 있습니다.\n현재 버전은 %@ 입니다.\n\n%@",
        "update.later": "나중에",
        "update.download": "다운로드",
    ]
}
