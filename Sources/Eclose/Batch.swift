// 批量转换的编排：扫描输入、决定每个文件写到哪、并发调度。
//
// 这些都是"安排工作"，与单张图怎么转、元数据怎么搬无关。

import Foundation

// MARK: - 收集输入文件

/// `url` 相对于 `base` 的路径；不在 `base` 之下就返回 nil。
/// 扫描输入和显示进度行都要做这件事，别各写一遍补斜杠的逻辑。
public func relativePath(of url: URL, under base: URL) -> String? {
    let basePath = base.standardizedFileURL.path
    let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count))
}

/// 一个待转换的文件。`relative` 是它相对于命令行给出的那个目录的路径，
/// 用 -o 输出到别处时据此镜像原有的子目录结构，避免同名文件互相覆盖。
public struct Job {
    public let input: URL
    public let relative: String
    /// 命令行/拖拽给出的那个目录；直接点名的单个文件没有根，为 nil。
    /// 多个根撞名时用它的名字做区分（见 assignDestinations）。
    public let root: URL?

    public init(input: URL, relative: String, root: URL?) {
        self.input = input
        self.relative = relative
        self.root = root
    }
}

/// 扫描命令行/拖拽进来的路径，展开成待转换文件列表。
/// 目录里按扩展名挑 `opts.sources` 那几种源的文件（SourceKind.extensions）；直接点名的文件不挑，
/// 转不转由 convert 按内容判定。
/// 警告随返回值一起交出去，由调用方决定怎么呈现（终端 stderr 或界面提示）。
public func collectInputs(_ opts: ConversionOptions) -> (jobs: [Job], warnings: [String]) {
    let fm = FileManager.default
    let extensions = opts.sources.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
    var out: [Job] = []
    var warnings: [String] = []
    var seen = Set<String>()

    func add(_ url: URL, relativeTo root: URL?) {
        let path = url.standardizedFileURL.path
        guard seen.insert(path).inserted else { return }
        let relative = root.flatMap { relativePath(of: url, under: $0) } ?? url.lastPathComponent
        out.append(Job(input: url, relative: relative, root: root))
    }

    for raw in opts.inputs {
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            warnings.append("跳过（不存在）: \(raw)")
            continue
        }
        if isDir.boolValue {
            let keys: [URLResourceKey] = [.isRegularFileKey]
            if opts.recursive {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if extensions.contains(f.pathExtension.lowercased()) { add(f, relativeTo: url) }
                }
            } else {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles])) ?? []
                for f in items where extensions.contains(f.pathExtension.lowercased()) {
                    add(f, relativeTo: url)
                }
            }
        } else {
            add(url, relativeTo: nil)
        }
    }
    return (out, warnings)
}

// MARK: - 输出位置

/// 输出到哪里。命令行和界面用同一套语义：指定了目录就输出到该目录（并镜像
/// 子目录层级），没指定就放在源文件旁边。
///
/// 用 enum 而不是两个 Optional 字段：三种去向互斥，`directory` 和 `singleFile`
/// 同时为 nil 才代表"源文件旁边"，这种编码要靠一个 static 别名才读得懂，
/// 而且允许出现两个都有值的无意义状态。
public enum OutputPlan {
    /// 产物放在每个源文件旁边。
    case sameFolder
    /// 全部产物放进这个目录，并在其中镜像源的子目录层级。
    case directory(URL)
    /// 只有单个输入时，输出可以是一个具体的文件名。
    case singleFile(URL)

    /// 输出根目录；只在 `.directory` 时有值。命令行用它把进度行显示成相对路径。
    public var directory: URL? {
        if case .directory(let url) = self { return url }
        return nil
    }

    enum PlanError: Error, LocalizedError {
        case cannotCreate(URL, String)
        case fileForManyInputs(URL)
        case existingFileForManyInputs(URL)
        case notHEIFName(URL)
        var errorDescription: String? {
            switch self {
            case let .cannotCreate(url, why): return "无法创建输出目录 \(url.path): \(why)"
            case let .fileForManyInputs(url):
                return "有多个输入时 -o 要给一个目录，\(url.lastPathComponent) 是文件名（单个输入时才能指定产物的文件名）"
            case let .existingFileForManyInputs(url):
                return "-o 指向的 \(url.path) 是一个已有的文件；有多个输入时 -o 要给一个目录"
            case let .notHEIFName(url):
                return "产物的文件名要以 .heic 或 .heif 结尾：\(url.lastPathComponent)"
            }
        }
    }

