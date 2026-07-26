import ArgumentParser
import Foundation

/// 用于在子命令中以友好信息退出（非零退出码），避免打印 Swift 的堆栈式错误。
struct ExitWithMessage: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
