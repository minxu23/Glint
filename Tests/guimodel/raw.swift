// 界面模型测试的第三部分：相机 RAW（eclose 第 2 段 b）。图库认 RAW、「可以转换」与副标题数 RAW、
// 转换的对象 JPEG 与 RAW 混着、删除只对 JPEG 生效、RAW 永不删除、RAW 的信息与缩略图。
// 由 guimodel 的 main.swift 调用（第 10 部分）。要真 RAW 的用例用
// Tests/DNG.swift 现场生成的 DNG（256×192 以上，过 ImageIO 认作 RAW 的门槛；更小的会被当成 TIFF，
// 所以先断言类型是 RAW）。

@testable import Eclose
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 格式与图库（纯数据）

func testRAWLibrary() {
    print("RAW：格式")
    check("常见的 RAW 扩展名都认作 RAW（不分大小写）",
          ["a.CR3", "a.cr2", "a.NEF", "a.arw", "a.dng", "a.RAF", "a.orf", "a.rw2"].map { ImageFormat(url: URL(fileURLWithPath: "/库/\($0)")) },
          Array(repeating: ImageFormat.raw, count: 8))
    let notRAW = SourceKind.raw.extensions.filter { ImageFormat(url: URL(fileURLWithPath: "/库/x.\($0)")) != .raw }
    check("与命令行同一份扩展名清单：清单里的每一个都认作 RAW", notRAW.sorted(), [])
    check("TIFF 不算 RAW（佳能的 tif RAW 不在清单里）", ImageFormat(url: URL(fileURLWithPath: "/库/x.tif")), .other("TIFF"))
    check("RAW 统一叫「RAW」", ImageFormat.raw.label, "RAW")
    check("能转的源：JPEG、RAW；别的不能转", [ImageFormat.jpeg, .raw, .heif, .other("PNG")].map(\.sourceKind),
          [.jpeg, .raw, nil, nil])
    check("扫描时 RAW 算图片", ["a.CR3", "a.dng", "a.nef"].map { ImageFormat.isImage(URL(fileURLWithPath: "/库/\($0)")) },
          [true, true, true])

    print("RAW：图库的计数、副标题与汇总")
    let mb = 1024 * 1024
    var lib = Library()
    lib.addFolder(URL(fileURLWithPath: "/库"))
    lib.merge([
        FileEntry(url: URL(fileURLWithPath: "/库/a.jpg"), size: 2 * mb, modified: Date(timeIntervalSince1970: 1)),
        FileEntry(url: URL(fileURLWithPath: "/库/b.JPG"), size: 2 * mb, modified: Date(timeIntervalSince1970: 2)),
        FileEntry(url: URL(fileURLWithPath: "/库/c.CR3"), size: 25 * mb, modified: Date(timeIntervalSince1970: 3)),
        FileEntry(url: URL(fileURLWithPath: "/库/子/d.dng"), size: 20 * mb, modified: Date(timeIntervalSince1970: 4)),
        FileEntry(url: URL(fileURLWithPath: "/库/e.heic"), size: mb, modified: Date(timeIntervalSince1970: 5)),
        FileEntry(url: URL(fileURLWithPath: "/库/f.png"), size: mb, modified: Date(timeIntervalSince1970: 6)),
    ])
    check("「可以转换」收 JPEG 和 RAW", Set(names(lib.items(in: .convertible))), ["a.jpg", "b.JPG", "c.CR3", "d.dng"])
    check("「可以转换」的张数", lib.count(of: .convertible), 4)
    check("副标题数 JPEG 也数 RAW", subtitle(items: lib.items(in: .all), selected: [], scanning: false),
          "6 张，其中 JPEG 2 张、RAW 2 张，共 51 MB")
    check("只有 RAW 时副标题只写 RAW", subtitle(items: lib.items(in: .folder("/库/子")), selected: [], scanning: false),
          "1 张，其中 RAW 1 张，共 20 MB")
    check("窄窗口的短写法去掉「其中 …」", subtitle(items: lib.items(in: .all), selected: [], scanning: true, detailed: false),
          "6 张，共 51 MB，正在读取…")
    check("有选中时短写法与完整写法相同",
          subtitle(items: lib.items(in: .all), selected: lib.items(in: .convertible), scanning: false, detailed: false),
          subtitle(items: lib.items(in: .all), selected: lib.items(in: .convertible), scanning: false))
    check("一张能转的都没有时不写「其中」", subtitle(items: lib.items(in: .all).filter { !$0.isConvertible }, selected: [], scanning: false),
          "2 张，共 2.0 MB")
    check("按格式的汇总：JPEG、RAW、HEIF 在前", ItemsSummary(items: lib.items(in: .all), selected: false).formatLines,
          ["JPEG 2 张，共 4.0 MB", "RAW 2 张，共 45 MB", "HEIF 1 张，共 1.0 MB", "PNG 1 张，共 1.0 MB"])
    check("按格式排：JPEG、RAW、HEIF、其它",
          names(sorted(lib.items(in: .all), by: SortOrder(key: .format, ascending: true))),
          ["a.jpg", "b.JPG", "c.CR3", "d.dng", "e.heic", "f.png"])
    check("RAW 的无障碍描述带格式", accessibilityDescription(item("/库/c.CR3", size: 25 * mb), mark: nil), "c.CR3，RAW，25 MB")
}