    /// 产物文件名认的后缀（不分大小写）。
    static let heifExtensions: Set<String> = ["heic", "heif"]
    /// 一看就是别的图片格式的后缀：拿它当产物的文件名，写出来的是 HEIF、名字却说是 JPEG。
    /// 不在两张表里的后缀（`2024.09`、`相册.v2`）照旧当目录。
    static let otherImageExtensions: Set<String> = SourceKind.jpeg.extensions.union(SourceKind.raw.extensions)
        .union(["png", "gif", "tif", "tiff", "bmp", "webp", "avif", "jxl"])

    /// - Parameters:
    ///   - fileCount: 待转换文件数。只有单个文件时，`output` 才可以是一个文件名。
    ///   - createDirectories: 是否现在就把输出目录建出来。提前建是为了让「路径不可写」
    ///     一次性报出来，而不是让一批 800 张的任务逐张失败。预演要传 false——
    ///     `--dry-run` 什么都不该往磁盘上写，哪怕只是一个空目录。
    public static func resolve(output: URL?, fileCount: Int,
                        createDirectories: Bool = true) throws -> OutputPlan {
        guard let url = output else { return .sameFolder }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if exists && isDir.boolValue { return .directory(url) }

        let ext = url.pathExtension.lowercased()
        if exists && fileCount > 1 { throw PlanError.existingFileForManyInputs(url) }
        if heifExtensions.contains(ext) && fileCount > 1 { throw PlanError.fileForManyInputs(url) }
        if otherImageExtensions.contains(ext) { throw PlanError.notHEIFName(url) }
        // 单个输入：.heic/.heif 的名字，或者已经存在的文件（覆盖与否由 -f 管），就是产物的文件名。
        if fileCount == 1 && (heifExtensions.contains(ext) || exists) {
            if createDirectories {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
            }
            return .singleFile(url)
        }
        if createDirectories {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw PlanError.cannotCreate(url, error.localizedDescription)
            }
        }
        return .directory(url)
    }

    /// 算出目标路径。纯计算，不建目录——目录等重名消解完、真要写的时候再建，
    /// 否则被改名让开的那些路径会留下一堆空文件夹。
    func destination(for job: Job, relative: String? = nil) -> URL {
        switch self {
        case .singleFile(let url):
            return url
        case .sameFolder:
            return job.input.deletingPathExtension().appendingPathExtension("heic")
        case .directory(let dir):
            // 保留原有的子目录层级，递归转换整个相册时不会因为重名互相覆盖。
            return dir.appendingPathComponent(relative ?? job.relative)
                .deletingPathExtension().appendingPathExtension("heic")
        }
    }
}

// MARK: - 目标路径分配

/// 开工前把每个任务的目标路径一次性定下来，并消解重名。
///
/// 必须串行地、在任何转换开始之前做完。把「输出已存在」的判断留在并发执行的
/// convert() 里的话，`glint A B -o OUT` 且 A/B 各有一个 a.jpg 时，两个任务
/// 会同时看到 OUT/a.heic 不存在，双双写入，后写的静默覆盖先写的。
///
/// 消解办法：把撞在一起的那一组**整组**挪进各自源目录名下（OUT/A/a.heic、
/// OUT/B/a.heic），而不是只给后来者改名——只改后来者会得到 OUT/a.heic 与
/// OUT/B/a.heic 这种不对称的结果，更难理解。仍然撞的（同名根目录、或同一目录下
/// 的 a.jpg 与 a.jpeg）再退回加数字后缀。
/// 给一组根目录算出互不相同的短名：先只用最后一段，不够就逐级往前多带一段。
/// `x/照片` 与 `y/照片` 的最后一段相同，只用它区分不了，得退到 `x/照片`、`y/照片`。
///
/// 入参允许重复——一个根可能在同一个冲突组里贡献多个文件（`A/a.jpg` 与
/// `A/a.jpeg` 都映射到 `a.heic`），所以内部先去重：不去重的话
/// `Set(names).count == roots.count` 在有重复时**永不成立**，逐级上溯每一层都
/// 失败，直接落到兜底。
///
/// 返回值按**标准化路径字符串**索引，不拿 URL 当键：同一个目录可以有多种 URL
/// 写法（尾斜杠、符号链接、`.` 段），用 URL 做键会把它们当成不同的根。
func distinctRootNames(_ roots: [URL]) -> [String: String] {
    var unique: [String] = []          // 标准化路径，保持输入顺序以求稳定
    var seen = Set<String>()
    for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
        unique.append(root.standardizedFileURL.path)
    }
    guard !unique.isEmpty else { return [:] }

    let components = unique.map { ($0 as NSString).pathComponents }
    let maxDepth = components.map(\.count).max() ?? 1
    for depth in 1...max(maxDepth, 1) {
        let names = components.map { $0.suffix(depth).joined(separator: "/") }
        if Set(names).count == unique.count {
            return Dictionary(uniqueKeysWithValues: zip(unique, names))
        }
    }
    // 去重后不可能所有完整路径都相同，这里只是不让它 trap。
    return Dictionary(uniqueKeysWithValues:
        unique.map { ($0, ($0 as NSString).lastPathComponent) })
}

