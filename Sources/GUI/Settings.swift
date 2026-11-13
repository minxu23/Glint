// 设置的读写：转换面板记住的那几项、浏览的偏好、加进来的文件夹。
//
// 存储可以注入（应用里是 UserDefaults，测试里是字典），好测「删除源文件」「覆盖同名的 HEIF」
// 不被记住。不依赖 AppKit。

import Eclose
import Foundation

/// 键值存储。
protocol SettingsStore: AnyObject {
    func value(forKey key: String) -> Any?
    func setValue(_ value: Any?, forKey key: String)
}

/// 应用里用的存储。
final class DefaultsStore: SettingsStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func value(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func setValue(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// 只在内存里的存储（测试、截图工具用）。
final class MemoryStore: SettingsStore {
    private(set) var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func value(forKey key: String) -> Any? { values[key] }
    func setValue(_ value: Any?, forKey key: String) { values[key] = value }
}

// MARK: - 转换面板

/// 转换面板上的设置。打开面板时从存储读，开始转换时写回。
/// 「删除源文件」「覆盖同名的 HEIF」「也转 CMYK 的 JPEG」不读也不写：每次打开面板都是关的。
struct PanelSettings: Equatable {
    var quality: Double
    /// 保存到指定文件夹；nil 是源文件旁边。
    var outputFolder: URL?
    var verify: Bool
    var embedCaption: Bool
    /// 「EXIF 交给系统重写」，即 ConversionOptions.rawExif 取反。
    var systemExif: Bool
    var deleteOriginal = false
    var overwrite = false
    /// 「也转 CMYK 的 JPEG」，即 ConversionOptions.convertCMYK。强制转换颜色会变，不记住。
    var convertCMYK = false

    private enum Key {
        static let quality = "panel.quality"
        static let outputFolder = "panel.outputFolder"
        static let verify = "panel.verify"
        static let embedCaption = "panel.embedCaption"
        static let systemExif = "panel.systemExif"
    }

    /// 没存过时的默认值：取自 ConversionOptions.default，只有校验有意不同（界面默认校验，
    /// 见 ConversionModel.options 的说明）。
    static var defaults: PanelSettings {
        let o = ConversionOptions.default
        return PanelSettings(quality: o.quality, outputFolder: nil, verify: true,
                             embedCaption: o.embedCaption, systemExif: !o.rawExif)
    }

    static func load(from store: SettingsStore) -> PanelSettings {
        var s = defaults
        if let q = store.value(forKey: Key.quality) as? Double, (0.4...1.0).contains(q) { s.quality = q }
        if let path = store.value(forKey: Key.outputFolder) as? String, !path.isEmpty {
            s.outputFolder = URL(fileURLWithPath: path)
        }
        if let v = store.value(forKey: Key.verify) as? Bool { s.verify = v }
        if let v = store.value(forKey: Key.embedCaption) as? Bool { s.embedCaption = v }
        if let v = store.value(forKey: Key.systemExif) as? Bool { s.systemExif = v }
        return s
    }

    func save(to store: SettingsStore) {
        store.setValue(quality, forKey: Key.quality)
        store.setValue(outputFolder?.path ?? "", forKey: Key.outputFolder)
        // 勾着删除时校验是被锁上的，那不是用户自己的选择，存的是锁之前的值。
        store.setValue(verify, forKey: Key.verify)
        store.setValue(embedCaption, forKey: Key.embedCaption)
        store.setValue(systemExif, forKey: Key.systemExif)
    }

    /// 实际生效的「逐项校验」：勾了删除源文件就必须校验（与 ConversionOptions.verifyEnabled 一致）。
    var effectiveVerify: Bool { verify || deleteOriginal }
    /// 「转完逐项校验」能不能改。
    var verifyLocked: Bool { deleteOriginal }

    /// 把面板设置落到 ConversionOptions 上。输入输出不在这里：输入是 Job，输出由
    /// ConversionModel 的 outputMode/outputFolder 管。收哪几种源、并发数、删除对这批生不生效
    /// 跟着这批的对象走，由 ConversionTargets.apply 在这之上再定。
    func apply(to options: inout ConversionOptions) {
        options.quality = quality
        options.verify = effectiveVerify
        options.embedCaption = embedCaption
        options.rawExif = !systemExif
        options.deleteOriginal = deleteOriginal
        options.overwrite = overwrite
        options.convertCMYK = convertCMYK
    }
}

/// 画质滑杆的取值：0.4–1.0，步长 0.05。
func steppedQuality(_ raw: Double) -> Double {
    min(1.0, max(0.4, (raw * 20).rounded() / 20))
}

// MARK: - 浏览偏好

enum BrowserMode: String {
    case grid, list
}

/// 网格单元边长的范围和默认值。
enum CellSize {
    static let range: ClosedRange<Double> = 96...320
    static let `default`: Double = 168
    static let step: Double = 24

    static func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
}

struct BrowserSettings: Equatable {
    var mode: BrowserMode = .grid
    var cellSize: Double = CellSize.default
    var sort = SortOrder()
    var inspectorVisible = true

    private enum Key {
        static let mode = "browser.mode"
        static let cellSize = "browser.cellSize"
        static let sortKey = "browser.sortKey"
        static let ascending = "browser.ascending"
        static let inspector = "browser.inspectorVisible"
    }

    static func load(from store: SettingsStore) -> BrowserSettings {
        var s = BrowserSettings()
        if let raw = store.value(forKey: Key.mode) as? String, let m = BrowserMode(rawValue: raw) { s.mode = m }
        if let v = store.value(forKey: Key.cellSize) as? Double { s.cellSize = CellSize.clamp(v) }
        if let raw = store.value(forKey: Key.sortKey) as? String, let k = SortKey(rawValue: raw) { s.sort.key = k }
        if let v = store.value(forKey: Key.ascending) as? Bool { s.sort.ascending = v }
        if let v = store.value(forKey: Key.inspector) as? Bool { s.inspectorVisible = v }
        return s
    }

    func save(to store: SettingsStore) {
        store.setValue(mode.rawValue, forKey: Key.mode)
        store.setValue(cellSize, forKey: Key.cellSize)
        store.setValue(sort.key.rawValue, forKey: Key.sortKey)
        store.setValue(sort.ascending, forKey: Key.ascending)
        store.setValue(inspectorVisible, forKey: Key.inspector)
    }
}

// MARK: - 来源

/// 加进来的文件夹（路径）。单独添加的图片不记。
enum SavedFolders {
    private static let key = "library.folders"

    static func load(from store: SettingsStore) -> [String] {
        (store.value(forKey: key) as? [String]) ?? []
    }

    static func save(_ folders: [String], to store: SettingsStore) {
        store.setValue(folders, forKey: key)
    }
}

// MARK: - 应用图标

/// 应用图标的款式，用户在应用菜单「应用图标」里选。图标文件随应用包分发
/// （Contents/Resources/<resourceName>.icns，由 Tools/make_icon.swift 生成）。
enum AppIconChoice: String, CaseIterable {
    /// 米白底、青到靛的渐变线条。应用包自带的就是这款（Info.plist 的 CFBundleIconFile）。
    case light
    /// 青到靛的渐变底、白色线条。
    case gradient

    static let `default` = AppIconChoice.light
    private static let key = "app.icon"

    var title: String {
        switch self {
        case .light: return "浅色"
        case .gradient: return "渐变"
        }
    }

    /// 应用包里图标文件的名字，不带扩展名。
    var resourceName: String {
        switch self {
        case .light: return "AppIcon"
        case .gradient: return "AppIcon-Gradient"
        }
    }

    /// 没存过、或存的值不认识（比如以后删掉的款式），都用默认的。
    static func load(from store: SettingsStore) -> AppIconChoice {
        (store.value(forKey: key) as? String).flatMap(AppIconChoice.init(rawValue:)) ?? .default
    }

    func save(to store: SettingsStore) {
        store.setValue(rawValue, forKey: Self.key)
    }
}
