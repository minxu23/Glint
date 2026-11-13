// 转换的对象（面板标题和说明）与转换记录（「最近一次转换」、标记、汇总、活动条的那句话）。
//
// 都是纯计算，不依赖 AppKit，由 Tests/guimodel 直接测。记录只在本次运行里有，不存盘。

import Eclose
import Foundation

// MARK: - 转换的对象

/// 点「转换…」时要转的那些图：JPEG 和相机 RAW，一批里可以混着，每张由 Eclose 按内容分派到对应的
/// 管线。删除源文件只对 JPEG 生效，RAW 原片始终保留（Eclose 那层也挡着，见 apply）。
struct ConversionTargets {
    enum Scope: Equatable {
        /// 选中的那些里能转的。
        case selection
        /// 当前视图里全部能转的；带上条目名和搜索词。
        case entry(name: String, search: String)
    }

    /// 能转的：按扩展名是 JPEG 或 RAW（PhotoItem.isConvertible）。
    let items: [PhotoItem]
    let jpegCount: Int
    let rawCount: Int
    let scope: Scope
    /// 范围里还有别的格式（它们不动）。
    let hasOtherFormats: Bool
    /// 交给 ConversionModel 的任务，各带来源根目录。
    let jobs: [Job]

    /// 一张能转的都没有时，「转换…」按钮的悬停提示。
    static let emptyHint = "这里没有可以转换的 JPEG 或 RAW"

