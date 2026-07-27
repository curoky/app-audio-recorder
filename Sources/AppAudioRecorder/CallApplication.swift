enum CallApplication: String, CaseIterable, Sendable {
    case weChat
    case lark
    case signal
    case whatsApp
    case telegram

    var displayName: String {
        switch self {
        case .weChat:
            "微信"
        case .lark:
            "Lark"
        case .signal:
            "Signal"
        case .whatsApp:
            "WhatsApp"
        case .telegram:
            "Telegram"
        }
    }

    var primaryBundleIdentifier: String {
        bundleIdentifiers[0]
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .weChat:
            ["com.tencent.xinWeChat"]
        case .lark:
            [
                "com.larksuite.macos.lark",
                "com.electron.lark",
            ]
        case .signal:
            ["org.whispersystems.signal-desktop"]
        case .whatsApp:
            ["net.whatsapp.WhatsApp"]
        case .telegram:
            [
                "ru.keepcoder.Telegram",
                "org.telegram.desktop",
            ]
        }
    }

    static func matching(bundleIdentifier: String) -> Self? {
        allCases.first { $0.rootBundleIdentifier(for: bundleIdentifier) != nil }
    }

    func rootBundleIdentifier(for bundleIdentifier: String) -> String? {
        bundleIdentifiers.first {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix("\($0).")
        }
    }
}

/// 把已适配通信 app 的 helper/扩展进程归到所选主 app；普通 app 仍保持精确匹配。
struct ApplicationBundleMatcher: Sendable {
    let rootBundleIdentifier: String
    private let includesDescendantBundles: Bool

    init(targetBundleIdentifier: String) {
        if let application = CallApplication.matching(bundleIdentifier: targetBundleIdentifier),
            let root = application.rootBundleIdentifier(for: targetBundleIdentifier)
        {
            rootBundleIdentifier = root
            includesDescendantBundles = true
        } else {
            rootBundleIdentifier = targetBundleIdentifier
            includesDescendantBundles = false
        }
    }

    func matches(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == rootBundleIdentifier
            || (includesDescendantBundles
                && bundleIdentifier.hasPrefix("\(rootBundleIdentifier)."))
    }

    func belongsToSameFamily(as bundleIdentifier: String) -> Bool {
        rootBundleIdentifier
            == ApplicationBundleMatcher(
                targetBundleIdentifier: bundleIdentifier
            ).rootBundleIdentifier
    }
}
