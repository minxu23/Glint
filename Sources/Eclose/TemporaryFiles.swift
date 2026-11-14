// 正在写的临时产物（输出目录里的 `.glint-<UUID>.heic`）。
//
// 转换先写临时文件、成功后再换成正式的名字，中途失败的那份当场删掉。可进程被信号打断
// （终端里按 Ctrl-C、kill、关掉终端窗口）或应用在转换中途退出时，没人去删：它们以点开头、
// 访达里看不见，悄悄占着空间。这里记下每个还在写的临时文件，打断时由命令行（信号处理）或
// 应用（退出前）调 removeInFlightTemporaries 删掉。
//
// 已经结束的转换（临时文件改成了正式名字，或已删掉）在 convert 返回时注销，所以这里只有
// 正在写的那几个。开始收尾以后不再登记新的：convert 拿不到临时文件就按编码失败处理。

import Foundation

final class TemporaryFiles {
    static let shared = TemporaryFiles()

    private let lock = NSLock()
    private var paths = Set<URL>()
    private var shuttingDown = false

    /// 登记一个即将写的临时文件。已经开始收尾时返回 false，调用方别再写。
    func register(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { return false }
        paths.insert(url)
        return true
    }

    var isShuttingDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return shuttingDown
    }

    func forget(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for u in urls { paths.remove(u) }
    }

    /// 开始收尾：不再登记新的，删掉还登记着的；再等正在进行的转换收手（最多 `timeout` 秒），期间
    /// 冒出来的临时文件也删掉。要等：ImageIO 在编码收尾时才建文件，刚收尾时还没有文件可删，退出前
    /// 它可能就写出来了。等的这会儿里转完的那张照常换成正式名字（产物是完整的），注销后不再管。
    /// 返回实际删掉的个数（已经不在的不算）。
    func shutDown(timeout: TimeInterval) -> Int {
        lock.lock()
        shuttingDown = true
        lock.unlock()
        var removed = removeRegisteredFiles()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let busy = !paths.isEmpty; lock.unlock()
            if !busy { break }
            Thread.sleep(forTimeInterval: 0.05)
            removed += removeRegisteredFiles()
        }
        return removed + removeRegisteredFiles()
    }

    private func removeRegisteredFiles() -> Int {
        lock.lock(); let pending = paths; lock.unlock()
        return pending.reduce(0) { $0 + TemporaryFiles.remove($1) }
    }

    /// 删掉一个临时产物，连同 ImageIO 写它时在旁边建的临时文件：ImageIO 先写进同一目录里的
    /// `.<文件名>-XXXXXX`，写完再改名；写到一半失败（磁盘满了）或进程被打断时，那个文件留下来，
    /// 名字形如 `..glint-<UUID>.heic-u41uww`。返回删掉的个数。
    static func remove(_ url: URL) -> Int {
        let fm = FileManager.default
        var removed = (try? fm.removeItem(at: url)) != nil ? 1 : 0
        let prefix = "." + url.lastPathComponent + "-"
        let folder = url.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            if (try? fm.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// 删掉所有还没写完的临时产物，此后的转换不再开始写临时文件。进程要被打断或退出时调用：
/// 会等正在进行的转换收手，最多 `timeout` 秒。返回删掉的个数。
public func removeInFlightTemporaries(timeout: TimeInterval = 3) -> Int {
    TemporaryFiles.shared.shutDown(timeout: timeout)
}

/// 已经开始收尾（removeInFlightTemporaries 调过了）。此后还在报结果的转换是被打断的，
/// 命令行据此不再逐张打印。
public var conversionsInterrupted: Bool { TemporaryFiles.shared.isShuttingDown }