// MARK: - 转换的对象（纯数据）

func testRAWTargets() {
    print("RAW：转换的对象")
    let mb = 1024 * 1024
    let j1 = item("/库/春/a.jpg", size: 2 * mb, root: "/库")
    let j2 = item("/库/春/b.jpg", size: 2 * mb, root: "/库")
    let r1 = item("/库/春/c.CR3", size: 24 * mb, root: "/库")
    let r2 = item("/库/春/子/d.dng", size: 20 * mb, root: "/库")
    let h = item("/库/春/e.heic", size: mb, root: "/库")

    let mixed = ConversionTargets(selected: [j1, r1, h], visible: [j1, j2, r1, r2, h], entry: .all, entryName: "全部图片", search: "")
    check("选中里混着 JPEG 和 RAW：两种都转，别的不动", names(mixed.items), ["a.jpg", "c.CR3"])
    check("两种各几张", [mixed.jpegCount, mixed.rawCount], [1, 1])
    check("混着时的标题", mixed.title, "转换 2 张（JPEG 1 张、RAW 1 张）")
    check("混着时选中的说明", mixed.detail, "选中的 2 张 JPEG 和 RAW，共 26 MB。别的格式不动。")
    check("RAW 也进了任务", mixed.jobs.map { $0.input.lastPathComponent }, ["a.jpg", "c.CR3"])

    let rawOnly = ConversionTargets(selected: [], visible: [r1, r2, h], entry: .folder("/库/春"), entryName: "春", search: "")
    check("只有 RAW 的标题", rawOnly.title, "转换 2 张 RAW")
    check("只有 RAW 时当前视图的说明", rawOnly.detail, "「春」里的全部 RAW，共 44 MB。别的格式不动。")
    check("RAW 的相对路径同样保留子目录", rawOnly.jobs.map(\.relative), ["c.CR3", "子/d.dng"])

    let searched = ConversionTargets(selected: [], visible: [j1, r1], entry: .all, entryName: "全部图片", search: "春")
    check("混着时搜索的说明", searched.detail, "「全部图片」里符合「春」的 JPEG 和 RAW，共 26 MB。")
    check("只有 JPEG 时照旧", ConversionTargets(selected: [j1, j2], visible: [], entry: .all, entryName: "", search: "").title,
          "转换 2 张 JPEG")
    let none = ConversionTargets(selected: [h], visible: [], entry: .all, entryName: "", search: "")
    check(none.isEmpty, "只有 HEIF 时对象为空")
    check("对象为空时按钮的提示", ConversionTargets.emptyHint, "这里没有可以转换的 JPEG 或 RAW")

    print("RAW：删除源文件只对 JPEG 生效")
    let jpegOnly = ConversionTargets(selected: [j1, j2], visible: [], entry: .all, entryName: "", search: "")
    check("只有 JPEG：删除选项照旧", jpegOnly.deleteChoice,
          .offered(title: "校验无差异后删除源文件", hint: "有差异的、HEIF 反而更大的，源文件都留着", primary: "转换并删除源文件"))
    check("混着 RAW：选项写明只删 JPEG、RAW 原片始终保留", mixed.deleteChoice,
          .offered(title: "校验无差异后删除源 JPEG", hint: "这批里的 1 张 RAW 原片始终保留；有差异的、HEIF 反而更大的 JPEG 也留着",
                   primary: "转换并删除源 JPEG"))
    check("只有 RAW：没有删除选项，明写不删", rawOnly.deleteChoice, .unavailable("RAW 原片始终保留，不删除"))

    var deleting = PanelSettings.defaults
    deleting.deleteOriginal = true
    check("混着 RAW 勾了删除：这批要删（只删 JPEG）", mixed.deletes(deleting), true)
    check("只有 RAW 时就算设置里是勾着的也不删", rawOnly.deletes(deleting), false)
    check("主按钮：混着 RAW", mixed.primaryTitle(deleting), "转换并删除源 JPEG")
    check("主按钮：只有 RAW", rawOnly.primaryTitle(deleting), "转换")

    print("RAW：落到 ConversionOptions 上")
    var opts = ConversionOptions.default
    mixed.apply(deleting, to: &opts)
    check("混着时两种源都收", opts.sources, [.jpeg, .raw])
    check("有 RAW 时并发数用 RAW 的默认值", opts.jobs, ConversionOptions.defaultRAWJobs)
    check("混着时删除照样交给 Eclose（RAW 由它跳过）", [opts.deleteOriginal, opts.verifyEnabled], [true, true])
    var rawOpts = ConversionOptions.default
    rawOnly.apply(deleting, to: &rawOpts)
    check("只有 RAW：删除关掉", rawOpts.deleteOriginal, false)
    check("只有 RAW：两种源都收", rawOpts.sources, [.jpeg, .raw])
    var jpegOpts = ConversionOptions.default
    jpegOpts.jobs = 1
    jpegOnly.apply(PanelSettings.defaults, to: &jpegOpts)
    check("只有 JPEG：两种源都收（每张按内容分派）", jpegOpts.sources, [.jpeg, .raw])
    check("只有 JPEG：并发数回到默认的核数", jpegOpts.jobs, ConversionOptions.default.jobs)
}

