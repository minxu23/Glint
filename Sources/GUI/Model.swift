// 界面状态与转换调度。真正的转换逻辑在 Sources/Core/Converter.swift，
// 这里只负责把它接到界面上：展开拖入的路径、跑批、把结果回填到列表。
//
// 刻意不依赖任何 UI 框架，状态变化统一通过 onChange 回调通知视图刷新。

import Foundation

enum OutputMode {
    case sameFolder     // 输出到源文件旁边
    case chosenFolder   // 输出到指定文件夹
}

enum RowStatus: Equatable {
    case pending, running, done
    /// 跳过与失败都带着原因——原因属于状态本身，只有这两种状态有。
    /// 以前原因和"转换成功但有话要说"挤在 FileRow.note 一个字段里：
    /// 同一个字段在 done 行是补充说明、在 failed 行是错误信息，
    /// 读的人得先看状态才知道它是什么意思。
    case skipped(String)
    case failed(String)

    /// 这一行已经有结局，不会再变。进度计数看的是这个——以前那里写的是
    /// `status != .pending && status != .running`，等于把"哪些算结束"
    /// 这件事在第三个地方又说了一遍，加一种状态就得记得改它。
    var isSettled: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .skipped, .failed: return true
        }
    }
}

struct FileRow {
    let job: Job
    var status: RowStatus = .pending
    var inBytes = 0
    var outBytes = 0
    var dest: URL?
    var issues: [String] = []
    /// 转换成功、但有一句与元数据差异无关的说明（目前只有"校验未通过所以
    /// 没删源文件"）。跳过/失败的原因不在这里，在 status 里。
    var note = ""
    var tagCount = 0
    var xattrCount = 0
    /// 列表里同时存在多个来源文件夹时置位，副标题才带上来源名——
    /// 只拖进一个文件夹时带上它纯属噪声。
    var showsRoot = false

    var name: String { job.input.lastPathComponent }

    /// 用来区分同名文件：先是来源文件夹（拖进多个时），再是它内部的子目录。
    var subpath: String? {
        var parts: [String] = []
        if showsRoot, let root = job.root { parts.append(root.lastPathComponent) }
        let rel = (job.relative as NSString).deletingLastPathComponent
        if !rel.isEmpty { parts.append(rel) }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    var savingPercent: Int? {
        guard case .done = status else { return nil }
        return percentSaved(inBytes: inBytes, outBytes: outBytes)
    }

    /// 副标题。始终带上子目录，否则递归转换时分不清同名文件是哪一个。
    var detailText: String {
        var parts: [String] = []
        if let subpath { parts.append(subpath) }
        switch status {
        case .done:
            if tagCount > 0 { parts.append("元数据 \(tagCount) 项") }
            if xattrCount > 0 { parts.append("扩展属性 \(xattrCount) 项") }
            if issues.isEmpty && tagCount > 0 { parts.append("校验无差异") }
            if !note.isEmpty { parts.append(note) }
        case .skipped(let why), .failed(let why):
            parts.append(why)
        case .pending, .running:
            break
        }
        return parts.joined(separator: " · ")
    }
}

final class ConversionModel {
    /// 状态有任何变化时在主线程回调，视图据此刷新。
    var onChange: (() -> Void)?

    private(set) var rows: [FileRow] = []
    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var warning: String?

    // MARK: 设置项

    /// 界面直接持有一份 ConversionOptions，不再为每个开关各存一个影子字段。
    /// 以前的写法要在 start() 和 reexpand() 两处把它们重新组装成 Options，
    /// 组装时少写一行就会悄悄跑偏，默认值也容易和命令行分家。
    ///
    /// 其中 verify 刻意与命令行不同：命令行的 --verify 是按需开关，脚本里不一定
    /// 想多付这份读回比对的开销；界面上结果是直接给人看的，默认校验才能让
    /// 「有没有丢东西」一眼可见。这是有意分叉，不是漏改。
    private(set) var options: ConversionOptions = {
        var o = ConversionOptions.default
        o.verify = true
        return o
    }()

    /// 改任何设置都走这里。原先每个开关各有一个只做转发的读写属性，
    /// 四个一模一样，加第五个开关就得再抄一遍——而 recursive 偏偏不是纯转发
    /// （它要重扫输入），抄错一个就是悄悄失效。现在只有这一个入口，
    /// 「哪些字段变了需要连带做什么」也只有这一处说得清。
    ///
    /// 改完一定通知视图，和本文件开头那句「状态变化统一通过 onChange 通知」
    /// 对上。被替换掉的那四个转发属性不通知，界面是靠 MainViewController 里
    /// 两处手工 refresh() 补的——今天对，但对未来任何调用方都是静默失效。
    ///
    /// `inputs` 与 `output` 这两个字段在这里改不动：界面的输入来自 roots、
    /// 输出来自 outputMode/outputFolder。要改输入输出请用 add/remove/clear 与
    /// outputMode/outputFolder；从这里改的一律原地复原，`options` 里不会存着
    /// 一个马上要被盖掉的假值。契约由下面两行加 guimodel 第 6 节共同规定。
    ///
    /// 这里曾经还有一条 assert 守着"调用方不该改这两个字段"。它在本项目里
    /// 永远不触发（一律 -O 构建，assert 被编译掉），而在唯一会触发的
    /// `-Onone` 构建里，它会让 guimodel 第 6 节——那一节故意就是改这两个
    /// 字段——直接 abort 而不是失败。自相矛盾的守卫不如没有。
    func updateOptions(_ change: (inout ConversionOptions) -> Void) {
        let before = options
        change(&options)
        options.inputs = before.inputs
        options.output = before.output
        if options.recursive != before.recursive {
            // reexpand 自己会通知——但它开头有 `guard !isRunning`，转换进行中
            // 会直接返回、一声不响。界面上走不到（refresh 在运行时禁用了
            // settingsControls，递归复选框就在里面），所以这里不额外补通知；
            // 哪天有别的调用方能在运行中改它，这条就得一起改。
            reexpand()
        } else if options != before {
            notify()
        }
    }

