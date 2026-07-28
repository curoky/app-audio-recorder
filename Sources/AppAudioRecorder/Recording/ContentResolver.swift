import Foundation
import ScreenCaptureKit

/// 封装 ScreenCaptureKit 的可共享内容查询与按 app 过滤器构建。
enum ContentResolver {
    /// 获取可共享内容；把权限相关错误统一转成友好错误。
    static func shareableContent() async throws(RecorderError) -> SCShareableContent {
        do {
            // onScreenWindowsOnly=false，尽量把后台运行的 app 也纳入。
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            // ScreenCaptureKit 在无权限时抛出的错误，统一转成权限提示。
            throw .screenRecordingPermissionDenied
        }
    }

    /// 列出可捕获音频的运行中 app（按名称排序、去重）。
    static func runningApps() async throws(RecorderError) -> [SCRunningApplication] {
        let content = try await shareableContent()
        let applications = content.applications
            .filter { !$0.applicationName.isEmpty && !$0.bundleIdentifier.isEmpty }

        var appByRootBundleIdentifier: [String: SCRunningApplication] = [:]
        for application in applications {
            let matcher = ApplicationBundleMatcher(
                targetBundleIdentifier: application.bundleIdentifier
            )
            let root = matcher.rootBundleIdentifier
            if let current = appByRootBundleIdentifier[root] {
                if application.bundleIdentifier == root,
                    current.bundleIdentifier != root
                {
                    appByRootBundleIdentifier[root] = application
                }
            } else {
                appByRootBundleIdentifier[root] = application
            }
        }

        return appByRootBundleIdentifier.values
            .sorted {
                $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
            }
    }

    /// 重新获取所选 app 的当前进程；已适配 app 同时接受其 helper 进程。
    static func findApp(
        bundleIdentifier: String
    ) async throws(RecorderError) -> SCRunningApplication {
        let apps = try await runningApps()
        guard !apps.isEmpty else { throw .noAppsAvailable }

        if let exact = apps.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            return exact
        }
        let matcher = ApplicationBundleMatcher(
            targetBundleIdentifier: bundleIdentifier
        )
        if let byFamily = apps.first(where: {
            matcher.belongsToSameFamily(as: $0.bundleIdentifier)
        }) {
            return byFamily
        }
        throw .applicationNotRunning(bundleIdentifier: bundleIdentifier)
    }

    /// 为指定 app 构建「只包含该 app 音频」的过滤器。
    static func filter(for app: SCRunningApplication) async throws(RecorderError) -> SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first else {
            throw .screenRecordingPermissionDenied
        }
        let matcher = ApplicationBundleMatcher(targetBundleIdentifier: app.bundleIdentifier)
        let matchingApplications = content.applications.filter {
            matcher.matches($0.bundleIdentifier)
        }
        // Signal 等 app 的音频可能由 helper 进程承载，过滤器需要包含整个已知 app 家族。
        return SCContentFilter(
            display: display,
            including: matchingApplications.isEmpty ? [app] : matchingApplications,
            exceptingWindows: []
        )
    }
}
