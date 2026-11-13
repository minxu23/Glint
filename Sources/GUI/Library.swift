// 图库：用户加进来的文件夹和单独的图片 → 扫描出的条目 → 侧栏各条目里的图片、张数、
// 副标题、汇总。
//
// 分两层：
// - `Library` 是值类型，只有数据和纯函数（过滤、排序、搜索、计数、文件夹树、副标题），
//   Tests/guimodel 直接喂数据测；
// - `LibraryModel` 把扫描和读元数据放到后台队列，结果回到主线程并进 `Library`。
//   扫描器和读取器都可以注入，测试用假的。
//
// 不依赖 AppKit。

import Foundation

// MARK: - 条目

/// 列文件那一步得到的东西：只有文件系统给的，不打开文件。
struct FileEntry: Equatable {
    let url: URL
    let size: Int
    let modified: Date
}

/// 图库里的一张图。
struct PhotoItem {
    let url: URL
    var size: Int
    var modified: Date
    let format: ImageFormat
    /// 它属于哪个已添加的文件夹（最外层那个）；单独添加的、文件夹之外的转换产物是 nil。
    var root: URL?
    /// 单独添加的图片。
    var isLoose = false
    /// 后台补上的元数据；还没读到是 nil。
    var info: PhotoInfo?

    init(url: URL, size: Int, modified: Date, root: URL? = nil, isLoose: Bool = false, info: PhotoInfo? = nil) {
        self.url = url.standardizedFileURL
        self.size = size
        self.modified = modified
        self.format = ImageFormat(url: url)
        self.root = root
        self.isLoose = isLoose
        self.info = info
    }

    init(_ entry: FileEntry, root: URL?) {
        self.init(url: entry.url, size: entry.size, modified: entry.modified, root: root)
    }

    var path: String { url.path }
    var name: String { url.lastPathComponent }
    var isJPEG: Bool { format == .jpeg }
    var isRAW: Bool { format == .raw }
    /// 能转：JPEG 或相机 RAW（按扩展名；转不转最终由 Eclose 按内容判定）。
    var isConvertible: Bool { format.sourceKind != nil }
    var hasNotes: Bool { info?.hasNotes ?? false }

    /// 排序用的拍摄时间：没有拍摄时间（或还没读到）时用修改时间。
    var sortTime: CaptureTime { info?.captured ?? CaptureTime(date: modified) }

    /// 搜索：文件名和备注，不分大小写。备注要等元数据读到才搜得到。
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        if name.range(of: q, options: [.caseInsensitive]) != nil { return true }
        return info?.notes.contains { $0.text.range(of: q, options: [.caseInsensitive]) != nil } ?? false
    }
}

/// `path` 是否在 `folder` 里（任意深度）。
func isPath(_ path: String, inside folder: String) -> Bool {
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    return path.hasPrefix(prefix)
}

// MARK: - 侧栏条目

/// 「最近一次转换」下的三种视图。
enum ConversionFilter: Hashable {
    case all, differences, failures
}

/// 侧栏上能选中的一项。
enum LibraryEntry: Hashable {
    case all
    case convertible
    case withNotes
    case conversion(ConversionFilter)
    /// 一个文件夹（已添加的，或它的子文件夹），按标准化路径。
    case folder(String)
    /// 单独添加的图片。
    case looseFiles

    /// 工具栏标题，也用在转换面板的说明里。
    func title(folderName: (String) -> String = { ($0 as NSString).lastPathComponent }) -> String {
        switch self {
        case .all: return "全部图片"
        case .convertible: return "可以转换"
        case .withNotes: return "有备注"
        case .conversion(.all): return "最近一次转换"
        case .conversion(.differences): return "有差异"
        case .conversion(.failures): return "失败"
        case .folder(let path): return folderName(path)
        case .looseFiles: return "单独添加的图片"
        }
    }
}

// MARK: - 排序

enum SortKey: String, CaseIterable {
    case captured, name, size, format

