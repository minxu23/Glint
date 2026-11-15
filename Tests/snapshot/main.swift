// 界面截图工具（开发用）。复用真实的 MainWindowController，把窗口离屏渲染成 PNG，
// 这样不需要屏幕录制权限也能检查界面排版。设置存在内存里，不碰用户的 UserDefaults。
//
// 用法见下面的 usage。`--convert` 的语义：把给出的目录加进来，扫完后把当前视图里全部的
// JPEG 和 RAW 按默认设置转完，再截图。

import AppKit

let usage = """
用法: uisnapshot <输出.png> [选项] [要加进来的文件夹或图片 ...]
  --appearance light|dark   浅色或深色（默认浅色）
  --size 宽x高              窗口内容尺寸（默认 1180x720）
  --view grid|list          网格或列表
  --sidebar <条目>          全部图片、可以转换、有备注、最近一次转换、有差异、失败、
                            单独添加的图片，或文件夹名
  --select <文件名>         选中这张（可以重复）
  --search <词>             搜索
  --sheet                   显示转换面板
  --sheet-delete            显示转换面板，并勾上「删除源文件」
  --sheet-advanced          显示转换面板，展开「高级」
  --sheet-bad-ssim <文字>   显示转换面板，展开「高级」，局部相似度那一格填这段文字
  --quality <0.4–1>         转换面板的画质（存进设置；配 --convert 用这个质量转）
  --convert                 把当前视图里全部的 JPEG 和 RAW 转完再截图
  --measure                 打印从加文件夹到第一屏缩略图出齐的时间
  --scroll                  把网格从头滚到尾，打印每一步主线程上花的最长时间
  --inspector <宽>          把信息栏拖到这个宽度（240–400）
  --onscreen                窗口放到屏幕上，用 screencapture 截真实窗口（玻璃、强调色都是真的；
                            需要屏幕录制权限），而不是离屏渲染
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, !args[0].hasPrefix("--") else { die(usage) }
let outPath = args.removeFirst()
var appearance = "light"
var size = MainWindowController.defaultSize
var viewMode: BrowserMode?
var sidebarEntry: String?
var selectNames: [String] = []
var searchText: String?
var showSheet = false
var sheetDelete = false
var sheetAdvanced = false
var sheetSSIM: String?
var panelQuality: Double?
var shouldConvert = false
var measure = false
var scrollTest = false
var inspectorWidth: Double?
var onscreen = false
var inputs: [URL] = []

while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { die("\(a) 缺少参数\n" + usage) }
        return args.removeFirst()
    }
    switch a {
    case "--appearance": appearance = value()
    case "--size":
        let parts = value().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { die("--size 要写成 宽x高") }
        size = NSSize(width: parts[0], height: parts[1])
    case "--view": viewMode = BrowserMode(rawValue: value())
    case "--sidebar": sidebarEntry = value()
    case "--select": selectNames.append(value())
    case "--search": searchText = value()
    case "--sheet": showSheet = true
    case "--sheet-delete": showSheet = true; sheetDelete = true
    case "--sheet-advanced": showSheet = true; sheetAdvanced = true
    case "--sheet-bad-ssim": showSheet = true; sheetAdvanced = true; sheetSSIM = value()
    case "--quality":
        guard let q = Double(value()), (0.4...1).contains(q) else { die("--quality 要在 0.4–1 之间") }
        panelQuality = q
    case "--convert": shouldConvert = true
    case "--measure": measure = true
    case "--scroll": scrollTest = true
    case "--inspector": inspectorWidth = Double(value())
    case "--onscreen": onscreen = true
    default:
        if a.hasPrefix("--") { die("不认识的选项 \(a)\n" + usage) }
        inputs.append(URL(fileURLWithPath: a))
    }
}

NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func wait(timeout: TimeInterval, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return done()
}

let store = MemoryStore()
if let viewMode { store.setValue(viewMode.rawValue, forKey: "browser.mode") }
if let panelQuality { store.setValue(panelQuality, forKey: "panel.quality") }
let controller = MainWindowController(store: store, autosave: false)
let window = controller.window!
window.setContentSize(size)
window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
window.orderBack(nil)
controller.applyDefaultSplitPositions()
settle(0.1)

let started = Date()
if !inputs.isEmpty { controller.add(urls: inputs) }
// 扫描和读元数据做完，第一屏缩略图出齐。
func idle() -> Bool {
    !controller.library.isBusy && (controller.visible.isEmpty || controller.browser.visibleThumbnailsReady)
}
_ = wait(timeout: 2) { !controller.library.library.isEmpty || inputs.isEmpty }
if measure {
    let firstScreen = wait(timeout: 60) {
        !controller.visible.isEmpty && controller.browser.visibleThumbnailsReady
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    print(firstScreen ? "首屏缩略图出齐：\(ms) ms（此刻已列出 \(controller.visible.count) 张）" : "首屏缩略图 60 秒内没有出齐")
}
_ = wait(timeout: 120, idle)
if measure {
    print("扫描和读元数据全部做完：\(Int(Date().timeIntervalSince(started) * 1000)) ms（共 \(controller.library.library.items.count) 张）")
}

if shouldConvert {
    let targets = ConversionTargets(selected: [], visible: controller.visible, entry: controller.entry,
                                    entryName: controller.entry.title(), search: controller.search)
    controller.startConversion(targets, settings: PanelSettings.load(from: store))
    _ = wait(timeout: 120) { !controller.conversion.isRunning }
    _ = wait(timeout: 60, idle)
    settle(0.3)
    _ = wait(timeout: 60, idle)
}

if let name = sidebarEntry {
    let lib = controller.library.library
    let fixed: [String: LibraryEntry] = ["全部图片": .all, "可以转换": .convertible, "有备注": .withNotes,
                                         "最近一次转换": .conversion(.all), "有差异": .conversion(.differences),
                                         "失败": .conversion(.failures), "单独添加的图片": .looseFiles]
    func findFolder(_ nodes: [FolderNode]) -> String? {
        for n in nodes {
            if n.name == name || n.path == name { return n.path }
            if let found = findFolder(n.children) { return found }
        }
        return nil
    }
    if let e = fixed[name] {
        controller.selectEntry(e)
    } else if let path = findFolder(lib.folderTree()) {
        controller.selectEntry(.folder(path))
    } else {
        die("侧栏里没有「\(name)」")
    }
}
if let searchText { controller.setSearch(searchText) }
if !selectNames.isEmpty { controller.selectNames(selectNames) }
_ = wait(timeout: 30, idle)
settle(0.4)
_ = wait(timeout: 30, idle)

if scrollTest {
    let grid = controller.browser.grid
    let clip = grid.enclosingScrollView!.contentView
    var worst = 0.0
    var steps = 0
    var y: CGFloat = 0
    let total = grid.frame.height
    while y < total {
        let t0 = Date()
        clip.scroll(to: NSPoint(x: 0, y: y))
        grid.enclosingScrollView!.reflectScrolledClipView(clip)
        grid.layoutSubtreeIfNeeded()
        grid.displayIfNeeded()
        RunLoop.current.run(mode: .default, before: Date())
        worst = max(worst, Date().timeIntervalSince(t0))
        steps += 1
        y += clip.bounds.height / 2
        settle(0.016)
    }
    print("滚动 \(steps) 步（每步半屏），主线程每步最长 \(Int(worst * 1000)) ms")
    clip.scroll(to: .zero)
    grid.enclosingScrollView!.reflectScrolledClipView(clip)
    _ = wait(timeout: 30, idle)
}

if let inspectorWidth { controller.setInspectorWidth(CGFloat(inspectorWidth)); settle(0.3) }
window.contentView?.layoutSubtreeIfNeeded()
window.displayIfNeeded()
settle(0.2)

if onscreen {
    // 真实窗口：放到屏幕上、置前，等系统合成完再用 screencapture 按窗口号截。
    NSApp.setActivationPolicy(.regular)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    settle(1.5)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-o", "-x", "-l", "\(window.windowNumber)", outPath]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { die("screencapture 失败（退出码 \(p.terminationStatus)）") }
    print("已写出 \(outPath)（真实窗口）")
    exit(0)
}

/// 整个窗口（含工具栏）渲染成位图。
func render(_ view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

let frameView = window.contentView!.superview ?? window.contentView!
// 毛玻璃（NSVisualEffectView）由窗口服务器合成，cacheDisplay 画不出来，会是黑的。
// 截图时把它们换成不透明的系统色：侧栏用 windowBackgroundColor，列表里选中行的
// 高亮用 unemphasizedSelectedContentBackgroundColor（离屏窗口本来就是非活动状态）。
// 真实窗口里侧栏是半透明的，颜色会比截图里略浅或略深。
func flattenVibrancy(_ v: NSView) {
    for sub in v.subviews { flattenVibrancy(sub) }
    // 新系统上侧栏是一块「玻璃」（NSGlassEffectView，玻璃本身画在一个托管视图里），同样画不出来。
    if String(describing: type(of: v)).contains("GlassEffectView") {
        for sub in v.subviews where String(describing: type(of: sub)).contains("HostingView") { sub.isHidden = true }
        v.wantsLayer = true
        frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
            v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        return
    }
    guard let e = v as? NSVisualEffectView, !e.isHidden, let parent = e.superview else { return }
    var inRow = false
    var p: NSView? = parent
    while let q = p { if q is NSTableRowView { inRow = true; break }; p = q.superview }
    let fill = NSView(frame: e.frame)
    fill.autoresizingMask = e.autoresizingMask
    fill.wantsLayer = true
    fill.layer?.cornerRadius = inRow ? 5 : 0
    frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
        fill.layer?.backgroundColor = (inRow ? NSColor.unemphasizedSelectedContentBackgroundColor
                                             : NSColor.windowBackgroundColor).cgColor
    }
    parent.addSubview(fill, positioned: .below, relativeTo: e)
    e.isHidden = true
}
flattenVibrancy(frameView)
frameView.layoutSubtreeIfNeeded()
frameView.displayIfNeeded()
guard var rep = render(frameView) else { die("无法创建位图") }

/// 把 `views` 各自单独渲染，按它们在窗口里的位置盖到 `base` 上（底下先铺一层窗口背景色）。
/// `clipTop` 是窗口顶上不盖的那一截（标题栏和工具栏）。
func overlay(_ base: NSBitmapImageRep, _ views: [NSView], clipTop: CGFloat = 0) -> NSBitmapImageRep {
    let size = frameView.bounds.size
    let image = NSImage(size: size)
    image.lockFocus()
    let baseImage = NSImage(size: size)
    baseImage.addRepresentation(base)
    baseImage.draw(in: NSRect(origin: .zero, size: size))
    NSRect(x: 0, y: 0, width: size.width, height: size.height - clipTop).clip()
    for v in views where !v.isHidden && v.window != nil {
        guard let r = render(v) else { continue }
        let frame = v.convert(v.bounds, to: nil)
        NSColor.windowBackgroundColor.setFill()
        frame.fill()
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(r)
        img.draw(in: frame)
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return base }
    return out
}

// 侧栏的内容放在玻璃里，整窗渲染时画不出来（黑的），单独渲染再盖上去。标题栏那一截不盖。
// source list 样式的行同样画不出（空白），截图里侧栏换成 plain 样式、普通外观来画：
// 内容、张数、层级是真的，行距和选中高亮与真实窗口略有不同。
do {
    let sidebarRoot = controller.sidebar.view
    sidebarRoot.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    controller.sidebar.outline.style = .plain
    controller.sidebar.outline.reloadData()
    controller.sidebar.update(library: controller.library.library, record: controller.record, selected: controller.entry)
    sidebarRoot.layoutSubtreeIfNeeded()
    sidebarRoot.displayIfNeeded()
    frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
        rep = overlay(rep, [sidebarRoot, controller.sidebar.outline.enclosingScrollView!], clipTop: frameView.bounds.height - window.contentLayoutRect.height)
    }
}

if showSheet {
    guard let sheet = controller.makeConversionSheet() else { die("当前视图里没有可以转换的 JPEG 或 RAW，没有面板可显示") }
    let sheetWindow = sheet.makeWindow()
    if sheetDelete { sheet.checkDeleteForSnapshot() }
    if sheetAdvanced { sheet.showAdvancedForSnapshot(ssim: sheetSSIM) }
    sheetWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    sheetWindow.orderBack(nil)
    sheet.view.layoutSubtreeIfNeeded()
    settle(0.2)
    guard let sheetRep = render(sheet.view) else { die("无法渲染转换面板") }
    // 合成：面板贴在工具栏下方、窗口水平居中，带一层阴影。
    let base = NSImage(size: frameView.bounds.size)
    base.addRepresentation(rep)
    let composite = NSImage(size: frameView.bounds.size)
    composite.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: frameView.bounds.size))
    let toolbarHeight = frameView.bounds.height - window.contentLayoutRect.height
    let sheetSize = sheet.view.bounds.size
    let origin = NSPoint(x: (frameView.bounds.width - sheetSize.width) / 2,
                         y: frameView.bounds.height - toolbarHeight - sheetSize.height)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.windowBackgroundColor.setFill()
    NSBezierPath(roundedRect: NSRect(origin: origin, size: sheetSize), xRadius: 10, yRadius: 10).fill()
    NSGraphicsContext.restoreGraphicsState()
    let sheetImage = NSImage(size: sheetSize)
    sheetImage.addRepresentation(sheetRep)
    sheetImage.draw(in: NSRect(origin: origin, size: sheetSize))
    composite.unlockFocus()
    guard let tiff = composite.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) else { die("无法合成") }
    rep = r
}

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { die("写不出 \(outPath)：\(error.localizedDescription)") }
print("已写出 \(outPath)")
