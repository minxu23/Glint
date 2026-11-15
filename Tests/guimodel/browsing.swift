// 界面模型测试的第二部分：图库、条目信息、转换的对象、转换记录、设置（规格第 11 节各块）。
// 由 main.swift 调用；样本都在这里用 ImageIO 和 setxattr 现造，不依赖外部脚本。

@testable import Eclose
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 造样本

/// 写一张 32×24 的小图。`type` 是 UTType 标识；`properties` 是 ImageIO 的属性字典；
/// `xmp` 非空时整包换成它（用于只在 XMP 里的说明）。
@discardableResult
func writeImage(_ url: URL, type: UTType = .jpeg, properties: [CFString: Any] = [:],
                xmpDescription: String? = nil) -> Bool {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let w = 32, h = 24
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    ctx.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
    if let xmpDescription {
        let md = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueMatchingImageProperty(md, kCGImagePropertyIPTCDictionary,
                                                         kCGImagePropertyIPTCCaptionAbstract, xmpDescription as CFString)
        CGImageDestinationAddImageAndMetadata(dest, image, md, properties as CFDictionary)
    } else {
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    }
    return CGImageDestinationFinalize(dest)
}

/// PhotoInfo.read 只许在后台调用（开头有 dispatchPrecondition），测试里也照办。
func readInBackground(_ url: URL) -> PhotoInfo {
    var info = PhotoInfo()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { info = PhotoInfo.read(url); done.signal() }
    done.wait()
    return info
}

func setXattr(_ url: URL, _ name: String, _ bytes: [UInt8]) {
    _ = bytes.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
}

func finderCommentBytes(_ text: String) -> [UInt8] {
    [UInt8]((try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0)) ?? Data())
}