    var title: String {
        switch self {
        case .captured: return "拍摄时间"
        case .name: return "文件名"
        case .size: return "大小"
        case .format: return "格式"
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey = .captured
    var ascending = true
}

/// 按给定顺序排。相同的按文件名、再按路径定先后，保证结果稳定。
func sorted(_ items: [PhotoItem], by order: SortOrder) -> [PhotoItem] {
    func byName(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        let r = a.name.localizedStandardCompare(b.name)
        return r == .orderedSame ? a.path < b.path : r == .orderedAscending
    }
    return items.sorted { a, b in
        let primary: ComparisonResult
        switch order.key {
        case .captured:
            primary = a.sortTime == b.sortTime ? .orderedSame : (a.sortTime < b.sortTime ? .orderedAscending : .orderedDescending)
        case .name:
            primary = a.name.localizedStandardCompare(b.name)
        case .size:
            primary = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
        case .format:
            primary = a.format.sortKey.compare(b.format.sortKey)
        }
        if primary == .orderedSame { return order.ascending ? byName(a, b) : byName(b, a) }
        return order.ascending ? primary == .orderedAscending : primary == .orderedDescending
    }
}

// MARK: - 文件夹树

/// 侧栏「文件夹」下的一个节点。
struct FolderNode: Equatable {
    let path: String
    let name: String
    var count: Int
    var children: [FolderNode]
    /// 已添加的文件夹在磁盘上找不到了。
    var missing = false
}

// MARK: - 图库

struct Library {
    /// 用户加进来的文件夹（标准化路径），按添加顺序。
    private(set) var folders: [String] = []
    /// 单独添加的图片（标准化路径）。
    private(set) var looseFiles: [String] = []
    /// 在磁盘上找不到的已添加文件夹。
    var missingFolders = Set<String>()
    /// 正在扫描的已添加文件夹。
    var scanning = Set<String>()
    /// 全部条目，按标准化路径。
    private(set) var items: [String: PhotoItem] = [:]

    var isEmpty: Bool { folders.isEmpty && looseFiles.isEmpty }

    // MARK: 来源

    /// 加一个文件夹；已经有了返回 false。
    @discardableResult
    mutating func addFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !folders.contains(path) else { return false }
        folders.append(path)
        reassignRoots()
        return true
    }

    /// 从侧栏移除（不动磁盘）：它下面的条目里，不再属于任何已添加文件夹、也不是单独添加的，一并去掉。
    mutating func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        missingFolders.remove(path)
        scanning.remove(path)
        reassignRoots()
        items = items.filter { $0.value.root != nil || $0.value.isLoose || !isPath($0.key, inside: path) }
    }

    /// 单独添加一张图。
    mutating func addLooseFile(_ entry: FileEntry) {
        let path = entry.url.standardizedFileURL.path
        if !looseFiles.contains(path) { looseFiles.append(path) }
        var item = items[path] ?? PhotoItem(entry, root: nil)
        item.isLoose = true
        item.size = entry.size
        item.modified = entry.modified
        item.root = root(for: path)
        items[path] = item
    }

    /// 最外层的、包含 `path` 的已添加文件夹。
    func root(for path: String) -> URL? {
        folders.filter { isPath(path, inside: $0) }.min { $0.count < $1.count }.map { URL(fileURLWithPath: $0) }
    }

    private mutating func reassignRoots() {
        for key in Array(items.keys) {
            let r = root(for: key)
            items[key]?.root = r
        }
    }

    // MARK: 扫描结果

    /// 并入扫描出来的一批。大小和修改时间都没变的条目保留已经读到的元数据。
    /// 返回需要（重新）读元数据的路径。
    @discardableResult
    mutating func merge(_ entries: [FileEntry]) -> [String] {
        var needInfo: [String] = []
        for entry in entries {
            let path = entry.url.standardizedFileURL.path
            if var existing = items[path] {
                if existing.size != entry.size || existing.modified != entry.modified {
                    existing.size = entry.size
                    existing.modified = entry.modified
                    existing.info = nil
                    needInfo.append(path)
                }
                existing.root = root(for: path)
                items[path] = existing
            } else {
                items[path] = PhotoItem(entry, root: root(for: path))
                needInfo.append(path)
            }
        }
        return needInfo
    }

    /// 一个文件夹扫完：它下面这次没扫到的条目（文件被删了、被挪走了）去掉，单独添加的除外。
    mutating func finishScan(of folder: String, seen: Set<String>) {
        scanning.remove(folder)
        items = items.filter { key, item in
            item.isLoose || !isPath(key, inside: folder) || seen.contains(key)
        }
    }

    /// 一张单独添加的图在磁盘上不见了。
    mutating func dropLooseFile(_ path: String) {
        looseFiles.removeAll { $0 == path }
        if var item = items[path] {
            item.isLoose = false
            if item.root == nil { items[path] = nil } else { items[path] = item }
        }
    }

    /// 转换刚产出的文件（还没重新扫描）：先按转换报告里的大小放进来，元数据随后补。
    /// 在已添加文件夹之外的产物只出现在「最近一次转换」里。返回是否新加了条目。
    @discardableResult
    mutating func adoptProduct(_ entry: FileEntry) -> Bool {
        let path = entry.url.standardizedFileURL.path
        guard items[path] == nil else { return false }
        items[path] = PhotoItem(entry, root: root(for: path))
        return true
    }

