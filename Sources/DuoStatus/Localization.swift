import Foundation

/// Languages the app ships with. Adding one means adding a `Strings` table below
/// and a case here — nothing else.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case chineseSimplified = "zh-Hans"

    /// Shown in its own language, the way macOS lists languages.
    var menuTitle: String {
        switch self {
        case .system:            return L.strings.followSystem
        case .english:           return "English"
        case .chineseSimplified: return "简体中文"
        }
    }
}

/// Current language and the active string table.
///
/// Runtime switching is a requirement, so this is a plain in-process table rather
/// than `NSLocalizedString` + `.lproj` — swapping the bundle underneath Foundation
/// to re-localize on the fly is a hack, and the app only has ~30 strings.
enum L {
    private static let key = "language"

    static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
            }
        }
    }

    /// `.system` resolved against the user's preferred languages.
    static var resolved: AppLanguage {
        guard language == .system else { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chineseSimplified : .english
    }

    static var strings: Strings {
        resolved == .chineseSimplified ? .chineseSimplified : .english
    }
}

/// Every user-visible string. Formatted ones are closures so the call sites stay
/// type-safe — no string keys to mistype.
struct Strings {
    // Section headers
    let battery: String
    let network: String
    let sound: String

    // Battery
    let health: (Int) -> String
    let cycles: (Int) -> String
    let lowPowerMode: String
    let charging: (Double) -> String
    let powerConnected: String
    let onBattery: (Int, Int) -> String
    let onBatteryEstimating: String

    // Network
    let notConnected: String
    let wifiOff: String
    let ethernet: String
    let cellular: String
    let connected: String
    let noInternet: String
    let noResponse: String
    let measuring: String

    // Sound
    let volumeUnavailable: String
    let muted: String
    let output: String
    let input: String

    // Commands
    let language: String
    let followSystem: String
    let openAtLogin: String
    let quit: String
    let loginItemFailed: String

    /// Longest plausible text of each row, used to pin the panel width so the
    /// numbers changing length don't make it jump. Per language: the widest row
    /// differs between them.
    let widthSamples: [String]
}

extension Strings {
    static let english = Strings(
        battery: "Battery",
        network: "Network",
        sound: "Sound",
        health: { "Health \($0)%" },
        cycles: { "\($0) cycles" },
        lowPowerMode: "Low Power Mode",
        charging: { String(format: "%.1fW charging", $0) },
        powerConnected: "Power connected",
        onBattery: { String(format: "On battery · %d:%02d left", $0, $1) },
        onBatteryEstimating: "On battery · estimating",
        notConnected: "Not connected",
        wifiOff: "Wi-Fi off",
        ethernet: "Ethernet",
        cellular: "Cellular",
        connected: "Connected",
        noInternet: "No internet",
        noResponse: " · No response",
        measuring: " · Measuring",
        volumeUnavailable: "Volume not adjustable here",
        muted: "Muted",
        output: "Output",
        input: "Input",
        language: "Language",
        followSystem: "System",
        openAtLogin: "Open at Login",
        quit: "Quit DuoStatus",
        loginItemFailed: "Couldn't change the login item",
        widthSamples: [
            "100% · Health 100% · 9999 cycles",
            "140W · 20V 5.00A · 99.9W charging",
            "On battery · 23:59 left",
            "↓1250 ↑1250 MB/s · 999ms · 100%",
        ]
    )

    static let chineseSimplified = Strings(
        battery: "电池",
        network: "网络",
        sound: "声音",
        health: { "健康度 \($0)%" },
        cycles: { "循环 \($0) 次" },
        lowPowerMode: "低电量模式",
        charging: { String(format: "%.1fW 充电中", $0) },
        powerConnected: "电源已接通",
        onBattery: { String(format: "电池供电 · 预计剩余 %d:%02d", $0, $1) },
        onBatteryEstimating: "电池供电 · 剩余时间计算中",
        notConnected: "未连接",
        wifiOff: "Wi-Fi 已关闭",
        ethernet: "以太网",
        cellular: "蜂窝数据",
        connected: "已连接",
        noInternet: "无法连接",
        noResponse: " · 无响应",
        measuring: " · 测量中",
        volumeUnavailable: "当前设备不支持音量控制",
        muted: "已静音",
        output: "输出",
        input: "输入",
        language: "语言",
        followSystem: "跟随系统",
        openAtLogin: "登录时启动",
        quit: "退出 DuoStatus",
        loginItemFailed: "无法修改登录项",
        widthSamples: [
            "100% · 健康度 100% · 循环 9999 次",
            "140W · 20V 5.00A · 99.9W 充电中",
            "电池供电 · 预计剩余 23:59",
            "↓1250 ↑1250 MB/s · 999ms · 100%",
        ]
    )
}
