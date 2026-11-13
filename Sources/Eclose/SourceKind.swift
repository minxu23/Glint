// 转换的源分两种：JPEG 与 RAW。两种走不同的管线（convert 按它分派），两个命令各收一种。

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SourceKind: Hashable, CaseIterable {
    case jpeg, raw

    /// 目录扫描时按扩展名挑文件（小写比较）。扩展名只决定扫不扫，转不转按内容判定（init(typeIdentifier:)）。
    public var extensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg", "jpe", "jfif", "jif"]
        case .raw: return rawExtensions
        }
    }

    /// 「JPEG」「RAW」。
    public var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        }
    }

    /// 转这种源的命令，跳过提示里指路用。
    var command: String {
        switch self {
        case .jpeg: return "jpeg2heif"
        case .raw: return "raw2heif"
        }
    }

    /// 按内容判定：`typeIdentifier` 是 CGImageSourceGetType 给的类型。是 public.jpeg 为 JPEG，符合
    /// public.camera-raw-image 为 RAW，别的（含 nil）不是这两种。
    ///
    /// 小于门槛的 DNG 被 ImageIO 认作 public.tiff，读到的是 8 位的预览图（实测 64×48、128×96 都是），
    /// 按扩展名当 RAW 转会交出一张预览图，所以只认内容。
    init?(typeIdentifier: String?) {
        guard let typeIdentifier else { return nil }
        if typeIdentifier == UTType.jpeg.identifier {
            self = .jpeg
        } else if let type = UTType(typeIdentifier), type.conforms(to: .rawImage) {
            self = .raw
        } else {
            return nil
        }
    }
}

/// raw2heif 扫目录时挑的扩展名：本机 ImageIO 能读的 RAW 类型（CGImageSourceCopyTypeIdentifiers 里
/// 符合 public.camera-raw-image 的那些）的扩展名，macOS 27 上实测。只去掉 `tif`（佳能的
/// com.canon.tif-raw-image）：普通 TIFF 也叫这个扩展名，收进来只会多出一串「不是 RAW 文件」的跳过。
/// 单测逐个核对清单里的扩展名在 UTType 里确实是 RAW。
let rawExtensions: Set<String> = [
    "3fr", "arw", "axr", "cr2", "cr3", "crw", "dcr", "dng", "dxo", "erf", "fff", "iiq", "mos", "mrw",
    "nef", "nefx", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw",
]

/// 一个源转不了时跳过的原因。`type` 是 CGImageSourceGetType 给的类型，`accepted` 是这次收的源。
/// 是另一种源时指路（「是 RAW 文件（用 raw2heif）」）；两种都不是时说「不是 JPEG 文件」这类话，
/// 只收 RAW 时再带上系统认作什么（门槛下的 DNG 是 public.tiff）。
func skipReason(type: String?, accepted: Set<SourceKind>) -> String {
    if let kind = SourceKind(typeIdentifier: type), !accepted.contains(kind) {
        return "是 \(kind.label) 文件（用 \(kind.command)）"
    }
    let wanted = SourceKind.allCases.filter(accepted.contains).map(\.label).joined(separator: " 或 ")
    var reason = "不是 \(wanted) 文件"
    if accepted == [.raw], let type { reason += "（系统认作 \(type)）" }
    return reason
}
