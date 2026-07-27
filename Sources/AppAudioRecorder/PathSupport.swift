import Foundation

extension URL {
    /// 从命令行字符串构造本地文件 URL，展开开头的 `~`。
    init(expandingPath path: String) {
        self.init(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