func writeText(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

/// 主 runloop 转起来等条件成立（模型的回调走主队列）。
func spin(until done: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return done()
}

func item(_ path: String, size: Int = 100, modified: TimeInterval = 0, root: String? = "/库",
          captured: CaptureTime? = nil, notes: [String] = [], outsideCaption: Bool = false,
          cmyk: Bool = false) -> PhotoItem {
    var info = PhotoInfo()
    info.isCMYK = cmyk
    info.captured = captured
    info.notes = notes.map { Note(text: $0, origins: [.fileDescription]) }
    info.captionOutsideOnly = outsideCaption
    return PhotoItem(url: URL(fileURLWithPath: path), size: size, modified: Date(timeIntervalSince1970: modified),
                     root: root.map { URL(fileURLWithPath: $0) }, info: info)
}

func names(_ items: [PhotoItem]) -> [String] { items.map(\.name) }

func row(_ name: String, _ status: RowStatus, inBytes: Int = 0, outBytes: Int = 0,
         verification: Verification = .notVerified, dest: String? = nil, sourceDeleted: Bool = false) -> FileRow {
    let url = URL(fileURLWithPath: "/库/\(name)")
    var r = FileRow(job: Job(input: url, relative: name, root: URL(fileURLWithPath: "/库")))
    r.status = status
    r.inBytes = inBytes
    r.outBytes = outBytes
    r.verification = verification
    r.dest = dest.map { URL(fileURLWithPath: $0) }
    r.sourceDeleted = sourceDeleted
    return r
}

// MARK: - 图库（纯数据）

func testLibraryData() {
    print("图库：空图库")
    let empty = Library()
    check(empty.isEmpty, "新图库是空的")
    check("空图库「全部图片」没有条目", empty.items(in: .all).count, 0)
    check("空图库没有文件夹树", empty.folderTree(), [])
    check("空图库的副标题", subtitle(items: [], selected: [], scanning: false), "0 张")
    check("空图库的汇总没有格式行", ItemsSummary(items: [], selected: false).formatLines, [])

    print("图库：条目、计数与文件夹树")
    var lib = Library()
    lib.addFolder(URL(fileURLWithPath: "/库"))
    let mb = 1024 * 1024
    lib.merge([
        FileEntry(url: URL(fileURLWithPath: "/库/a/x.jpg"), size: 3 * mb, modified: Date(timeIntervalSince1970: 10)),
        FileEntry(url: URL(fileURLWithPath: "/库/b/x.jpg"), size: 2 * mb, modified: Date(timeIntervalSince1970: 20)),
        FileEntry(url: URL(fileURLWithPath: "/库/b/深处/y.png"), size: 1 * mb, modified: Date(timeIntervalSince1970: 30)),
        FileEntry(url: URL(fileURLWithPath: "/库/z.heic"), size: mb / 2, modified: Date(timeIntervalSince1970: 40)),
    ])
    check("同名文件按路径各算一张", lib.count(of: .all), 4)
    check("可以转换只算 JPEG", lib.count(of: .convertible), 2)
    check("子文件夹的张数含更深处", lib.count(of: .folder("/库/b")), 2)
    let tree = lib.folderTree()
    check("文件夹树一个根", tree.count, 1)
    check("根的张数", tree.first?.count, 4)
    check("子文件夹按名字排、只列有图片的", tree.first?.children.map(\.name), ["a", "b"])
    check("更深一层的子文件夹也列出", tree.first?.children.last?.children.map(\.name), ["深处"])
    lib.setInfo(PhotoInfo(notes: [Note(text: "备注", origins: [.photos])]), for: "/库/a/x.jpg")
    check("有备注的张数", lib.count(of: .withNotes), 1)
    check("副标题：张数、JPEG、总大小", subtitle(items: lib.items(in: .all), selected: [], scanning: false),
          "4 张，其中 JPEG 2 张，共 6.5 MB")
    check("副标题：正在读取", subtitle(items: lib.items(in: .all), selected: [], scanning: true),
          "4 张，其中 JPEG 2 张，共 6.5 MB，正在读取…")
    let picked = lib.items(in: .convertible)
    check("副标题：有选中时", subtitle(items: lib.items(in: .all), selected: picked, scanning: false), "选中 2 张，共 5.0 MB")
    let summary = ItemsSummary(items: lib.items(in: .all), selected: true)
    check("多选汇总的标题", summary.title, "选中 4 张")
    check("格式分布：JPEG、HEIF 在前", summary.formatLines, ["JPEG 2 张，共 5.0 MB", "HEIF 1 张，共 512 KB", "PNG 1 张，共 1.0 MB"])
    check("有备注的张数", summary.notesLine, "有备注 1 张")
    check("没有备注时不写这一行", ItemsSummary(items: lib.items(in: .convertible).filter { !$0.hasNotes }, selected: false).notesLine, nil)

    // 重新扫描：大小、修改时间没变的保留元数据；扫完没再见到的去掉。
    let again = lib.merge([FileEntry(url: URL(fileURLWithPath: "/库/a/x.jpg"), size: 3 * mb,
                                     modified: Date(timeIntervalSince1970: 10))])
    check("没变的文件不重读元数据", again, [])
    check("没变的文件保留已读到的备注", lib.items["/库/a/x.jpg"]?.hasNotes, true)
    let changed = lib.merge([FileEntry(url: URL(fileURLWithPath: "/库/a/x.jpg"), size: 3 * mb + 1,
                                       modified: Date(timeIntervalSince1970: 11))])
    check("变了的文件要重读元数据", changed, ["/库/a/x.jpg"])
    lib.finishScan(of: "/库", seen: ["/库/a/x.jpg", "/库/b/x.jpg"])
    check("扫完没见到的去掉", lib.count(of: .all), 2)

    // 嵌套添加：来源根取最外层；移除外层后里层的条目还在。
    lib.addFolder(URL(fileURLWithPath: "/库/b"))
    check("嵌套添加时来源根取最外层", lib.items["/库/b/x.jpg"]?.root?.path, "/库")
    lib.removeFolder("/库")
    check("移除外层后里层的条目还在", lib.count(of: .all), 1)
    check("里层条目的来源根换成里层", lib.items["/库/b/x.jpg"]?.root?.path, "/库/b")
    lib.removeFolder("/库/b")
    check("全部移除后没有条目", lib.count(of: .all), 0)

    // 单独添加的图片。
    lib.addLooseFile(FileEntry(url: URL(fileURLWithPath: "/别处/单张.jpg"), size: 10, modified: Date()))
    check("单独添加的图片在自己的条目里", lib.count(of: .looseFiles), 1)
    check("单独添加的图片也算进全部图片", lib.count(of: .all), 1)
    // 文件夹之外的转换产物只在「最近一次转换」里出现。
    lib.adoptProduct(FileEntry(url: URL(fileURLWithPath: "/输出/单张.heic"), size: 5, modified: Date()))
    check("文件夹之外的产物不进全部图片", lib.count(of: .all), 1)
    let record = ConversionRecord(rows: [row("单张.jpg", .done, inBytes: 10, outBytes: 5, dest: "/输出/单张.heic")])
    var lib2 = lib
    lib2.addLooseFile(FileEntry(url: URL(fileURLWithPath: "/库/单张.jpg"), size: 10, modified: Date()))
    check("「最近一次转换」显示产物", names(lib2.items(in: .conversion(.all), record: record)), ["单张.heic"])
}

// MARK: - 搜索与排序

func testSearchAndSort() {
    print("图库：搜索")
    let a = item("/库/IMG_0001.JPG", notes: ["西湖日落 Sunset"])
    let b = item("/库/旅行/海边.heic", notes: [])
    let c = item("/库/IMG_0002.png", notes: ["家里的猫"])
    let all = [a, b, c]
    check("命中文件名（不分大小写）", names(all.filter { $0.matches("img_000") }), ["IMG_0001.JPG", "IMG_0002.png"])
    check("命中备注（不分大小写）", names(all.filter { $0.matches("SUNSET") }), ["IMG_0001.JPG"])
    check("命中中文备注", names(all.filter { $0.matches("猫") }), ["IMG_0002.png"])
    check("不命中", all.filter { $0.matches("雪山") }.count, 0)
    check("搜索词为空时全部命中", all.filter { $0.matches("  ") }.count, 3)
    var lib = Library()
    lib.addFolder(URL(fileURLWithPath: "/库"))
    lib.merge(all.map { FileEntry(url: $0.url, size: $0.size, modified: $0.modified) })
    for i in all { lib.setInfo(i.info!, for: i.path) }
    check("当前视图按搜索过滤", names(lib.visibleItems(in: .all, record: nil, search: "海", order: SortOrder())), ["海边.heic"])

    print("图库：排序")
    let t1 = CaptureTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5)
    let t2 = CaptureTime(year: 2025, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    let p = item("/库/b.jpg", size: 300, modified: 0, captured: t2)
    let q = item("/库/a10.png", size: 100, modified: 0, captured: t1)
    let r = item("/库/a9.heic", size: 200, modified: 0, captured: nil)   // 没有拍摄时间：用修改时间（1970）
    let set = [p, q, r]
    check("拍摄时间升序（没有拍摄时间的用修改时间）", names(sorted(set, by: SortOrder(key: .captured, ascending: true))),
          ["a9.heic", "a10.png", "b.jpg"])
    check("拍摄时间降序", names(sorted(set, by: SortOrder(key: .captured, ascending: false))), ["b.jpg", "a10.png", "a9.heic"])
    check("文件名升序（数字按大小）", names(sorted(set, by: SortOrder(key: .name, ascending: true))), ["a9.heic", "a10.png", "b.jpg"])
    check("文件名降序", names(sorted(set, by: SortOrder(key: .name, ascending: false))), ["b.jpg", "a10.png", "a9.heic"])
    check("大小升序", names(sorted(set, by: SortOrder(key: .size, ascending: true))), ["a10.png", "a9.heic", "b.jpg"])
    check("大小降序", names(sorted(set, by: SortOrder(key: .size, ascending: false))), ["b.jpg", "a9.heic", "a10.png"])
    check("格式升序：JPEG、HEIF、其它", names(sorted(set, by: SortOrder(key: .format, ascending: true))), ["b.jpg", "a9.heic", "a10.png"])
    check("格式降序", names(sorted(set, by: SortOrder(key: .format, ascending: false))), ["a10.png", "a9.heic", "b.jpg"])
    let tie = [item("/库/2.jpg", size: 5), item("/库/1.jpg", size: 5)]
    check("相同的按文件名定先后", names(sorted(tie, by: SortOrder(key: .size, ascending: true))), ["1.jpg", "2.jpg"])
}

// MARK: - 备注

func testNotesRules() {
    print("备注：去重与存放位置")
    let merged = mergeNotes([(.photos, " 西湖 \n"), (.fileDescription, "西湖"), (.exifComment, "  "),
                             (.exifComment, "相机里写的"), (.finder, "访达里写的")])
    check("同一段文字只留一条，空的不要", merged.map(\.text), ["西湖", "相机里写的", "访达里写的"])
    check("文件里外各有一份", merged.first?.placeText, "文件里外各有一份")
    check("只在 EXIF 备注里", merged[1].placeText, "存在文件里（EXIF 备注）")
    check("只在文件之外", merged[2].placeText, "存在文件之外，换设备或传网盘容易丢")
    check("只在文件之外的才标风险", merged.map(\.isAtRisk), [false, false, true])
    check("文件里的说明和 EXIF 备注同值：存在文件里",
          mergeNotes([(.fileDescription, "一样"), (.exifComment, "一样")]).first?.placeText, "存在文件里")

    print("备注：EXIF 备注用 Eclose 的读法")
    check("ImageIO 读不出、原始字节是可靠的文本：用原始字节",
          displayedUserComment(seenByImageIO: nil, reading: .reliable("无头的备注", header: .none)), "无头的备注")
    check("原始字节只能猜：不显示",
          displayedUserComment(seenByImageIO: "Ã¤", reading: .guessed("Ã¤", raw: [0xC3], header: .ascii)), nil)
    check("ImageIO 读得出：用 ImageIO 的",
          displayedUserComment(seenByImageIO: "普通备注\0\0", reading: .reliable("普通备注", header: .unicode)), "普通备注")
    check("都没有", displayedUserComment(seenByImageIO: nil, reading: .absent), nil)
}

/// 真文件：四种来源各造一张，读出来对照。
func testNotesOnDisk(_ dir: URL) {
    print("备注：从真文件读四种来源")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)

    let photos = dir.appendingPathComponent("照片说明.jpg")
    writeImage(photos)
    setXattr(photos, photosCaptionXattr, Array("「照片」里写的说明".utf8))
    let photosInfo = readInBackground(photos)
    check("「照片」的说明读到了", photosInfo.notes.map(\.text), ["「照片」里写的说明"])
    check("「照片」的说明存在文件之外", photosInfo.notes.first?.placeText, "存在文件之外，换设备或传网盘容易丢")
    check("「照片」说明在、文件里没有：算作能写进文件的", photosInfo.captionOutsideOnly, true)

    let finder = dir.appendingPathComponent("访达备注.jpg")
    writeImage(finder)
    setXattr(finder, finderCommentXattr, finderCommentBytes("访达里写的备注"))
    let finderInfo = readInBackground(finder)
    check("访达备注读到了", finderInfo.notes.map(\.text), ["访达里写的备注"])
    check("访达备注存在文件之外", finderInfo.notes.first?.place, .outside)
    check("只有访达备注的不算「照片」说明", finderInfo.captionOutsideOnly, false)

    let inside = dir.appendingPathComponent("文件里.jpg")
    writeImage(inside, properties: [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "文件里的说明"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "文件里的说明"],
    ])
    let insideInfo = readInBackground(inside)
    check("TIFF 与 IPTC 同值只显示一条", insideInfo.notes.map(\.text), ["文件里的说明"])
    check("文件里的说明：存在文件里", insideInfo.notes.first?.placeText, "存在文件里")

    let xmpOnly = dir.appendingPathComponent("只在XMP.jpg")
    writeImage(xmpOnly, xmpDescription: "XMP 里的说明")
    check("只在 XMP dc:description 里的说明也读到", readInBackground(xmpOnly).notes.map(\.text), ["XMP 里的说明"])

    let exif = dir.appendingPathComponent("EXIF备注.jpg")
    writeImage(exif, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "note from the camera"]])
    let exifInfo = readInBackground(exif)
    check("EXIF 备注读到了", exifInfo.notes.map(\.text), ["note from the camera"])
    check("EXIF 备注：存在文件里（EXIF 备注）", exifInfo.notes.first?.placeText, "存在文件里（EXIF 备注）")

    // 不写字符集头的裸 UTF-8（部分安卓机这么写）：ImageIO 读不出，要用 Eclose 的原始字节读法。
    let headless = dir.appendingPathComponent("无头备注.jpg")
    writeImage(headless, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: String(repeating: "x", count: 24)]])
    var patched = false
    if var data = try? Data(contentsOf: headless), let range = exifUserCommentRange(in: data) {
        var body = Array("无头的备注".utf8)
        if body.count <= range.count {
            body += [UInt8](repeating: 0x20, count: range.count - body.count)
            data.replaceSubrange(range, with: body)
            patched = (try? data.write(to: headless)) != nil
        }
    }
    check(patched, "造出了不带字符集头的 EXIF 备注")
    check("ImageIO 读不出的裸 UTF-8 备注照样读到", readInBackground(headless).notes.map(\.text), ["无头的备注"])

    let both = dir.appendingPathComponent("里外各一份.jpg")
    writeImage(both, xmpDescription: "同一段说明")
    setXattr(both, photosCaptionXattr, Array("同一段说明".utf8))
    let bothInfo = readInBackground(both)
    check("文件内外同一段文字只显示一条", bothInfo.notes.count, 1)
    check("文件内外都有：文件里外各有一份", bothInfo.notes.first?.placeText, "文件里外各有一份")
    check("文件里已有说明：不算能写进文件的", bothInfo.captionOutsideOnly, false)

    let several = dir.appendingPathComponent("好几条.jpg")
    writeImage(several, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "second"]])
    setXattr(several, photosCaptionXattr, Array("第一条".utf8))
    setXattr(several, finderCommentXattr, finderCommentBytes("第三条"))
    check("读到几条显示几条", readInBackground(several).notes.map(\.text), ["第一条", "第三条", "second"])

    print("条目信息：拍摄参数")
    let camera = dir.appendingPathComponent("相机.jpg")
    writeImage(camera, properties: [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:04:27 20:28:41",
            kCGImagePropertyExifFNumber: 1.4, kCGImagePropertyExifExposureTime: 0.02,
            kCGImagePropertyExifISOSpeedRatings: [640], kCGImagePropertyExifFocalLength: 24.0,
            kCGImagePropertyExifLensModel: "RF24mm F1.4",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.053, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 13.7343, kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ])
    let info = readInBackground(camera)
    check("像素尺寸", info.dimensions, "32 × 24")
    check("拍摄时间", info.captured?.display, "2026 年 4 月 27 日 20:28")
    check("相机取型号", info.cameraName, "Canon EOS R5")
    check("曝光参数一行", info.exposureLine, "f/1.4，1/50 秒，ISO 640，24 mm")
    check("镜头", info.lens, "RF24mm F1.4")
    check("位置", info.location?.display, "51.0530° N，13.7343° E")
    check("没有备注", info.hasNotes, false)
    let plain = dir.appendingPathComponent("什么都没有.png")
    writeImage(plain, type: .png)
    let plainInfo = readInBackground(plain)
    check("没有参数的图：曝光行、相机、位置都没有", [plainInfo.exposureLine, plainInfo.cameraName, plainInfo.location?.display],
          [nil, nil, nil])
}