    /// 删掉一个条目（转换时源文件被删除）。只改图库，不碰磁盘。
    mutating func removeItem(_ path: String) {
        items[path] = nil
        looseFiles.removeAll { $0 == path }
    }

    mutating func setInfo(_ info: PhotoInfo, for path: String) {
        items[path]?.info = info
    }

    // MARK: 视图

    /// 能出现在「全部图片」里的：已添加文件夹里的，和单独添加的。
    private var listed: [PhotoItem] { items.values.filter { $0.root != nil || $0.isLoose } }

    /// 侧栏条目里的图片（未排序、未搜索）。转换相关的条目要给转换记录。
    func items(in entry: LibraryEntry, record: ConversionRecord? = nil) -> [PhotoItem] {
        switch entry {
        case .all: return listed
        case .convertible: return listed.filter(\.isConvertible)
        case .withNotes: return listed.filter(\.hasNotes)
        case .folder(let path): return listed.filter { isPath($0.path, inside: path) }
        case .looseFiles: return items.values.filter(\.isLoose)
        case .conversion(let filter):
            guard let record else { return [] }
            return record.displayedPaths(filter).compactMap { items[$0] }
        }
    }

    /// 当前视图：条目里的图片，按搜索词过滤、按顺序排好。
    func visibleItems(in entry: LibraryEntry, record: ConversionRecord?, search: String, order: SortOrder) -> [PhotoItem] {
        sorted(items(in: entry, record: record).filter { $0.matches(search) }, by: order)
    }

    /// 侧栏上的张数。
    func count(of entry: LibraryEntry, record: ConversionRecord? = nil) -> Int {
        if case .conversion(let filter) = entry { return record?.count(filter) ?? 0 }
        return items(in: entry, record: record).count
    }

    /// 侧栏「文件夹」下的树：每个已添加文件夹一棵，子节点只列里面（含更深处）有图片的子文件夹。
    func folderTree() -> [FolderNode] {
        let all = listed
        return folders.map { root in
            var node = FolderNode(path: root, name: (root as NSString).lastPathComponent, count: 0, children: [],
                                  missing: missingFolders.contains(root))
            for item in all where isPath(item.path, inside: root) {
                node.count += 1
                let rel = String(item.path.dropFirst(root.count + 1))
                let dirs = (rel as NSString).deletingLastPathComponent
                guard !dirs.isEmpty else { continue }
                insert(dirs.split(separator: "/").map(String.init), under: &node)
            }
            sortChildren(&node)
            return node
        }
    }

    private func insert(_ components: [String], under node: inout FolderNode) {
        guard let first = components.first else { return }
        let path = node.path + "/" + first
        if let i = node.children.firstIndex(where: { $0.path == path }) {
            node.children[i].count += 1
            insert(Array(components.dropFirst()), under: &node.children[i])
        } else {
            var child = FolderNode(path: path, name: first, count: 1, children: [])
            insert(Array(components.dropFirst()), under: &child)
            node.children.append(child)
        }
    }

    private func sortChildren(_ node: inout FolderNode) {
        node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for i in node.children.indices { sortChildren(&node.children[i]) }
    }
}

// MARK: - 副标题与汇总

/// 工具栏副标题：`248 张，其中 JPEG 196 张、RAW 30 张，共 612 MB`（能转的两种，没有的那种不写）；
/// 有选中时 `选中 3 张，共 6.6 MB`；还在扫描时末尾加 `，正在读取…`。
///
/// `detailed` 为 false 时去掉「其中 …」那段：`248 张，共 612 MB`。窗口窄、标题栏放不下完整的
/// 那句时用（见 MainWindowController.fitSubtitle），按格式的张数和大小信息栏里有。
func subtitle(items: [PhotoItem], selected: [PhotoItem], scanning: Bool, detailed: Bool = true) -> String {
    var text: String
    if !selected.isEmpty {
        text = "选中 \(selected.count) 张，共 \(shortSize(selected.reduce(0) { $0 + $1.size }))"
    } else {
        let total = items.reduce(0) { $0 + $1.size }
        text = "\(items.count) 张"
        let kinds = convertibleCounts(items)
        if detailed && !kinds.isEmpty { text += "，其中 " + kinds }
        if !items.isEmpty { text += "，共 \(shortSize(total))" }
    }
    if scanning { text += "，正在读取…" }
    return text
}

