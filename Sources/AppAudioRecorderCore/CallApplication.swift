public enum CallApplication: String, CaseIterable, Sendable {
    case weChat
    case signal
    case whatsApp
    case telegram

    public var displayName: String {
        switch self {
        case .weChat:
            "微信"
        case .signal:
            "Signal"
        case .whatsApp:
            "WhatsApp"
        case .telegram:
            "Telegram"
        }
    }

    public var primaryBundleIdentifier: String {
        bundleIdentifiers[0]
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .weChat:
            ["com.tencent.xinWeChat"]
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

    public static func matching(bundleIdentifier: String) -> Self? {
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