// MARK: - 后台扫描（真磁盘与假扫描器）

func testScanning(_ dir: URL) {
    print("图库：扫描真文件夹")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    writeImage(dir.appendingPathComponent("一/同名.jpg"))
    writeImage(dir.appendingPathComponent("二/同名.jpg"))
    writeImage(dir.appendingPathComponent("二/更深/图.png"), type: .png)
    writeText(dir.appendingPathComponent("说明.txt"), "不是图片")
    writeText(dir.appendingPathComponent("一/数据.json"), "{}")
    writeImage(dir.appendingPathComponent(".隐藏.jpg"))
    try? fm.createDirectory(at: dir.appendingPathComponent("空的"), withIntermediateDirectories: true)

    let model = LibraryModel()
    var folderSaves: [[String]] = []
    model.onFoldersChange = { folderSaves.append($0) }
    model.addFolders([dir])
    check(spin(until: { !model.isBusy }), "扫描和读元数据都做完了")
    let lib = model.library
    check("非图片、隐藏文件被忽略", Set(names(lib.items(in: .all))), ["同名.jpg", "图.png"])
    check("同名文件都在", lib.count(of: .all), 3)
    let root = dir.standardizedFileURL.path
    check("文件夹树只列有图片的子文件夹", lib.folderTree().first?.children.map(\.name), ["一", "二"])
    check("元数据在后台补上了", lib.items.values.allSatisfy { $0.info != nil }, true)
    check("加文件夹时通知存设置", folderSaves.last, [root])

    // 删一个文件、加一个文件，重新读取后以磁盘为准。
    try? fm.removeItem(at: dir.appendingPathComponent("一/同名.jpg"))
    writeImage(dir.appendingPathComponent("一/新的.jpg"))
    model.reload()
    check(spin(until: { !model.isBusy }), "重新读取做完了")
    check("重新读取后以磁盘为准", Set(model.library.items.keys.map { ($0 as NSString).lastPathComponent }), ["同名.jpg", "新的.jpg", "图.png"])

    print("图库：注入假的扫描器")
    let fake = LibraryModel(scanner: { folder, deliver in
        deliver([FileEntry(url: folder.appendingPathComponent("1.jpg"), size: 1, modified: Date(timeIntervalSince1970: 1))])
        Thread.sleep(forTimeInterval: 0.2)
        deliver([FileEntry(url: folder.appendingPathComponent("2.heic"), size: 2, modified: Date(timeIntervalSince1970: 2))])
    }, reader: { url in
        PhotoInfo(notes: url.pathExtension == "jpg" ? [Note(text: "假备注", origins: [.photos])] : [])
    }, statter: { _ in nil }, folderExists: { $0.path != "/不存在" })
    var sawPartial = false
    fake.onChange = { if fake.library.count(of: .all) == 1 && !fake.library.scanning.isEmpty { sawPartial = true } }
    fake.addFolders([URL(fileURLWithPath: "/假的")])
    check(spin(until: { !fake.isBusy }), "假扫描做完了")
    check(sawPartial, "先出来的先显示（扫描中途就有一张）")
    check("两批都并进来了", fake.library.count(of: .all), 2)
    check("读取器的结果并进来了", fake.library.count(of: .withNotes), 1)
    fake.addFolders([URL(fileURLWithPath: "/不存在")])
    check(spin(until: { !fake.isBusy }), "不存在的文件夹也扫完了")
    check("找不到的文件夹标出来", fake.library.folderTree().last?.missing, true)
    fake.removeFolder("/不存在")
    check("从侧栏移除", fake.library.folders, ["/假的"])
}

