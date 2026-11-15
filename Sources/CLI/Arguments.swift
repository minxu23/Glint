// 两个命令共用的参数解析。
//
// 单独成文件、不碰 CommandLine 也不 exit()，是为了能链进测试里直接调用：
// "命令行与界面默认值是否一致"这类断言要真的解析一遍命令行。

import Eclose
import Foundation

/// 两个命令：jpeg2heif 转 JPEG，raw2heif 转相机 RAW。选项大体相同，差在：收的源、
/// 默认并发数（RAW 用 ConversionOptions.defaultRAWJobs）、raw2heif 不接受 --delete-original
/// 和 --allow-cmyk（RAW 没有 CMYK 一说，当未知选项报错），以及画质核对的四个选项只有 jpeg2heif 有
/// （raw2heif 给了就报错，RAW 不核对画质）。
enum Command {
    case jpeg2heif, raw2heif

    var name: String {
        switch self {
        case .jpeg2heif: return "jpeg2heif"
        case .raw2heif: return "raw2heif"
        }
    }

    var source: SourceKind {
        switch self {
        case .jpeg2heif: return .jpeg
        case .raw2heif: return .raw
        }
    }
}

enum ArgumentError: Error, LocalizedError {
    case missingValue(flag: String)
    case badQuality(String)
    case badJobs(String)
    case unknownOption(String)
    case keepsRAW(flag: String)
    case badMinSSIM(String)
    case badMinPSNR(String)
    case badQualityDrop(String)
    case noQualityCheckForRAW(flag: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "选项 \(flag) 缺少参数"
        case .badQuality(let raw): return "质量必须是 0.0 到 1.0 之间的数字，收到: \(raw)"
        case .badJobs(let raw): return "并发数必须是正整数，收到: \(raw)"
        case .unknownOption(let opt): return "未知选项: \(opt)（用 --help 查看用法）"
        case .keepsRAW(let flag): return "raw2heif 不删除 RAW 原片，不接受 \(flag)"
        case .badMinSSIM(let raw): return "--min-ssim 必须是 0 到 1 之间的数字，收到: \(raw)"
        case .badMinPSNR(let raw): return "--min-psnr 必须是 0 到 100 之间的数字（单位 dB），收到: \(raw)"
        case .badQualityDrop(let raw): return "--on-quality-drop 只能是 skip（不转）或 retry（提高质量再试），收到: \(raw)"
        case .noQualityCheckForRAW(let flag): return "raw2heif 不核对画质（画质核对只对 JPEG），不接受 \(flag)"
        }
    }
}

/// 画质核对的四个选项。只有 jpeg2heif 认；raw2heif 遇到任何一个都报错。
let qualityCheckFlags: Set<String> = ["--no-quality-check", "--min-ssim", "--min-psnr", "--on-quality-drop"]

enum ParsedArguments: Equatable {
    case run(ConversionOptions)
    /// 该打印用法并以这个状态码退出：`--help` 是 0，没给输入是 1。
    case showUsage(exitCode: Int32)
}

func parseArguments(_ arguments: [String], command: Command) throws -> ParsedArguments {
    var o = ConversionOptions.default
    o.sources = [command.source]
    if command == .raw2heif { o.jobs = ConversionOptions.defaultRAWJobs }
    var args = arguments
    var sawSeparator = false

    func next(_ flag: String) throws -> String {
        guard !args.isEmpty else { throw ArgumentError.missingValue(flag: flag) }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let a = args.removeFirst()
        if sawSeparator { o.inputs.append(a); continue }
        if command == .raw2heif, qualityCheckFlags.contains(a) { throw ArgumentError.noQualityCheckForRAW(flag: a) }
        switch a {
        case "-h", "--help": return .showUsage(exitCode: 0)
        case "--": sawSeparator = true
        case "-q", "--quality":
            let raw = try next(a)
            guard let v = Double(raw), v >= 0, v <= 1 else { throw ArgumentError.badQuality(raw) }
            o.quality = v
        case "-o", "--output":
            o.output = URL(fileURLWithPath: (try next(a) as NSString).expandingTildeInPath)
        case "-r", "--recursive": o.recursive = true
        case "-f", "--overwrite": o.overwrite = true
        case "--delete-original":
            // RAW 永远保留：报错退出，一张都不转。
            guard command != .raw2heif else { throw ArgumentError.keepsRAW(flag: a) }
            o.deleteOriginal = true
        case "--verify": o.verify = true
        case "--no-raw-exif": o.rawExif = false
        case "--embed-caption": o.embedCaption = true
        case "--allow-cmyk" where command == .jpeg2heif: o.convertCMYK = true
        case "--no-quality-check": o.qualityCheck = false
        case "--min-ssim":
            let raw = try next(a)
            guard let v = QualityThresholds.parseSSIM(raw) else { throw ArgumentError.badMinSSIM(raw) }
            o.qualityThresholds.minSSIM = v
        case "--min-psnr":
            let raw = try next(a)
            guard let v = QualityThresholds.parsePSNR(raw) else { throw ArgumentError.badMinPSNR(raw) }
            o.qualityThresholds.minPSNR = v
        case "--on-quality-drop":
            let raw = try next(a)
            guard let v = QualityDropAction(rawValue: raw) else { throw ArgumentError.badQualityDrop(raw) }
            o.onQualityDrop = v
        case "-n", "--dry-run": o.dryRun = true
        case "-v", "--verbose": o.verbose = true
        case "-j", "--jobs":
            let raw = try next(a)
            guard let v = Int(raw), v >= 1 else { throw ArgumentError.badJobs(raw) }
            o.jobs = v
        default:
            if a.hasPrefix("-") && a.count > 1 { throw ArgumentError.unknownOption(a) }
            o.inputs.append(a)
        }
    }
    return o.inputs.isEmpty ? .showUsage(exitCode: 1) : .run(o)
}
