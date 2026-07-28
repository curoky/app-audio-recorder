import OSLog

enum AppLog {
    private static let subsystem = "com.local.AppAudioRecorder"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