// MARK: - 转换的对象

func testTargets() {
    print("转换的对象")
    let mb = 1024 * 1024
    let j1 = item("/库/2026 春/a.jpg", size: 2 * mb, root: "/库", outsideCaption: true)
    let j2 = item("/库/2026 春/子/b.JPG", size: 1 * mb, root: "/库")
    let h = item("/库/2026 春/c.heic", size: mb, root: "/库")
    let p = item("/库/2026 春/d.png", size: mb, root: "/库")
    let loose = item("/别处/e.jpg", size: mb, root: nil, outsideCaption: true)

    let mixed = ConversionTargets(selected: [j1, h, p], visible: [j1, j2, h, p], entry: .all, entryName: "全部图片", search: "")
    check("选中里混着别的格式：只转 JPEG", names(mixed.items), ["a.jpg"])
    check("面板标题", mixed.title, "转换 1 张 JPEG")
    check("选中时的说明", mixed.detail, "选中的 1 张 JPEG，共 2.0 MB。别的格式不动。")

    let entry = ConversionTargets(selected: [], visible: [j1, j2, h, p], entry: .folder("/库/2026 春"), entryName: "2026 春", search: "")
    check("没选中：当前视图里全部的 JPEG", names(entry.items), ["a.jpg", "b.JPG"])
    check("当前视图的说明", entry.detail, "「2026 春」里的全部 JPEG，共 3.0 MB。别的格式不动。")
    check("当前是文件夹时来源根取这个文件夹", entry.jobs.map { $0.root?.path }, ["/库/2026 春", "/库/2026 春"])
    check("相对路径保留子目录", entry.jobs.map(\.relative), ["a.jpg", "子/b.JPG"])

    let onlyJPEG = ConversionTargets(selected: [j1, j2], visible: [j1, j2], entry: .all, entryName: "全部图片", search: "")
    check("全是 JPEG 时不说别的格式", onlyJPEG.detail, "选中的 2 张 JPEG，共 3.0 MB。")
    check("不在文件夹条目时来源根取所属的已添加文件夹", onlyJPEG.jobs.map(\.relative), ["2026 春/a.jpg", "2026 春/子/b.JPG"])

    let searched = ConversionTargets(selected: [], visible: [j1], entry: .all, entryName: "全部图片", search: " a ")
    check("搜索时的说明", searched.detail, "「全部图片」里符合「a」的 JPEG，共 2.0 MB。")

    let withLoose = ConversionTargets(selected: [loose, j1], visible: [], entry: .looseFiles, entryName: "单独添加的图片", search: "")
    check("单独添加的图片没有来源根", withLoose.jobs.first?.root, nil)
    check("这批里备注存在文件之外的张数", withLoose.captionOutsideCount, 2)
    check("「把备注写进文件」的说明", withLoose.captionHint, "这批里有 2 张的备注存在文件之外，写进去以后换了设备也在")
    check("没有时的说明", onlyJPEG.captionHint.isEmpty ? "" : ConversionTargets(selected: [j2], visible: [], entry: .all, entryName: "", search: "").captionHint,
          "这批里没有存在文件之外的备注")

    let printJob = item("/库/印刷/f.jpg", size: mb, cmyk: true)
    let withCMYK = ConversionTargets(selected: [printJob, j1, h], visible: [], entry: .all, entryName: "全部图片", search: "")
    check("CMYK 的 JPEG 照样在这批里（转不转由面板上的勾决定）", names(withCMYK.items), ["f.jpg", "a.jpg"])
    check("这批里 CMYK 的张数", withCMYK.cmykCount, 1)
    check("「也转 CMYK 的 JPEG」的说明", withCMYK.cmykHint, "这批里有 1 张 CMYK 的 JPEG。HEIF 只能存 RGB，转了颜色会变；不勾就跳过")
    check("没有 CMYK 时的说明", onlyJPEG.cmykHint, "CMYK 的 JPEG 多是印刷用的稿子。HEIF 只能存 RGB，转了颜色会变；不勾就跳过")

    let none = ConversionTargets(selected: [h, p], visible: [], entry: .all, entryName: "全部图片", search: "")
    check(none.isEmpty, "一张 JPEG 都没有时对象为空（按钮禁用）")
}