// MARK: - 转换记录（纯数据）

func testRAWRecord() {
    print("RAW：转换记录")
    let mb = 1024 * 1024
    let rows = [
        row("a.jpg", .done, inBytes: 4 * mb, outBytes: mb, verification: .passed, dest: "/库/a.heic"),
        row("c.CR3", .done, inBytes: 24 * mb, outBytes: 4 * mb, verification: .passed, dest: "/库/c.heic"),
        row("d.dng", .done, inBytes: 20 * mb, outBytes: 4 * mb, verification: .differences(["GPS 精度降低：最大偏差 3 厘米"]),
            dest: "/库/d.heic"),
    ]
    let deleted = ConversionRecord(rows: rows, deleteRequested: true)
    check("勾了删除：只有 JPEG 的源算删掉，无差异的 RAW 也不算", rows.map { deleted.sourceDeleted($0) }, [true, false, false])
    check("RAW 的源按扩展名认", rows.map(ConversionRecord.isRAWSource), [false, true, true])
    check("勾了删除、批里有 RAW：说一句 RAW 原片都留着", deleted.activityText,
          "转完 3 张，省下 39 MB。1 张有差异，它们的源文件都还在。RAW 原片都留着。")
    let kept = ConversionRecord(rows: rows, deleteRequested: false)
    check("没勾删除：不提 RAW", kept.activityText, "转完 3 张，省下 39 MB。1 张有差异。")
    check("只有无差异的 JPEG 和 RAW、勾了删除", ConversionRecord(rows: Array(rows.prefix(2)), deleteRequested: true).activityText,
          "转完 2 张，省下 23 MB。RAW 原片都留着。")
    check("RAW 一样算进各类张数", kept.classLines, ["无差异 2 张", "有差异 1 张"])
    check("「最近一次转换」里 RAW 显示产物", kept.displayedPaths(.all).map { ($0 as NSString).lastPathComponent },
          ["a.heic", "c.heic", "d.heic"])
    check("RAW 的源与产物都找得到那一行", [kept.mark(for: "/库/d.dng"), kept.mark(for: "/库/d.heic")],
          [.differences(1), .differences(1)])
}

