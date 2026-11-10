// 界面截图工具（开发用）。复用真实的 MainViewController，把窗口离屏渲染成 PNG，
// 这样不需要屏幕录制权限也能检查界面排版。
//
// 用法: uisnapshot <输出.png> [--convert] [要加入列表的文件或目录 ...]

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write(Data("用法: uisnapshot <输出.png> [--convert] [文件 ...]\n".utf8))
    exit(2)
}
let outPath = args.removeFirst()
var shouldConvert = false
if let i = args.firstIndex(of: "--convert") {
    shouldConvert = true
    args.remove(at: i)
}
let inputs = args.map { URL(fileURLWithPath: $0) }

let controller = MainViewController()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                      styleMask: [.titled, .closable, .resizable],
                      backing: .buffered, defer: false)
window.contentViewController = controller
window.title = "JPEG 转 HEIF"

func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

if !inputs.isEmpty { controller.add(urls: inputs) }
settle(0.3)

if shouldConvert {
    func findButton(_ view: NSView, title: String) -> NSButton? {
        if let b = view as? NSButton, b.title == title { return b }
        for sub in view.subviews {
            if let found = findButton(sub, title: title) { return found }
        }
        return nil
    }
    findButton(window.contentView!, title: "开始转换")?.performClick(nil)
    settle(4.0)
}

window.contentView?.layoutSubtreeIfNeeded()
settle(0.2)

guard let view = window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    FileHandle.standardError.write(Data("无法创建位图\n".utf8))
    exit(1)
}
view.cacheDisplay(in: view.bounds, to: rep)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("已写出 \(outPath)")