// MARK: - 转换记录

func testRecord() {
    print("转换记录：计数与体积")
    let mb = 1024 * 1024
    let rows = [
        row("ok.jpg", .done, inBytes: 4 * mb, outBytes: 1 * mb, verification: .passed, dest: "/库/ok.heic",
            sourceDeleted: true),
        row("diff.jpg", .done, inBytes: 4 * mb, outBytes: 1 * mb,
            verification: .differences(["丢失 APP8 段（ITUT35&，24 字节）", "变化 {TIFF}/Model: A → B", "照片里的东西：不一样"]),
            dest: "/库/diff.heic"),
        row("diff2.jpg", .done, inBytes: 2 * mb, outBytes: 1 * mb,
            verification: .differences(["丢失 APP8 段（ITUT35&，30 字节）", "丢失 APP8 段（ITUT35&，31 字节）"]), dest: "/库/diff2.heic"),
        row("grew.jpg", .done, inBytes: 1 * mb, outBytes: 2 * mb, verification: .passed, dest: "/库/grew.heic"),
        row("nover.jpg", .done, inBytes: 1 * mb, outBytes: mb / 2, verification: .notVerified, dest: "/库/nover.heic"),
        row("skip.jpg", .skipped("不是 JPEG 文件")),
        row("fail.jpg", .failed("无法读取图像")),
    ]
    var rec = ConversionRecord(rows: rows, deleteRequested: false)
    let t = rec.tally
    check("各类张数", [t.converted, t.passed, t.differences, t.notVerified, t.skipped, t.failed, t.grew],
          [5, 2, 2, 1, 1, 1, 1])
    check("总体积", [t.inBytes, t.outBytes], [12 * mb, mb * 11 / 2])
    check("省下的那一行", rec.savingLine, "转完 5 张，省下 6.5 MB")
    check("总量那一行", rec.volumeLine, "12 MB → 5.5 MB")
    check("各类张数的行，零的不列", rec.classLines,
          ["无差异 2 张", "有差异 2 张", "没有校验 1 张", "已跳过 1 张", "失败 1 张", "HEIF 比源文件大 1 张"])
    check("「最近一次转换」显示产物，没有产物的显示源文件", rec.displayedPaths(.all).map { ($0 as NSString).lastPathComponent },
          ["ok.heic", "diff.heic", "diff2.heic", "grew.heic", "nover.heic", "skip.jpg", "fail.jpg"])
    check("子项「有差异」", rec.count(.differences), 2)
    check("子项「失败」", rec.count(.failures), 1)
    check("源与产物都能找到那一行", [rec.mark(for: "/库/diff.jpg"), rec.mark(for: "/库/diff.heic")],
          [.differences(3), .differences(3)])
    check("没碰过的图没有状态", rec.mark(for: "/库/别的.jpg"), nil)
    check("网格上只标转换中、有差异、失败",
          [ConversionMark.running, .passed, .notVerified, .differences(1), .skipped, .failed].map(\.showsOnGrid),
          [true, false, false, true, false, true])
    check(rec.isProduct("/库/ok.heic") && !rec.isProduct("/库/ok.jpg"), "产物与源的对应")

    print("转换记录：最常见的差异")
    let top = rec.topDifferences()
    check("一张图里相同的只算一次，数字归并成 N", top.first?.family, "丢失 APPN 段（ITUTN&，N 字节）")
    check("最常见的差异的张数", top.first?.count, 2)
    check("截到第一个冒号或等号", issueFamily("变化 {TIFF}/Model: A → B"), "变化 {TIFF}/Model")
    check("全角冒号也截", issueFamily("照片里的东西：不一样"), "照片里的东西")
    check("等号也截", issueFamily("丢失 {Exif}/ISO = 400"), "丢失 {Exif}/ISO")
    check("最多 5 条", ConversionRecord(rows: [row("x.jpg", .done, verification: .differences(["甲", "乙", "丙", "丁", "戊", "己", "庚"].map { "丢失 \($0)" }))])
        .topDifferences().count, 5)

    print("转换记录：差异行的标记")
    check("丢失", splitIssue("丢失 APP8 段").tag, .lost)
    check("丢失的正文去掉开头两个字", splitIssue("丢失 APP8 段").text, "APP8 段")
    check("变化", splitIssue("变化 {TIFF}/Model: A → B").tag, .changed)
    check("其它标注意，正文原样", [splitIssue("无法核对扩展属性").tag == .notice ? "注意" : "", splitIssue("无法核对扩展属性").text],
          ["注意", "无法核对扩展属性"])

    print("转换记录：活动条的每一句话")
    check("转完、没开删除", rec.activityText, "转完 5 张，省下 6.5 MB。2 张有差异，1 张跳过，1 张失败。")
    check("「N 张有差异」可以点，跳到有差异", rec.activitySentence.first { $0.link != nil }?.link, .conversion(.differences))
    rec.deleteRequested = true
    check("转完、开了删除", rec.activityText,
          "转完 5 张，省下 6.5 MB。2 张有差异，1 张 HEIF 比源文件大，1 张跳过，1 张失败，它们的源文件都还在。")
    check("源删掉没有：照 Eclose 的报告",
          rows.map { rec.sourceDeleted($0) }, [true, false, false, false, false, false, false])
    let clean = ConversionRecord(rows: [rows[0]], deleteRequested: true)
    check("全都无差异", clean.activityText, "转完 1 张，省下 3.0 MB。")
    let bigger = ConversionRecord(rows: [rows[3]])
    check("产物总体变大", bigger.activityText, "转完 1 张，比源文件大 1.0 MB。")
    check("产物总体变大的汇总行", bigger.savingLine, "转完 1 张，比源文件大 1.0 MB")
    let running = ConversionRecord(rows: [rows[0], row("p.jpg", .running), row("q.jpg", .pending)], isRunning: true)
    check("进行中", running.activityText, "正在转换　已转 1 张，共 3 张")
    check("进行中「最近一次转换」只含已开始的", running.count(.all), 2)
    let cancelled = ConversionRecord(rows: [rows[0], rows[1], row("p.jpg", .pending), row("q.jpg", .pending)], wasCancelled: true)
    check("取消", cancelled.activityText, "已取消。转完 2 张，还有 2 张没转。1 张有差异。")
    let allFailed = ConversionRecord(rows: [rows[6]])
    check("一张都没转成", allFailed.activityText, "一张都没转成。1 张失败。")

    print("转换记录：描述与文案")
    var withNote = item("/库/IMG_2026.jpg", size: 3 * mb + mb / 3, notes: ["有"])
    check("缩略图的无障碍描述", accessibilityDescription(withNote, mark: .differences(2)),
          "IMG_2026.jpg，JPEG，3.3 MB，有备注，转换时有 2 处差异")
    withNote.info = nil
    check("没备注、没转过的描述", accessibilityDescription(withNote, mark: nil), "IMG_2026.jpg，JPEG，3.3 MB")
    check("体积两行：省", volumeLines(inBytes: 4 * mb, outBytes: mb).1, "省 75%")
    check("体积两行：变大", volumeLines(inBytes: 3 * mb, outBytes: 4 * mb).1, "比源文件大 33%")
    check("结论标题", [ConversionMark.passed, .differences(2), .notVerified, .failed].map(verdictTitle),
          ["转换时无差异", "转换时有 2 处差异", "没有校验", "转换失败"])
    check("列表「转换」列", [ConversionMark.passed, .differences(3), .failed, .running].map(\.listText),
          ["无差异", "3 处差异", "失败", "转换中"])
    check("文件大小的写法", [shortSize(512), shortSize(1024 * 989), shortSize(3 * mb + mb / 3), shortSize(612 * mb)],
          ["512 B", "989 KB", "3.3 MB", "612 MB"])
}

