import Foundation

extension URL {
    /// 从命令行字符串构造本地文件 URL，展开开头的 `~`。
    init(expandingPath path: String) {
        self.init(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

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
