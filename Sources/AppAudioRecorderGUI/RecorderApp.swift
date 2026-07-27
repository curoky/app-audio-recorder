import AppKit
import Logging
import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
    }

    var body: some Scene {
        WindowGroup("App Audio Recorder") {
            RecorderView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RecorderModel()
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isActive else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