// MARK: - 设置

func testSettings() {
    print("设置：读写")
    let store = MemoryStore()
    let fresh = PanelSettings.load(from: store)
    check("没存过时用默认值", fresh, PanelSettings.defaults)
    check("默认校验", fresh.verify, true)
    check("默认画质取自命令行的默认值", fresh.quality, ConversionOptions.default.quality)
    var s = fresh
    s.quality = 0.9
    s.outputFolder = URL(fileURLWithPath: "/输出")
    s.verify = false
    s.embedCaption = true
    s.systemExif = true
    s.deleteOriginal = true
    s.overwrite = true
    s.convertCMYK = true
    s.save(to: store)
    let back = PanelSettings.load(from: store)
    check("画质、保存到、校验、写进文件、EXIF 都记住了",
          [back.quality == 0.9, back.outputFolder?.path == "/输出", back.verify == false, back.embedCaption, back.systemExif],
          [true, true, true, true, true])
    check("「删除源文件」不记", back.deleteOriginal, false)
    check("「覆盖同名的 HEIF」不记", back.overwrite, false)
    check("「也转 CMYK 的 JPEG」不记", back.convertCMYK, false)
    check("存储里根本没有这三项",
          store.values.keys.filter { $0.contains("delete") || $0.contains("overwrite") || $0.lowercased().contains("cmyk") }, [])
    var del = back
    del.deleteOriginal = true
    check("勾了删除：校验被锁上并生效", [del.effectiveVerify, del.verifyLocked], [true, true])
    let jpegBatch = ConversionTargets(selected: [item("/库/a.jpg")], visible: [], entry: .all, entryName: "", search: "")
    check("勾了删除：主按钮", jpegBatch.primaryTitle(del), "转换并删除源文件")
    check("没勾删除：主按钮", jpegBatch.primaryTitle(back), "转换")
    var opts = ConversionOptions.default
    del.apply(to: &opts)
    check("落到 ConversionOptions 上", [opts.verify, opts.deleteOriginal, opts.embedCaption, opts.rawExif], [true, true, true, false])
    check("不勾就不转 CMYK", opts.convertCMYK, false)
    del.convertCMYK = true
    del.apply(to: &opts)
    check("勾了「也转 CMYK 的 JPEG」落到 ConversionOptions 上", opts.convertCMYK, true)
    check("「原图缺了附加图像时保留 JPEG」默认不勾（照删）", [fresh.keepStaleMPF, ConversionOptions.default.keepStaleMPF], [false, false])
    var keep = back
    keep.keepStaleMPF = true
    keep.save(to: store)
    check("「原图缺了附加图像时保留 JPEG」记住了", PanelSettings.load(from: store).keepStaleMPF, true)
    keep.apply(to: &opts)
    check("勾了「原图缺了附加图像时保留 JPEG」落到 ConversionOptions 上", opts.keepStaleMPF, true)
    s.outputFolder = nil
    s.save(to: store)
    check("改回源文件旁边也记住", PanelSettings.load(from: store).outputFolder, nil)
    check("画质步长 0.05、范围 0.4–1.0", [steppedQuality(0.83), steppedQuality(0.1), steppedQuality(1.3)], [0.85, 0.4, 1.0])
    check("画质提示语沿用原来的", qualityHint(0.8), "日常存档的推荐区间")

    var b = BrowserSettings.load(from: store)
    check("浏览默认网格、168、拍摄时间升序", [b.mode == .grid, b.cellSize == 168, b.sort == SortOrder()], [true, true, true])
    b.mode = .list
    b.cellSize = 999
    b.sort = SortOrder(key: .size, ascending: false)
    b.save(to: store)
    let b2 = BrowserSettings.load(from: store)
    check("网格/列表、排序记住", [b2.mode == .list, b2.sort == SortOrder(key: .size, ascending: false)], [true, true])
    check("单元边长读回时夹在 96–320", b2.cellSize, 320)
    SavedFolders.save(["/一", "/二"], to: store)
    check("加进来的文件夹记住", SavedFolders.load(from: store), ["/一", "/二"])

    check("应用图标没选过时用浅色", AppIconChoice.load(from: store), .light)
    check("默认款式就是应用包自带的那个（Info.plist 的 CFBundleIconFile）", AppIconChoice.default.resourceName, "AppIcon")
    AppIconChoice.gradient.save(to: store)
    check("应用图标选了渐变记住", AppIconChoice.load(from: store), .gradient)
    store.setValue("以后删掉的款式", forKey: "app.icon")
    check("存的款式不认识就回到默认", AppIconChoice.load(from: store), .light)
    check("菜单里的名字", AppIconChoice.allCases.map(\.title), ["浅色", "渐变"])
    check("每款各有图标文件，名字不重", Set(AppIconChoice.allCases.map(\.resourceName)).count, AppIconChoice.allCases.count)
}

