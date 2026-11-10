// 命令行参数解析。
//
// 单独成文件、不碰 CommandLine 也不 exit()，是为了能链进测试里直接调用：
// "命令行与界面默认值是否一致"这类断言要真的解析一遍命令行。

import Foundation

enum ArgumentError: Error, LocalizedError {
    case missingValue(flag: String)
    case badQuality(String)
    case badJobs(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "选项 \(flag) 缺少参数"
        case .badQuality(let raw): return "质量必须是 0.0 到 1.0 之间的数字，收到: \(raw)"
        case .badJobs(let raw): return "并发数必须是正整数，收到: \(raw)"
        case .unknownOption(let opt): return "未知选项: \(opt)（用 --help 查看用法）"
        }
    }
}

enum ParsedArguments: Equatable {
    case run(ConversionOptions)
    /// 该打印用法并以这个状态码退出：`--help` 是 0，没给输入是 1。
    case showUsage(exitCode: Int32)
}

func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
    var o = ConversionOptions.default
    var args = arguments
    var sawSeparator = false

    func next(_ flag: String) throws -> String {
        guard !args.isEmpty else { throw ArgumentError.missingValue(flag: flag) }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let a = args.removeFirst()
        if sawSeparator { o.inputs.append(a); continue }
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
        case "--delete-original": o.deleteOriginal = true
        case "--verify": o.verify = true
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