    /// - Parameters:
    ///   - selected: 选中的图片；空表示没选中。
    ///   - visible: 当前视图里的全部图片（已按搜索过滤）。
    ///   - entry: 当前的侧栏条目。当前是文件夹时，来源根取这个文件夹，输出到指定文件夹时
    ///     从这一层往下镜像；否则取图片所属的已添加文件夹。单独添加的图片没有根。
    init(selected: [PhotoItem], visible: [PhotoItem], entry: LibraryEntry, entryName: String, search: String) {
        let pool = selected.isEmpty ? visible : selected
        items = pool.filter(\.isConvertible)
        jpegCount = items.filter(\.isJPEG).count
        rawCount = items.filter(\.isRAW).count
        hasOtherFormats = items.count < pool.count
        scope = selected.isEmpty ? .entry(name: entryName, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
                                 : .selection
        jobs = items.map { item in
            var root = item.root
            if case .folder(let path) = entry, isPath(item.path, inside: path) { root = URL(fileURLWithPath: path) }
            let relative = root.flatMap { relativePath(of: item.url, under: $0) } ?? item.name
            return Job(input: item.url, relative: relative, root: root)
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var totalBytes: Int { items.reduce(0) { $0 + $1.size } }

    /// 这批是哪几种：`JPEG`、`RAW` 或 `JPEG 和 RAW`。
    private var kinds: String {
        switch (jpegCount > 0, rawCount > 0) {
        case (true, true): return "JPEG 和 RAW"
        case (false, true): return "RAW"
        default: return "JPEG"
        }
    }

    /// `转换 196 张 JPEG`、`转换 4 张 RAW`；两种混着时 `转换 12 张（JPEG 8 张、RAW 4 张）`。
    var title: String {
        if jpegCount > 0 && rawCount > 0 { return "转换 \(items.count) 张（JPEG \(jpegCount) 张、RAW \(rawCount) 张）" }
        return "转换 \(items.count) 张 \(kinds)"
    }

    /// 面板标题下那一句。
    var detail: String {
        let size = shortSize(totalBytes)
        let others = hasOtherFormats ? "别的格式不动。" : ""
        switch scope {
        case .selection:
            return "选中的 \(items.count) 张 \(kinds)，共 \(size)。" + others
        case .entry(let name, let search):
            let what = search.isEmpty ? "「\(name)」里的全部 \(kinds)" : "「\(name)」里符合「\(search)」的 \(kinds)"
            return "\(what)，共 \(size)。" + others
        }
    }

    // MARK: 删除源文件

    /// 面板「源文件」一栏。删除只对 JPEG 生效：RAW 原片始终保留。
    enum DeleteChoice: Equatable {
        /// 这批里有 JPEG：一个复选框。`title` 是复选框的字，`hint` 是下面那行说明，
        /// `primary` 是勾上以后主按钮的字。
        case offered(title: String, hint: String, primary: String)
        /// 这批里只有 RAW：没有删除这个选项，只写一句（不放一个灰掉的复选框）。
        case unavailable(String)
    }

    var deleteChoice: DeleteChoice {
        if jpegCount == 0 { return .unavailable("RAW 原片始终保留，不删除") }
        if rawCount == 0 {
            return .offered(title: "校验无差异后删除源文件", hint: "有差异的、HEIF 反而更大的，源文件都留着",
                            primary: "转换并删除源文件")
        }
        return .offered(title: "校验无差异后删除源 JPEG",
                        hint: "这批里的 \(rawCount) 张 RAW 原片始终保留；有差异的、HEIF 反而更大的 JPEG 也留着",
                        primary: "转换并删除源 JPEG")
    }

    /// 这批真的要删源文件：勾了删除，而且这批里有 JPEG。只有 RAW 时面板上没有这个选项、
    /// 存储里也不记它，这里再挡一道。
    func deletes(_ settings: PanelSettings) -> Bool { settings.deleteOriginal && jpegCount > 0 }

    /// 主按钮的字：要删就是 `转换并删除源文件`（混着 RAW 时 `转换并删除源 JPEG`），否则 `转换`。
    func primaryTitle(_ settings: PanelSettings) -> String {
        if deletes(settings), case .offered(_, _, let primary) = deleteChoice { return primary }
        return "转换"
    }

    /// 把面板设置连同这批的情况落到 ConversionOptions 上。输入输出不在这里（见 PanelSettings.apply）。
    /// - 两种源都收，每张由 Eclose 按内容分派；
    /// - 这批里有 RAW 时，并发数用 Eclose 给 RAW 的默认值（显影吃内存，见
    ///   ConversionOptions.defaultRAWJobs），只有 JPEG 时用默认的核数；
    /// - 删除只在这批有 JPEG 时打开（deletes）。混着 RAW 时照样交给 Eclose，RAW 由它跳过不删。
    func apply(_ settings: PanelSettings, to options: inout ConversionOptions) {
        settings.apply(to: &options)
        options.sources = [.jpeg, .raw]
        options.jobs = rawCount > 0 ? ConversionOptions.defaultRAWJobs : ConversionOptions.default.jobs
        options.deleteOriginal = deletes(settings)
    }

    /// 这批里「照片」说明在、文件里没有说明的张数（勾「把备注写进文件」能写进去的）。
    /// 元数据还没读到的不算。
    var captionOutsideCount: Int { items.filter { $0.info?.captionOutsideOnly == true }.count }

    /// 这批里 CMYK 的张数（不勾「也转 CMYK 的 JPEG」时转换会跳过的）。元数据还没读到的不算，
    /// 转换时照样按内容判定、跳过。
    var cmykCount: Int { items.filter { $0.info?.isCMYK == true }.count }

    /// 「也转 CMYK 的 JPEG」下面那行说明。
    var cmykHint: String {
        let n = cmykCount
        let why = "HEIF 只能存 RGB，转了颜色会变；不勾就跳过"
        return n > 0 ? "这批里有 \(n) 张 CMYK 的 JPEG。" + why : "CMYK 的 JPEG 多是印刷用的稿子。" + why
    }

    /// 「把备注写进文件」下面那行说明。
    var captionHint: String {
        let n = captionOutsideCount
        return n > 0 ? "这批里有 \(n) 张的备注存在文件之外，写进去以后换了设备也在" : "这批里没有存在文件之外的备注"
    }
}

// MARK: - 差异行

/// 一行差异的标记。
enum IssueTag: Equatable {
    case lost, changed, notice

    var label: String {
        switch self {
        case .lost: return "丢失"
        case .changed: return "变化"
        case .notice: return "注意"
        }
    }
}

/// 把一行差异分成（标记，正文）：以 `丢失 ` 开头的标「丢失」，以 `变化 ` 开头的标「变化」，
/// 正文去掉开头那两个字和空格；其它标「注意」，正文原样。
func splitIssue(_ line: String) -> (tag: IssueTag, text: String) {
    if line.hasPrefix("丢失 ") { return (.lost, String(line.dropFirst(3))) }
    if line.hasPrefix("变化 ") { return (.changed, String(line.dropFirst(3))) }
    return (.notice, line)
}

/// 「最常见的差异」归并用的那一截：取到第一个 ` = `、`: `、`：` 为止，连续的数字换成 `N`。
func issueFamily(_ line: String) -> String {
    var head = Substring(line)
    let cuts = [" = ", ": ", "："].compactMap { line.range(of: $0)?.lowerBound }
    if let first = cuts.min() { head = line[..<first] }
    var out = ""
    var inDigits = false
    for ch in head {
        if ch.isASCII && ch.isNumber {
            if !inDigits { out.append("N") }
            inDigits = true
        } else {
            out.append(ch)
            inDigits = false
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

// MARK: - 转换记录

/// 缩略图角上和列表「转换」列的状态。没转过的、转换成功且无差异的不在网格上加标记。
enum ConversionMark: Equatable {
    case running
    case passed
    case notVerified
    case differences(Int)
    case skipped
    case failed

    /// 网格上要不要放标记：只有转换中、有差异、失败三种。
    var showsOnGrid: Bool {
        switch self {
        case .running, .differences, .failed: return true
        default: return false
        }
    }

    /// 列表「转换」列的文字。
    var listText: String {
        switch self {
        case .running: return "转换中"
        case .passed: return "无差异"
        case .notVerified: return "没有校验"
        case .differences(let n): return "\(n) 处差异"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        }
    }

    /// 无障碍描述里的那一截。
    var spokenText: String {
        switch self {
        case .running: return "正在转换"
        case .passed: return "转换时无差异"
        case .notVerified: return "转换时没有校验"
        case .differences(let n): return "转换时有 \(n) 处差异"
        case .skipped: return "转换时跳过"
        case .failed: return "转换失败"
        }
    }
}

/// 活动条那句话里的一段；`link` 非空的那段可以点，点了跳到对应的侧栏条目。
struct SentencePart: Equatable {
    var text: String
    var link: LibraryEntry?
    /// 第一句加粗（草图里 `转完 195 张，省下 398 MB。` 那一截）。
    var emphasized = false
}

/// 这次运行里最后一批转换。行来自 ConversionModel（它只装着这一批）。
struct ConversionRecord {
    var rows: [FileRow]
    var startedAt: Date
    /// 这批勾了「校验无差异后删除源文件」（且有 JPEG 可删，见 ConversionTargets.deletes）。
    var deleteRequested: Bool
    var isRunning: Bool
    var wasCancelled: Bool

    init(rows: [FileRow], startedAt: Date = Date(), deleteRequested: Bool = false,
         isRunning: Bool = false, wasCancelled: Bool = false) {
        self.rows = rows
        self.startedAt = startedAt
        self.deleteRequested = deleteRequested
        self.isRunning = isRunning
        self.wasCancelled = wasCancelled
    }

    // MARK: 对应关系

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// 一个路径对应的那一行：它是源，或者是产物。
    func row(for path: String) -> FileRow? {
        rows.first { ConversionRecord.key($0.job.input) == path || $0.dest.map(ConversionRecord.key) == path }
    }

    /// 这个路径是不是这批转出来的产物。
    func isProduct(_ path: String) -> Bool {
        rows.contains { $0.dest.map(ConversionRecord.key) == path }
    }

    /// 这一行的源是相机 RAW（按扩展名，与图库的格式同一个判定）。
    static func isRAWSource(_ row: FileRow) -> Bool { ImageFormat(url: row.job.input) == .raw }

    /// 源文件按 Eclose 的规则被删掉了：勾了删除、源不是 RAW（RAW 原片永远保留）、校验无差异、
    /// 产物不比源大。
    func sourceDeleted(_ row: FileRow) -> Bool {
        guard deleteRequested, !ConversionRecord.isRAWSource(row), row.status == .done, row.verification == .passed
        else { return false }
        return growthPercent(inBytes: row.inBytes, outBytes: row.outBytes) == nil
    }

    static func mark(of row: FileRow) -> ConversionMark? {
        switch row.status {
        case .pending: return nil
        case .running: return .running
        case .skipped: return .skipped
        case .failed: return .failed
        case .done:
            switch row.verification {
            case .passed: return .passed
            case .notVerified: return .notVerified
            case .differences(let list): return .differences(list.count)
            }
        }
    }

    /// 一张图（源或产物）的转换状态；这批没碰过它是 nil。
    func mark(for path: String) -> ConversionMark? {
        row(for: path).flatMap(ConversionRecord.mark(of:))
    }

    // MARK: 「最近一次转换」

    private func included(_ row: FileRow, _ filter: ConversionFilter) -> Bool {
        switch filter {
        case .all: return row.status != .pending
        case .differences: return row.status == .done && row.verification.hasDifferences
        case .failures: if case .failed = row.status { return true }; return false
        }
    }

    /// 条目里显示哪些路径：有产物的显示产物（HEIF），没有产物的（失败、跳过、正在转）显示源文件。
    func displayedPaths(_ filter: ConversionFilter) -> [String] {
        rows.filter { included($0, filter) }.map { row in
            row.dest.map(ConversionRecord.key) ?? ConversionRecord.key(row.job.input)
        }
    }

    func count(_ filter: ConversionFilter) -> Int { rows.filter { included($0, filter) }.count }

    // MARK: 汇总

    struct Tally: Equatable {
        var total = 0
        var converted = 0
        var passed = 0
        var differences = 0
        var notVerified = 0
        var skipped = 0
        var failed = 0
        var grew = 0
        var pending = 0
        var inBytes = 0
        var outBytes = 0

        var saved: Int { inBytes - outBytes }
    }

    var tally: Tally {
        var t = Tally()
        t.total = rows.count
        for row in rows {
            switch row.status {
            case .pending, .running: t.pending += 1
            case .skipped: t.skipped += 1
            case .failed: t.failed += 1
            case .done:
                t.converted += 1
                t.inBytes += row.inBytes
                t.outBytes += row.outBytes
                if growthPercent(inBytes: row.inBytes, outBytes: row.outBytes) != nil { t.grew += 1 }
                switch row.verification {
                case .passed: t.passed += 1
                case .notVerified: t.notVerified += 1
                case .differences: t.differences += 1
                }
            }
        }
        return t
    }

    /// 已经有结局的张数（进度条和「已转 N 张」用）。
    var settledCount: Int { rows.filter(\.status.isSettled).count }

    /// `转完 195 张，省下 398 MB` 或 `转完 3 张，比源文件大 1.2 MB`；一张都没转成是 nil。
    var savingLine: String? {
        let t = tally
        guard t.converted > 0 else { return nil }
        return t.saved >= 0 ? "转完 \(t.converted) 张，省下 \(shortSize(t.saved))"
                            : "转完 \(t.converted) 张，比源文件大 \(shortSize(-t.saved))"
    }

    /// `412 MB → 14 MB`；一张都没转成是 nil。
    var volumeLine: String? {
        let t = tally
        guard t.converted > 0 else { return nil }
        return "\(shortSize(t.inBytes)) → \(shortSize(t.outBytes))"
    }

    /// 各类张数，零的不列。
    var classLines: [String] {
        let t = tally
        let pairs: [(String, Int)] = [("无差异", t.passed), ("有差异", t.differences), ("没有校验", t.notVerified),
                                      ("已跳过", t.skipped), ("失败", t.failed), ("HEIF 比源文件大", t.grew)]
        return pairs.filter { $0.1 > 0 }.map { "\($0.0) \($0.1) 张" }
    }

    /// 最常见的差异，前 `limit` 条：归并规则见 issueFamily，一张图里相同的只算一次；
    /// 张数多的在前，一样多的按文字排。
    func topDifferences(limit: Int = 5) -> [(family: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in rows {
            guard case .differences(let list) = row.verification else { continue }
            for family in Set(list.map(issueFamily)) { counts[family, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { ($0.key, $0.value) }
    }

    // MARK: 活动条

    /// 活动条的那句话。
    /// - 进行中：`正在转换　已转 82 张，共 196 张`
    /// - 转完：`转完 195 张，省下 398 MB。9 张有差异，1 张失败，它们的源文件都还在。`
    ///   没有的类不写；没开删除就不提源文件。`N 张有差异` 可以点。开了删除而这批里有 RAW 时，
    ///   末尾再加 `RAW 原片都留着。`
    /// - 取消：`已取消。转完 82 张，还有 114 张没转。`，后面同样跟着各类。
    var activitySentence: [SentencePart] {
        let t = tally
        if isRunning {
            return [SentencePart(text: "正在转换", emphasized: true),
                    SentencePart(text: "　已转 \(settledCount) 张，共 \(t.total) 张")]
        }
        var parts: [SentencePart] = []
        if wasCancelled {
            parts.append(SentencePart(text: "已取消。转完 \(t.converted) 张，还有 \(t.pending) 张没转。", emphasized: true))
        } else if let line = savingLine {
            parts.append(SentencePart(text: line + "。", emphasized: true))
        } else {
            parts.append(SentencePart(text: "一张都没转成。", emphasized: true))
        }
        var classes: [SentencePart] = []
        if t.differences > 0 {
            classes.append(SentencePart(text: "\(t.differences) 张有差异", link: .conversion(.differences)))
        }
        if deleteRequested && t.grew > 0 { classes.append(SentencePart(text: "\(t.grew) 张 HEIF 比源文件大")) }
        if t.skipped > 0 { classes.append(SentencePart(text: "\(t.skipped) 张跳过")) }
        if t.failed > 0 { classes.append(SentencePart(text: "\(t.failed) 张失败", link: .conversion(.failures))) }
        for (i, part) in classes.enumerated() {
            if i > 0 { parts.append(SentencePart(text: "，")) }
            parts.append(part)
        }
        if !classes.isEmpty { parts.append(SentencePart(text: deleteRequested ? "，它们的源文件都还在。" : "。")) }
        // 勾了删除、这批里又有 RAW：说一句 RAW 没删，免得以为漏删了。
        if deleteRequested && rows.contains(where: ConversionRecord.isRAWSource) {
            parts.append(SentencePart(text: "RAW 原片都留着。"))
        }
        return parts
    }

    /// 整句话的纯文本。
    var activityText: String { activitySentence.map(\.text).joined() }
}

// MARK: - 一张图的描述

/// 缩略图单元的无障碍描述：`IMG_2026.jpg，JPEG，3.3 MB，有备注，转换时有 2 处差异`。
func accessibilityDescription(_ item: PhotoItem, mark: ConversionMark?) -> String {
    var parts = [item.name, item.format.label, shortSize(item.size)]
    if item.hasNotes { parts.append("有备注") }
    if let mark { parts.append(mark.spokenText) }
    return parts.joined(separator: "，")
}

/// 画质滑杆旁的提示语（取值范围 0.4–1.0，与命令行同一套语义）。
func qualityHint(_ quality: Double) -> String {
    switch quality {
    case ..<0.6: return "体积最小，画质损失明显"
    case ..<0.86: return "日常存档的推荐区间"
    case ..<0.96: return "接近原画质，文件更大"
    default: return "几乎不压缩，体积可能超过源文件"
    }
}

/// 信息栏「转换结果」一组里体积的两行：`3.3 MB → 989 KB`，下一行 `省 71%` 或 `比源文件大 33%`。
func volumeLines(inBytes: Int, outBytes: Int) -> (String, String?) {
    let head = "\(shortSize(inBytes)) → \(shortSize(outBytes))"
    if let growth = growthPercent(inBytes: inBytes, outBytes: outBytes) { return (head, "比源文件大 \(growth)") }
    guard let pct = percentSaved(inBytes: inBytes, outBytes: outBytes) else { return (head, nil) }
    return (head, "省 \(pct)%")
}

/// 「转换结果」一组的标题：`转换时无差异` / `转换时有 N 处差异` / `没有校验` / `转换失败` 等。
func verdictTitle(_ mark: ConversionMark) -> String {
    switch mark {
    case .running: return "正在转换"
    case .passed: return "转换时无差异"
    case .notVerified: return "没有校验"
    case .differences(let n): return "转换时有 \(n) 处差异"
    case .skipped: return "没有转换"
    case .failed: return "转换失败"
    }
}