// MARK: - 按 Job 转换（带来源根）

func testJobConversion(_ dir: URL, source: URL) {
    print("转换：按 Job 转、镜像子目录、报告字段")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let root = dir.appendingPathComponent("库")
    let out = dir.appendingPathComponent("输出")
    try? fm.createDirectory(at: root.appendingPathComponent("子"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("子/a.jpg")
    try? fm.copyItem(at: source, to: a)
    try? fm.copyItem(at: source, to: b)
    let items = [a, b].map { PhotoItem(url: $0, size: fileSize($0), modified: Date(), root: root) }
    let targets = ConversionTargets(selected: [], visible: items, entry: .folder(root.path), entryName: "库", search: "")
    let m = ConversionModel()
    var rowEvents = 0
    m.onRowChange = { _ in rowEvents += 1 }
    m.outputMode = .chosenFolder
    m.outputFolder = out
    m.replaceJobs(targets.jobs)
    check("换上新的一批", m.rows.count, 2)
    m.start()
    check(spin(until: { !m.isRunning }, timeout: 60), "这一批转完")
    check(fm.fileExists(atPath: out.appendingPathComponent("a.heic").path)
          && fm.fileExists(atPath: out.appendingPathComponent("子/a.heic").path), "输出到指定文件夹时按子目录摆放")
    check("每一行开始和结束都单独通知", rowEvents, 4)
    check("报告里的 EXIF 照搬结果带到了行上", m.rows.allSatisfy { $0.rawExif != nil }, true)
    check("没有被取消", m.wasCancelled, false)
    let rec = ConversionRecord(rows: m.rows)
    check("记录里两张都转完", rec.tally.converted, 2)
    m.replaceJobs([])
    check("换成空的一批", m.rows.count, 0)
}

/// 规格第 11 节各块的用例。
func runBrowsingTests(work: URL) {
    testLibraryData()
    testSearchAndSort()
    testNotesRules()
    testNotesOnDisk(work.appendingPathComponent("备注样本"))
    testScanning(work.appendingPathComponent("扫描样本"))
    testTargets()
    testRecord()
    testSettings()
    if let source = files(in: work.appendingPathComponent("源"), ext: "jpg").first {
        testJobConversion(work.appendingPathComponent("按Job转换"), source: source)
    } else {
        fail("没有可以转换的源图")
    }
}