/// 能转的两种各几张：`JPEG 196 张、RAW 30 张`，没有的那种不写；一张都没有是空串。
func convertibleCounts(_ items: [PhotoItem]) -> String {
    let jpegs = items.filter(\.isJPEG).count
    let raws = items.filter(\.isRAW).count
    var parts: [String] = []
    if jpegs > 0 { parts.append("JPEG \(jpegs) 张") }
    if raws > 0 { parts.append("RAW \(raws) 张") }
    return parts.joined(separator: "、")
}

/// 信息栏在选中多张或没选中时的汇总（第 7.3 节，不含转换汇总）。
struct ItemsSummary: Equatable {
    /// `选中 12 张`；没选中时是 nil（标题由当前条目给）。
    var title: String?
    /// `JPEG 10 张，共 31 MB` 这样的每种格式一行，JPEG、RAW、HEIF 在前。
    var formatLines: [String]
    /// `有备注 3 张`；没有就是 nil。
    var notesLine: String?

    init(items: [PhotoItem], selected: Bool) {
        title = selected ? "选中 \(items.count) 张" : nil
        var groups: [ImageFormat: (count: Int, bytes: Int)] = [:]
        for item in items { groups[item.format, default: (0, 0)].count += 1; groups[item.format]!.bytes += item.size }
        formatLines = groups.sorted { $0.key.sortKey < $1.key.sortKey }
            .map { "\($0.key.label) \($0.value.count) 张，共 \(shortSize($0.value.bytes))" }
        let notes = items.filter(\.hasNotes).count
        notesLine = notes > 0 ? "有备注 \(notes) 张" : nil
    }
}

// MARK: - 后台扫描与读取

/// 递归列出一个文件夹里的图片，分批交给 `deliver`（先出来的先显示）。在后台队列上调用。
typealias FolderScanner = (_ folder: URL, _ deliver: ([FileEntry]) -> Void) -> Void
/// 读一张图的元数据。在后台队列上调用。
typealias InfoReader = (URL) -> PhotoInfo
/// 取一个路径的文件信息；不存在或不是普通文件是 nil。在后台队列上调用。
typealias FileStatter = (URL) -> FileEntry?

