import Foundation

/// 轻量的诊断日志。
///
/// 小米登录的每一步（有没有拿到二维码、长轮询拿回了什么、cookie 里有哪些名字、
/// 到底缺哪一项凭证）都往这里记。卡住时在「关联米家」页展开「诊断信息」，
/// 直接复制发出来即可，不用反复靠猜。
///
/// 登录流程跑在多个后台任务里，所以用锁保证任意线程写入都安全。
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let lock = NSLock()
    private var storage: [String] = []
    /// 只保留最近这些行，避免长时间运行把内存吃满。
    private let limit = 500

    func log(_ message: String) {
        let now = Date()
        lock.lock()
        let formatter = Diagnostics.formatter
        let line = "\(formatter.string(from: now)) \(message)"
        storage.append(line)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// 全局简写，调用点不用到处写 Diagnostics.shared。
func dlog(_ message: String) {
    Diagnostics.shared.log(message)
}

/// 把一组 cookie 汇总成便于阅读的名字（只记名字，不记值，避免泄露凭证）。
func cookieNameList(_ cookies: [HTTPCookie]) -> String {
    let names = Set(cookies.map(\.name)).sorted()
    return names.isEmpty ? "无" : names.joined(separator: ",")
}
