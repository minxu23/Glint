// 界面状态与转换调度。真正的转换逻辑在 Sources/Eclose/Converter.swift，
// 这里只负责把它接到界面上：展开拖入的路径、跑批、把结果回填到列表。
//
// 刻意不依赖任何 UI 框架，状态变化统一通过 onChange 回调通知视图刷新。

import Eclose
import Foundation

enum OutputMode {
    case sameFolder     // 输出到源文件旁边
    case chosenFolder   // 输出到指定文件夹
}

enum RowStatus: Equatable {
    case pending, running, done
    /// 跳过与失败都带着原因——原因属于状态本身，只有这两种状态有。
    /// "转换成功但有话要说"放在 FileRow.note，不和原因共用一个字段。
    case skipped(String)
    case failed(String)
    /// 画质核对不达标，没有转换（ConvertResult.qualityDropped）：没有产物，源原样留着。
    /// 与跳过、失败分开，带着量出的数和门槛。
    case qualityDropped(QualityDrop)

    /// 这一行已经有结局，不会再变。进度计数看的是这个："哪些算结束"只在这里定义。
    var isSettled: Bool {
        switch self {
        case .pending, .running: return false
        case .done, .skipped, .failed, .qualityDropped: return true
        }
    }
}

struct FileRow {
    let job: Job
    var status: RowStatus = .pending
    var inBytes = 0
    var outBytes = 0
    var dest: URL?
    var verification: Verification = .notVerified
    /// 转换成功、但有与元数据差异无关的说明（产物比原图大、没删源文件的原因，
    /// 即 ConversionReport.note）。跳过/失败的原因不在这里，在 status 里。
    var note = ""
    var tagCount = 0
    var xattrCount = 0
    /// 以下四项照抄 ConversionReport，信息栏的「转换结果」一组显示；没有就是 nil。
    var rawExif: RawExifOutcome?
    var reencode: Reencode?
    var caption: CaptionOutcome?
    var quality: QualityOutcome?
    /// Eclose 报告源文件确实被删掉了（ConversionReport.sourceDeleted）。
    var sourceDeleted = false
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
            if verification == .passed && tagCount > 0 { parts.append("校验无差异") }
            if !note.isEmpty { parts.append(note) }
        case .skipped(let why), .failed(let why):
            parts.append(why)
        case .qualityDropped(let drop):
            parts.append(drop.description)
        case .pending, .running:
            break
        }
        return parts.joined(separator: " · ")
    }
}

final class ConversionModel {
    /// 状态有任何变化时在主线程回调，视图据此刷新。
    var onChange: (() -> Void)?
    /// 某一行的状态变了（开始转、转完）时在主线程回调，先于 onChange。
    /// 视图据此只刷新那一张图，不必整个重载。
    var onRowChange: ((FileRow) -> Void)?

    private(set) var rows: [FileRow] = []
    private(set) var isRunning = false
    private(set) var completedCount = 0
    private(set) var warning: String?
    /// 最近一次跑批是被取消的（结束时还有没转的行）。开始下一批时清掉。
    private(set) var wasCancelled = false

    // MARK: 设置项

    /// 界面直接持有一份 ConversionOptions，不为每个开关各存一个影子字段，
    /// 默认值也取自命令行同一份 ConversionOptions.default。
    ///
    /// 其中 verify 刻意与命令行不同：命令行的 --verify 是按需开关，脚本里不一定
    /// 想多付这份读回比对的开销；界面上结果是直接给人看的，默认校验才能让
    /// 「有没有丢东西」一眼可见。这是有意分叉，不是漏改。
    private(set) var options: ConversionOptions = {
        var o = ConversionOptions.default
        o.verify = true
        return o
    }()

    /// 改任何设置都走这里。只有这一个入口，「哪些字段变了需要连带做什么」
    /// （recursive 要重扫输入）也只有这一处说得清。
    ///
    /// 改完一定通知视图，和本文件开头那句「状态变化统一通过 onChange 通知」对上。
    ///
    /// `inputs` 与 `output` 这两个字段在这里改不动：界面的输入来自 roots、
    /// 输出来自 outputMode/outputFolder。要改输入输出请用 add/remove/clear 与
    /// outputMode/outputFolder；从这里改的一律原地复原，`options` 里不会存着
    /// 一个马上要被盖掉的假值。契约由下面两行加 guimodel「改设置会通知视图」
    /// 一节共同规定；那一节故意改这两个字段，所以这里不用 assert。
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

    /// 换上新的一批：清掉旧的行，按给定的 Job 建行。界面每次从转换面板开始都走这里——
    /// Job 由调用方算好，带着来源根目录，输出到指定文件夹时 Eclose 据此镜像子目录。
    /// 转换进行中不换。
    func replaceJobs(_ jobs: [Job]) {
        guard !isRunning else { return }
        roots = []
        excluded = []
        rows = jobs.map { FileRow(job: $0) }
        warning = nil
        wasCancelled = false
        recount()
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
                                      hasIssues: row.verification.hasDifferences)
            case .skipped: tally.skipped += 1
            case .failed: tally.failed += 1
            case .qualityDropped: tally.qualityDropped += 1
            case .pending, .running: break
            }
        }
        guard tally.converted > 0 || tally.qualityDropped > 0 else {
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
        wasCancelled = false
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
                self.wasCancelled = token.isCancelled && self.rows.contains { $0.status == .pending }
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
        onRowChange?(rows[i])
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
            rows[i].verification = r.verification
            rows[i].rawExif = r.rawExif
            rows[i].reencode = r.reencode
            rows[i].caption = r.caption
            rows[i].quality = r.quality
            rows[i].sourceDeleted = r.sourceDeleted
        case .skipped(let why):
            rows[i].status = .skipped(why)
        case .failed(let why):
            rows[i].status = .failed(why)
        case .qualityDropped(let drop):
            rows[i].status = .qualityDropped(drop)
        }
        recount()
        onRowChange?(rows[i])
        notify()
    }
}