// MARK: - 真 DNG：信息、缩略图、扫描

/// 生成一张 DNG 并确认 ImageIO 把它认作 RAW（门槛下的会被当成 TIFF，后面的断言就失去意义）。
func writeDNG(_ url: URL, orientation: Int = 1) -> Bool {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var spec = DNGSpec()
    spec.orientation = orientation
    guard (try? makeDNG(spec).write(to: url)) != nil,
          let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return isCameraRAW(src)
}

func testRAWOnDisk(_ dir: URL) {
    print("RAW：从真 DNG 读信息")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let dng = dir.appendingPathComponent("竖拍.dng")
    check(writeDNG(dng, orientation: 6), "生成的 DNG 被 ImageIO 认作 RAW")
    let info = readInBackground(dng)
    check("按方向转正后的尺寸", info.dimensions, "192 × 256")
    check("相机", info.cameraName, "TestCamera")
    check("拍摄时间", info.captured?.display, "2024 年 5 月 6 日 07:08")
    check("位置", info.location?.display, "31.2294° N，121.4720° E")
    check("文件里的说明读得到", info.notes.map(\.text), ["A test DNG"])
    check("说明存在文件里", info.notes.first?.placeText, "存在文件里")
    check("格式是 RAW", PhotoItem(url: dng, size: 1, modified: Date()).format, .raw)

    print("RAW：缩略图不整幅显影")
    let previewOpts = thumbnailOptions(fromPreview: true, maxPixels: 256)
    check("用预览的选项：FromImageIfAbsent，不带 FromImageAlways",
          [previewOpts[kCGImageSourceCreateThumbnailFromImageIfAbsent] as? Bool, previewOpts[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool],
          [true, nil])
    let jpg = dir.appendingPathComponent("对照.jpg")
    writeImage(jpg)
    let jpgSource = CGImageSourceCreateWithURL(jpg as CFURL, nil)
    check("按内容认 RAW", [CGImageSourceCreateWithURL(dng as CFURL, nil).map(isCameraRAW), jpgSource.map(isCameraRAW)], [true, false])
    check("JPEG 从全图缩", jpgSource.flatMap { makeThumbnail($0, maxPixels: 16) }.map { "\($0.width)×\($0.height)" }, "16×12")
    // 1024×768 的 DNG 内嵌一张 64×48 的预览（DNG.swift 取全图的 1/16）。
    // 放在扫描的文件夹之外，下面「扫描真文件夹」只数那两张。
    let bigDir = dir.deletingLastPathComponent().appendingPathComponent("RAW缩略图")
    try? fm.removeItem(at: bigDir)
    try? fm.createDirectory(at: bigDir, withIntermediateDirectories: true)
    let big = bigDir.appendingPathComponent("大一点.dng")
    var spec = DNGSpec()
    (spec.width, spec.height) = (1024, 768)
    try? makeDNG(spec).write(to: big)
    let bigSource = CGImageSourceCreateWithURL(big as CFURL, nil)
    check(bigSource.map(isCameraRAW) == true, "1024×768 的 DNG 被认作 RAW")
    func thumb(_ px: Int) -> String? { bigSource.flatMap { makeThumbnail($0, maxPixels: px) }.map { "\($0.width)×\($0.height)" } }
    check("预览够大（不到两倍放大）时用预览，不显影", thumb(96), "64×48")
    check("预览不到要的一半时才整幅显影", thumb(256), "256×192")

    print("RAW：扫描真文件夹")
    let model = LibraryModel()
    model.addFolders([dir])
    check(spin(until: { !model.isBusy }), "扫描和读元数据都做完了")
    let lib = model.library
    check("RAW 被扫进来、算可以转换", Set(names(lib.items(in: .convertible))), ["竖拍.dng", "对照.jpg"])
    check("副标题里有 RAW", subtitle(items: lib.items(in: .all), selected: [], scanning: false).contains("JPEG 1 张、RAW 1 张"), true)
}

// MARK: - 混着转、勾了删除：RAW 原片永远在

func testMixedConversion(_ dir: URL, source: URL) {
    print("RAW：JPEG 和 RAW 混着转，勾了删除")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let root = dir.appendingPathComponent("库")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let jpg = root.appendingPathComponent("照片.jpg"), dng = root.appendingPathComponent("相机.dng")
    try? fm.copyItem(at: source, to: jpg)
    check(writeDNG(dng), "生成的 DNG 被 ImageIO 认作 RAW")
    let items = [jpg, dng].map { PhotoItem(url: $0, size: fileSize($0), modified: Date(), root: root) }
    let targets = ConversionTargets(selected: [], visible: items, entry: .folder(root.path), entryName: "库", search: "")
    var settings = PanelSettings.defaults
    settings.deleteOriginal = true
    let m = ConversionModel()
    m.replaceJobs(targets.jobs)
    m.updateOptions { targets.apply(settings, to: &$0) }
    check("模型拿到的选项：两种源、RAW 的并发数、删除开着",
          [m.options.sources == [.jpeg, .raw], m.options.jobs == ConversionOptions.defaultRAWJobs, m.options.deleteOriginal],
          [true, true, true])
    m.start()
    check(spin(until: { !m.isRunning }, timeout: 120), "这一批转完")
    let status = Dictionary(uniqueKeysWithValues: m.rows.map { ($0.name, $0.status) })
    check("JPEG 和 RAW 都转了", [status["照片.jpg"], status["相机.dng"]], [.done, .done])
    let rawProduct = root.appendingPathComponent("相机.heic")
    let depth = CGImageSourceCreateWithURL(rawProduct as CFURL, nil)
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyDepth] as? Int
    check("RAW 转出 10 位的 HEIF", depth, 10)
    // 对照：删除确实开着（无差异的 JPEG 被删了），下一条「RAW 还在」才不是空断言。
    let jpegRow = m.rows.first { $0.name == "照片.jpg" }
    check("对照：无差异的 JPEG 源被删了", [jpegRow?.verification == .passed, fm.fileExists(atPath: jpg.path)], [true, false])
    check("RAW 原片还在", fm.fileExists(atPath: dng.path), true)
    check("RAW 那一行说明没删", m.rows.first { $0.name == "相机.dng" }?.note.contains("RAW 原片永远保留") == true, true)
    let record = ConversionRecord(rows: m.rows, deleteRequested: targets.deletes(settings))
    check("记录里：JPEG 的源删了，RAW 的没删", m.rows.map { record.sourceDeleted($0) }, [true, false])
    check("活动条说 RAW 原片都留着", record.activityText.hasSuffix("RAW 原片都留着。"), true)
}