func assignDestinations(_ jobs: [Job], plan: OutputPlan,
                        avoidingExistingFiles: Bool = true)
    -> (pairs: [(job: Job, dest: URL)], warnings: [String]) {
    // macOS 默认文件系统不区分大小写，a.heic 与 A.heic 是同一个文件，
    // 所以按小写分组。区分大小写的卷上最多多垫一层目录，不会丢文件。
    func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    let natural = jobs.map { plan.destination(for: $0) }
    var groups: [String: [Int]] = [:]
    for (i, dest) in natural.enumerated() { groups[key(dest), default: []].append(i) }

    var finals = natural
    var warnings: [String] = []
    var taken = Set<String>()

    // 先把不冲突的占住位置，免得消解冲突时又撞上它们。
    for (_, members) in groups where members.count == 1 {
        taken.insert(key(natural[members[0]]))
    }

    for (_, members) in groups.sorted(by: { $0.key < $1.key }) where members.count > 1 {
        // 按源路径排序再处理：否则"谁保住干净名字"取决于目录枚举顺序，
        // 同一批文件跨次运行可能得到不同的结果。
        let ordered = members.sorted { jobs[$0].input.path < jobs[$1].input.path }

        // 只有撞在一起的文件来自不同的根时，分目录才有区分意义；
        // 同一个根下的 a.jpg 与 a.jpeg 垫一层同名目录没用，直接走数字后缀。
        let roots = ordered.compactMap { jobs[$0].root }
        let distinctRoots = Set(roots.map { $0.standardizedFileURL.path })
        let folderName = distinctRoots.count > 1 ? distinctRootNames(roots) : [:]
        func folder(for job: Job) -> String? {
            job.root.flatMap { folderName[$0.standardizedFileURL.path] }
        }

        for i in ordered {
            let job = jobs[i]
            var candidate = natural[i]
            if let name = folder(for: job) {
                candidate = plan.destination(for: job, relative: "\(name)/\(job.relative)")
            }

            // 还占着就加数字后缀，直到找到空位。基名固定，避免变成 a-2-3。
            // 除了本批已占用的，也要让开磁盘上已有的文件——否则改名让出来的位置
            // 可能正好压在先前某次运行的产物上。但 --overwrite 时不让：用户明确要覆盖。
            let folder = candidate.deletingLastPathComponent()
            let base = candidate.deletingPathExtension().lastPathComponent
            func occupied(_ url: URL) -> Bool {
                if taken.contains(key(url)) { return true }
                return avoidingExistingFiles && FileManager.default.fileExists(atPath: url.path)
            }
            var n = 2
            while occupied(candidate) {
                candidate = folder.appendingPathComponent("\(base)-\(n)")
                    .appendingPathExtension("heic")
                n += 1
            }
            taken.insert(key(candidate))
            finals[i] = candidate
            // 组里可能有一个恰好留在原位，那就别谎称它挪过。
            if key(candidate) != key(natural[i]) {
                warnings.append("重名避让: \(job.input.path) 改写到 \(candidate.path)")
            }
        }
    }

    return (Array(zip(jobs, finals)).map { (job: $0.0, dest: $0.1) }, warnings)
}

// MARK: - 批量执行

