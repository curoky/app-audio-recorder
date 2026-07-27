import Foundation

extension URL {
    /// 返回目录中尚不存在的文件路径；冲突时依次追加 `-2`、`-3`。
    static func uniqueFile(
        in directory: URL,
        stem: String,
        pathExtension: String,
        fileManager: FileManager = .default
    ) -> URL {
        var suffix = 1
        while true {
            let name = suffix == 1 ? stem : "\(stem)-\(suffix)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}

enum RecordingFiles {
    static func validateOutputDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            fileManager.isWritableFile(atPath: directory.path)
        else {
            throw RecorderError.outputNotWritable(path: directory.path)
        }
    }

    static func uniqueContainerURL(
        applicationName: String,
        in directory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeName = applicationName.replacingOccurrences(of: "/", with: "-")
        return URL.uniqueFile(
            in: directory,
            stem: "\(safeName)-\(formatter.string(from: date))",
            pathExtension: "m4a",
            fileManager: fileManager
        )
    }
}