/// 本文件的用例。`source` 是一张能无差异转换的 JPEG（Tests/fixture 造的）。
/// 「把备注写进文件」对 RAW 也算数：转换时 RAW 与 JPEG 走同一个 captionPlan，所以 captionCanBeEmbedded
/// 对文件里没有说明字段、只有「照片」说明的 RAW 要说「能」；文件里已有说明的照旧说「不能」。
func testRAWCaption(_ dir: URL) {
    print("RAW：「照片」说明能不能写进文件")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var bare = DNGSpec(); bare.imageDescription = nil
    let outside = dir.appendingPathComponent("只有照片说明.dng"), inside = dir.appendingPathComponent("文件里有说明.dng")
    try? makeDNG(bare).write(to: outside)
    try? makeDNG(DNGSpec()).write(to: inside)
    for url in [outside, inside] { setXattr(url, photosCaptionXattr, Array("「照片」里写的说明".utf8)) }
    func embeddable(_ url: URL) -> Bool? {
        CGImageSourceCreateWithURL(url as CFURL, nil).map { captionCanBeEmbedded(url, image: $0) }
    }
    check("文件里没有说明字段的 RAW：「照片」说明算作能写进文件的", embeddable(outside), true)
    check("文件里已有说明的 RAW：不算能写进文件的", embeddable(inside), false)
}

func runRAWTests(work: URL, source: URL?) {
    testRAWLibrary()
    testRAWCaption(work.appendingPathComponent("RAW说明"))
    testRAWTargets()
    testRAWRecord()
    testRAWOnDisk(work.appendingPathComponent("RAW样本"))
    if let source {
        testMixedConversion(work.appendingPathComponent("混着转"), source: source)
    } else {
        fail("没有可以转换的源图")
    }
}