    var outputMode: OutputMode = .sameFolder { didSet { notify() } }
    var outputFolder: URL? { didSet { notify() } }

    // MARK: 内部状态

    /// 用户拖入或选中的原始路径。递归开关变化时据此重新展开文件列表。
    private var roots: [String] = []
    /// 用户手动从列表里移除过的文件，重新展开时不要再冒出来。
    private var excluded = Set<String>()
    private var cancellation: CancellationToken?

    private func notify() { onChange?() }

    // MARK: 输入管理

    func add(urls: [URL]) {
        let incoming = urls.map(\.path).filter { !roots.contains($0) }
        guard !incoming.isEmpty else { return }
        roots.append(contentsOf: incoming)
        reexpand()
    }

    func remove(at index: Int) {
        guard rows.indices.contains(index), !isRunning else { return }
        excluded.insert(rows[index].job.input.standardizedFileURL.path)
        rows.remove(at: index)
        recount()
        notify()
    }

    func clear() {
        guard !isRunning else { return }
        roots = []
        rows = []
        excluded = []
        completedCount = 0
        warning = nil
        notify()
    }

    private func reexpand() {
        guard !isRunning else { return }
        var opts = options
        opts.inputs = roots
        let (jobs, warnings) = collectInputs(opts)

        // 已经转换过的行保留原状，避免重新展开时把进度和结果冲掉。
        var previous: [String: FileRow] = [:]
        for r in rows where r.status != .pending {
            previous[r.job.input.standardizedFileURL.path] = r
        }
        // 拖进来的根不止一个时，同名文件要靠来源文件夹才分得清。
        let multipleRoots = Set(jobs.compactMap { $0.root?.standardizedFileURL.path }).count > 1
        rows = jobs.compactMap { job in
            let key = job.input.standardizedFileURL.path
            if excluded.contains(key) { return nil }
            var row = previous[key] ?? FileRow(job: job)
            row.showsRoot = multipleRoots
            return row
        }
        warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        recount()
        notify()
    }

    private func recount() {
        completedCount = rows.filter(\.status.isSettled).count
    }

    // MARK: 派生状态

    var pendingCount: Int { rows.filter { $0.status == .pending }.count }

    var canStart: Bool {
        guard !isRunning, pendingCount > 0 else { return false }
        if outputMode == .chosenFolder && outputFolder == nil { return false }
        return true
    }

    /// 汇总句子的措辞规则与命令行共用 BatchTally，只是量词不同；
    /// 这边的计数来自列表行（它们跨多次转换累积），不是随回调累加。
    var summary: String {
        var tally = BatchTally()
        for row in rows {
            switch row.status {
            case .done:
                tally.recordConverted(inBytes: row.inBytes, outBytes: row.outBytes,
                                      hasIssues: !row.issues.isEmpty)
            case .skipped: tally.skipped += 1
            case .failed: tally.failed += 1
            case .pending, .running: break
            }
        }
        guard tally.converted > 0 else {
            return rows.isEmpty ? "" : "共 \(rows.count) 张待转换"
        }
        return tally.summary(unit: "张")
    }

    // MARK: 转换

    func start() {
        guard canStart else { return }
        let targets = rows.filter { $0.status == .pending }

        var opts = options
        opts.output = outputMode == .chosenFolder ? outputFolder : nil

        let plan: OutputPlan
        do {
            plan = try OutputPlan.resolve(output: opts.output, fileCount: targets.count)
        } catch {
            warning = error.localizedDescription
            notify()
            return
        }

        let token = CancellationToken()
        cancellation = token
        isRunning = true
        warning = nil
        notify()

        let jobs = targets.map(\.job)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let renameNotices = runConversions(jobs, opts: opts, plan: plan, cancellation: token) { job in
                DispatchQueue.main.async { self?.mark(job, .running) }
            } onResult: { job, result in
                DispatchQueue.main.async { self?.apply(result, to: job) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !renameNotices.isEmpty { self.warning = renameNotices.joined(separator: "\n") }
                self.isRunning = false
                self.cancellation = nil
                // 取消时剩下的行退回待转换状态，方便再点一次继续。
                for i in self.rows.indices where self.rows[i].status == .running {
                    self.rows[i].status = .pending
                }
                self.recount()
                self.notify()
            }
        }
    }

    func cancel() { cancellation?.cancel() }

    private func index(of job: Job) -> Int? {
        rows.firstIndex { $0.job.input == job.input }
    }

    private func mark(_ job: Job, _ status: RowStatus) {
        guard let i = index(of: job) else { return }
        rows[i].status = status
        notify()
    }

    private func apply(_ result: ConvertResult, to job: Job) {
        guard let i = index(of: job) else { return }
        switch result {
        case .converted(let r):
            rows[i].status = .done
            rows[i].note = r.note ?? ""
            rows[i].inBytes = r.inBytes
            rows[i].outBytes = r.outBytes
            rows[i].dest = r.dest
            rows[i].tagCount = r.tagCount
            rows[i].xattrCount = r.xattrCount
            rows[i].issues = r.issues
        case .skipped(let why):
            rows[i].status = .skipped(why)
        case .failed(let why):
            rows[i].status = .failed(why)
        }
        recount()
        notify()
    }
}
