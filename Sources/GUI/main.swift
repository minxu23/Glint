// 图形界面入口。用 AppKit 而不是 SwiftUI：SwiftUI 的属性包装器现在是宏，
// 宏插件只随完整版 Xcode 分发，而 AppKit 用命令行工具即可构建。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController!
    private let store = DefaultsStore()
    /// 「应用图标」子菜单里的各项，换了款式后更新勾选。
    private var iconItems: [NSMenuItem] = []
    private var launched = false
    /// 启动时随「打开方式」送进来的路径会先于 applicationDidFinishLaunching 到，先攒着。
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.apply(AppIconChoice.load(from: store), launching: true)
        controller = MainWindowController(store: store)
        controller.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        launched = true
        if !pendingURLs.isEmpty { controller.add(urls: pendingURLs); pendingURLs = [] }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 切回应用时重新读取（不监视文件夹变化）。启动那一次不算。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard launched, controller != nil else { return }
        controller.library.reload()
    }

    /// 在访达里对图片或文件夹选「打开方式」，或拖到程序坞图标上。
    func application(_ application: NSApplication, open urls: [URL]) {
        if let controller { controller.add(urls: urls) } else { pendingURLs += urls }
    }

    /// 「应用图标」子菜单里选了一款：记住，马上换上。
    @objc func chooseAppIcon(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AppIconChoice(rawValue: raw) else { return }
        choice.save(to: store)
        AppIcon.apply(choice)
        updateIconItems(choice)
    }

    private func updateIconItems(_ choice: AppIconChoice) {
        for i in iconItems { i.state = (i.representedObject as? String) == choice.rawValue ? .on : .off }
    }

    /// 应用菜单里的「应用图标」：每款一项，带一张小图。
    private func appIconMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "应用图标")
        iconItems = AppIconChoice.allCases.map { choice in
            let i = NSMenuItem(title: choice.title, action: #selector(chooseAppIcon(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = choice.rawValue
            if let img = AppIcon.image(choice)?.copy() as? NSImage {
                img.size = NSSize(width: 16, height: 16)
                i.image = img
            }
            menu.addItem(i)
            return i
        }
        updateIconItems(AppIconChoice.load(from: store))
        let holder = NSMenuItem(title: "应用图标", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// 没有 nib 就得自己搭菜单。动作发给响应链（nil target），由主窗口或当前焦点处理。
    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        let hideOthers = item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = submenu(appName, [
            item("关于\(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            appIconMenuItem(),
            .separator(),
            item("隐藏\(appName)", #selector(NSApplication.hide(_:)), "h"),
            hideOthers,
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("退出\(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])

        _ = submenu("文件", [
            item("添加文件夹…", #selector(MainWindowController.addFolder(_:)), "o", [.command, .shift]),
            item("打开", #selector(MainWindowController.openSelected(_:)), "o"),
            item("在访达中显示", #selector(MainWindowController.revealSelected(_:)), "r", [.command, .shift]),
            .separator(),
            item("转换…", #selector(MainWindowController.showConversion(_:)), "e"),
            item("取消转换", #selector(MainWindowController.cancelConversion(_:)), "."),
            .separator(),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
        ])

        _ = submenu("编辑", [
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("查找", #selector(MainWindowController.focusSearch(_:)), "f"),
        ])

        _ = submenu("显示", [
            item("网格", #selector(MainWindowController.showGrid(_:)), "1"),
            item("列表", #selector(MainWindowController.showList(_:)), "2"),
            .separator(),
            item("放大", #selector(MainWindowController.zoomIn(_:)), "+"),
            item("缩小", #selector(MainWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("隐藏侧栏", #selector(MainWindowController.toggleSidebarPane(_:)), "s", [.command, .control]),
            item("隐藏信息栏", #selector(MainWindowController.toggleInspectorPane(_:)), "i", [.command, .option]),
            .separator(),
            item("重新读取", #selector(MainWindowController.reloadLibrary(_:)), "r"),
        ])

        let windowMenu = submenu("窗口", [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = windowMenu
        let helpMenu = submenu("帮助", [])
        NSApp.helpMenu = helpMenu
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