/// 供界面上的"取消"使用。已经开始的那一张会转完，之后的不再启动。
public final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// 并发转换整批文件，每转完一个就回调一次（回调已串行化，可直接累加统计）。
/// 本函数会阻塞到全部结束，界面端请在后台队列调用。
/// 返回重名避让的说明，调用方负责呈现。
@discardableResult
public func runConversions(_ jobs: [Job], opts: ConversionOptions, plan: OutputPlan,
                    cancellation: CancellationToken? = nil,
                    onStart: ((Job) -> Void)? = nil,
                    onResult: @escaping (Job, ConvertResult) -> Void) -> [String] {
    // 目标路径必须在并发开始之前定完，否则两个任务会抢同一个目标。
    let (pairs, warnings) = assignDestinations(jobs, plan: plan,
                                               avoidingExistingFiles: !opts.overwrite)

    let concurrency = max(1, min(opts.jobs, max(jobs.count, 1)))
    let queue = DispatchQueue(label: "glint.convert", attributes: .concurrent)
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: concurrency)
    let callbackLock = NSLock()
    // 核对用的缓冲在这一批里复用，整批结束时还给系统（见 QualityBuffers）。
    QualityBuffers.shared.beginBatch()
    defer { QualityBuffers.shared.endBatch() }

    for (job, dest) in pairs {
        if cancellation?.isCancelled == true { break }
        semaphore.wait()
        queue.async(group: group) {
            defer { semaphore.signal() }
            if cancellation?.isCancelled == true { return }
            if let onStart {
                callbackLock.lock(); onStart(job); callbackLock.unlock()
            }
            let result = convert(job.input, opts: opts, dest: dest)
            callbackLock.lock(); defer { callbackLock.unlock() }
            onResult(job, result)
        }
    }
    group.wait()
    return warnings
}

// MARK: - 结果统计

/// 节省比例。命令行和界面共用这一个定义。
/// 返回 nil 表示无从计算（缺少体积数据）；负数表示产物反而更大。
public func percentSaved(inBytes: Int, outBytes: Int) -> Int? {
    guard inBytes > 0, outBytes > 0 else { return nil }
    return Int(round((1 - Double(outBytes) / Double(inBytes)) * 100))
}

/// 一批转换的计数与体积。命令行和界面从不同来源填它（一个随回调累加，
/// 一个从列表行汇总），但"汇总句子里哪些从句该出现"这条规则只写一遍。
public struct BatchTally {
    public var converted = 0
    public var skipped = 0
    public var failed = 0
    public var flagged = 0          // 转换成功但元数据有差异
    public var grew = 0             // 转换成功但产物比原图大（判据见 growthPercent）
    public var qualityDropped = 0   // 画质核对不达标、没有转换（ConvertResult.qualityDropped），不算失败
    public var inBytes = 0
    public var outBytes = 0

    public init() {}

    public mutating func record(_ result: ConvertResult) {
        switch result {
        case .converted(let r):
            recordConverted(inBytes: r.inBytes, outBytes: r.outBytes,
                            hasIssues: r.verification.hasDifferences)
        case .skipped:
            skipped += 1
        case .failed:
            failed += 1
        case .qualityDropped:
            qualityDropped += 1
        }
    }

    /// 界面的计数来自列表行而不是回调，拿不到 ConvertResult，但记账规则是同一套。
    public mutating func recordConverted(inBytes bytes: Int, outBytes out: Int, hasIssues: Bool) {
        converted += 1
        inBytes += bytes
        outBytes += out
        if hasIssues { flagged += 1 }
        if growthPercent(inBytes: bytes, outBytes: out) != nil { grew += 1 }
    }

    /// - Parameter unit: 量词。命令行说"个"，界面说"张"。
    public func summary(unit: String) -> String {
        var parts = ["完成 \(converted) \(unit)"]
        if skipped > 0 { parts.append("跳过 \(skipped) \(unit)") }
        if failed > 0 { parts.append("失败 \(failed) \(unit)") }
        if flagged > 0 { parts.append("\(flagged) \(unit)有元数据差异") }
        if grew > 0 { parts.append("\(grew) \(unit)比原图大") }
        if qualityDropped > 0 { parts.append("\(qualityDropped) \(unit)画质不达标，保留原 JPEG") }
        if let pct = percentSaved(inBytes: inBytes, outBytes: outBytes) {
            parts.append("总计 \(humanSize(inBytes)) → \(humanSize(outBytes))，" + (pct >= 0 ? "节省 \(pct)%" : "增大 \(-pct)%"))
        }
        return parts.joined(separator: "，")
    }
}
