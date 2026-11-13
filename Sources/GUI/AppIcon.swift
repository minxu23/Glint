// 把用户选的应用图标用上：程序坞里正在运行的图标、关于面板，以及访达和没在运行时的程序坞。
//
// macOS 没有给应用换图标的正式接口（iOS 的 setAlternateIconName 在 AppKit 里没有）。
// 运行时改 NSApp.applicationIconImage；不运行时显示的是应用包的图标，只能给应用包设自定义
// 图标（与在「显示简介」里粘贴图标同一做法：应用包根目录多一个 `Icon\r` 文件）。选回默认款式时
// 把自定义图标去掉，应用包恢复原样。重新 make 或 make install-dev 后自定义图标会没，下次启动补上。

import AppKit

enum AppIcon {
    /// 应用包里某款图标的图像。
    static func image(_ choice: AppIconChoice, in bundle: Bundle = .main) -> NSImage? {
        bundle.url(forResource: choice.resourceName, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// 应用包是不是带着自定义图标。
    static func hasCustomIcon(_ bundle: Bundle = .main) -> Bool {
        FileManager.default.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Icon\r").path)
    }

    /// 用上 `choice`。`launching` 为真时只在应用包的状态与选择不符时才动它（启动时调用），
    /// 否则总是重设（用户刚在菜单里换了）。
    static func apply(_ choice: AppIconChoice, launching: Bool = false, bundle: Bundle = .main) {
        let isDefault = choice == .default
        // nil 让程序坞回到应用包自带的图标
        NSApp.applicationIconImage = isDefault ? nil : image(choice, in: bundle)

        let custom = hasCustomIcon(bundle)
        if launching && custom != isDefault { return }
        // 改不了（比如应用包在只读的位置）就算了：运行时的图标已经换上
        _ = NSWorkspace.shared.setIcon(isDefault ? nil : image(choice, in: bundle), forFile: bundle.bundlePath, options: [])
    }
}