/// 默认的扫描器：跳过隐藏文件和包内容，只收 UTType 符合 public.image 的，每 200 个交一批。
func scanFolderOnDisk(_ folder: URL, deliver: ([FileEntry]) -> Void) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
    var batch: [FileEntry] = []
    while let url = e.nextObject() as? URL {
        guard ImageFormat.isImage(url),
              let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
        batch.append(FileEntry(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
        if batch.count >= 200 { deliver(batch); batch = [] }
    }
    if !batch.isEmpty { deliver(batch) }
}

/// 默认的文件信息读取。
func statFileOnDisk(_ url: URL) -> FileEntry? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
          values.isRegularFile == true else { return nil }
    return FileEntry(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
}

/// 文件夹是否存在。
func folderExistsOnDisk(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

/// 图库的调度：扫描和读元数据都在后台，结果回主线程并进 `library`，再通知视图。
final class LibraryModel {
    private(set) var library = Library()

    /// 来源、条目或张数变了。合并过的通知，一批扫描结果只通知一次。
    var onChange: (() -> Void)?
    /// 这些路径的元数据读到了（信息栏、备注标记、搜索据此刷新）。
    var onInfo: ((Set<String>) -> Void)?
    /// 已添加的文件夹变了（视图据此存设置）。
    var onFoldersChange: (([String]) -> Void)?

    private let scanner: FolderScanner
    private let reader: InfoReader
    private let statter: FileStatter
    private let folderExists: (URL) -> Bool
    private let scanQueue = DispatchQueue(label: "吉光.scan", qos: .userInitiated, attributes: .concurrent)
    private let infoQueue: OperationQueue
    /// 每个文件夹的扫描代数：重新扫描或移除后，旧扫描交回来的结果作废。
    private var generations: [String: Int] = [:]
    /// 读到的元数据先攒着，隔一小段时间一起交给主线程，免得两千张图刷两千次。
    private let pendingLock = NSLock()
    private var pendingInfo: [String: PhotoInfo] = [:]
    private var flushScheduled = false

    init(scanner: @escaping FolderScanner = scanFolderOnDisk,
         reader: @escaping InfoReader = PhotoInfo.read,
         statter: @escaping FileStatter = statFileOnDisk,
         folderExists: @escaping (URL) -> Bool = folderExistsOnDisk,
         infoConcurrency: Int = 2) {
        self.scanner = scanner
        self.reader = reader
        self.statter = statter
        self.folderExists = folderExists
        infoQueue = OperationQueue()
        infoQueue.maxConcurrentOperationCount = infoConcurrency
        infoQueue.qualityOfService = .utility
    }

    /// 是否还有扫描或元数据读取没做完。
    var isBusy: Bool { !library.scanning.isEmpty || infoQueue.operationCount > 0 || hasPendingInfo }

    private var hasPendingInfo: Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return !pendingInfo.isEmpty || flushScheduled
    }

    // MARK: 来源

    func addFolders(_ urls: [URL]) {
        var added: [String] = []
        for url in urls where library.addFolder(url) { added.append(url.standardizedFileURL.path) }
        guard !added.isEmpty else { return }
        onFoldersChange?(library.folders)
        onChange?()
        for path in added { scan(path) }
    }

    func removeFolder(_ path: String) {
        generations[path, default: 0] += 1
        library.removeFolder(path)
        onFoldersChange?(library.folders)
        onChange?()
    }

    /// 单独添加图片；不是图片的忽略。
    func addFiles(_ urls: [URL]) {
        let candidates = urls.filter(ImageFormat.isImage)
        guard !candidates.isEmpty else { return }
        scanQueue.async { [weak self, statter] in
            let entries = candidates.compactMap(statter)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for e in entries { self.library.addLooseFile(e) }
                self.onChange?()
                self.readInfo(entries.map { $0.url.standardizedFileURL.path })
            }
        }
    }

    /// 重新读取全部来源（⌘R、切回应用）。
    func reload() {
        for path in library.folders { scan(path) }
        recheckLooseFiles(library.looseFiles)
    }

    /// 重新读取包含这些路径的已添加文件夹，以及这些路径里单独添加的图片（转完以后）。
    func reload(affecting paths: [String]) {
        let folders = library.folders.filter { folder in paths.contains { isPath($0, inside: folder) } }
        for path in folders { scan(path) }
        let loose = library.looseFiles.filter(paths.contains)
        recheckLooseFiles(loose)
    }

    /// 转换刚产出的文件：按报告里的大小先放进来，后台补元数据。
    func adoptProduct(url: URL, size: Int) {
        let entry = FileEntry(url: url, size: size, modified: Date())
        if library.adoptProduct(entry) {
            onChange?()
            readInfo([entry.url.standardizedFileURL.path])
        }
    }

    /// 转换时源文件被删了：从图库里拿掉（不碰磁盘）。之后的重新读取以磁盘为准。
    func forgetItem(_ path: String) {
        library.removeItem(path)
        onChange?()
    }

    // MARK: 内部

    private func scan(_ folder: String) {
        let generation = (generations[folder] ?? 0) + 1
        generations[folder] = generation
        library.scanning.insert(folder)
        onChange?()
        let url = URL(fileURLWithPath: folder)
        scanQueue.async { [weak self, scanner, folderExists] in
            let exists = folderExists(url)
            var seen = Set<String>()
            if exists {
                scanner(url) { batch in
                    seen.formUnion(batch.map { $0.url.standardizedFileURL.path })
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generations[folder] == generation else { return }
                        let need = self.library.merge(batch)
                        self.onChange?()
                        self.readInfo(need)
                    }
                }
            }
            let finalSeen = seen
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generations[folder] == generation else { return }
                if exists { self.library.missingFolders.remove(folder) } else { self.library.missingFolders.insert(folder) }
                self.library.finishScan(of: folder, seen: finalSeen)
                self.onChange?()
            }
        }
    }

    private func recheckLooseFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        scanQueue.async { [weak self, statter] in
            let found = paths.map { (path: $0, entry: statter(URL(fileURLWithPath: $0))) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var need: [String] = []
                for (path, entry) in found {
                    if let entry { self.library.addLooseFile(entry); need.append(path) } else { self.library.dropLooseFile(path) }
                }
                self.onChange?()
                self.readInfo(need)
            }
        }
    }

    private func readInfo(_ paths: [String]) {
        for path in paths {
            infoQueue.addOperation { [weak self, reader] in
                let info = reader(URL(fileURLWithPath: path))
                self?.enqueue(info, for: path)
            }
        }
    }

    private func enqueue(_ info: PhotoInfo, for path: String) {
        pendingLock.lock()
        pendingInfo[path] = info
        let schedule = !flushScheduled
        flushScheduled = true
        pendingLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flushInfo() }
    }

    private func flushInfo() {
        pendingLock.lock()
        let batch = pendingInfo
        pendingInfo = [:]
        flushScheduled = false
        pendingLock.unlock()
        var changed = Set<String>()
        for (path, info) in batch where library.items[path] != nil {
            library.setInfo(info, for: path)
            changed.insert(path)
        }
        guard !changed.isEmpty else { return }
        onInfo?(changed)
    }
}
