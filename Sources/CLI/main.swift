// jpeg2heif 命令行入口。转换逻辑全部在 Sources/Core/Converter.swift，
// 这里只负责解析参数和把结果打印出来。

import Foundation

let usage = """
用法: jpeg2heif [选项] <文件或目录> ...

把 JPEG 转换成 HEIF(.heic)，同时完整保留 EXIF（拍摄时间/相机参数）、
GPS（拍摄位置）、IPTC、XMP（备注/标题/版权）以及文件时间戳、访达备注与标签。

选项:
  -q, --quality <0.0-1.0>  有损压缩质量，默认 0.8（越高越清晰、文件越大）
  -o, --output <路径>       输出目录；单个输入时也可以是输出文件名。
                           默认输出到源文件同一目录
  -r, --recursive          递归处理目录中的所有 JPEG
  -f, --overwrite          覆盖已存在的输出文件
      --delete-original    删除源 JPEG（会自动先做 --verify，只有完全无损、
                           且 HEIF 不比原图大才删）
      --verify             转换后逐条比对元数据，报告任何丢失或变化的条目
      --no-raw-exif        EXIF 交给系统重写，不整块照搬源文件的 EXIF。
                           遇到读不了产物的软件时用
  -n, --dry-run            只打印将要做什么，不实际写文件
  -j, --jobs <n>           并发任务数，默认 \(ProcessInfo.processInfo.activeProcessorCount)
  -v, --verbose            输出每张图保留的元数据条目数，以及 EXIF 整块照搬了没有
  -h, --help               显示本帮助

示例:
  jpeg2heif photo.jpg                          转单张
  jpeg2heif ~/Pictures/2024                    转该文件夹顶层的所有 JPEG
  jpeg2heif -r ~/Pictures/2024 -o ~/输出       递归整个文件夹，输出到别处
  jpeg2heif --verify --delete-original -r ./相册   校验无损后替换源文件
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("错误: \(msg)\n".utf8))
    exit(2)
}

func warn(_ msg: String) {
    FileHandle.standardError.write(Data("警告: \(msg)\n".utf8))
}

// MARK: - 主流程

let opts: ConversionOptions
do {
    switch try parseArguments(Array(CommandLine.arguments.dropFirst())) {
    case .run(let parsed):
        opts = parsed
    case .showUsage(let code):
        print(usage)
        exit(code)
    }
} catch {
    fail(error.localizedDescription)
}
let (files, warnings) = collectInputs(opts)
for w in warnings { warn(w) }
guard !files.isEmpty else { fail("没有找到要处理的文件") }

let plan: OutputPlan
do {
    plan = try OutputPlan.resolve(output: opts.output, fileCount: files.count,
                                  createDirectories: !opts.dryRun)
} catch {
    fail(error.localizedDescription)
}

/// 指定了输出目录时，显示相对该目录的路径：递归转换能看出文件落在哪个子目录，
/// 重名避让后也不会出现两行一模一样的 "a.jpg → a.heic"。
func displayName(_ dest: URL) -> String {
    guard let dir = plan.directory else { return dest.lastPathComponent }
    return relativePath(of: dest, under: dir) ?? dest.lastPathComponent
}

var tally = BatchTally()

let renameNotices = runConversions(files, opts: opts, plan: plan) { job, result in
    tally.record(result)
    let input = job.input
    switch result {
    case .converted(let r):
        let prefix = opts.dryRun ? "[预演] " : ""
        var line = "\(prefix)\(input.lastPathComponent) → \(displayName(r.dest))"
        if !opts.dryRun, let pct = r.savingPercent {
            line += "  \(humanSize(r.inBytes)) → \(humanSize(r.outBytes)) (\(pct >= 0 ? "省 \(pct)" : "大 \(-pct)")%)"
        }
        print(line)
        if opts.verbose {
            print("    元数据条目 \(r.tagCount) 项，扩展属性 \(r.xattrCount) 项")
            switch r.rawExif {
            case .carried(let bytes)?: print("    EXIF 整块照搬（\(bytes) 字节）")
            case .kept(let why)?: print("    EXIF 没有照搬：\(why)")
            case nil: break
            }
            if let reencode = r.reencode { print("    \(reencode.description)") }
        }
        switch r.verification {
        case .differences(let issues):
            print("    ⚠︎ 元数据校验发现 \(issues.count) 处差异:")
            // 差异多的时候默认只列前几条，加 -v 看全部。
            let shown = opts.verbose ? issues.count : 10
            for i in issues.prefix(shown) { print("       - \(i)") }
            if issues.count > shown {
                print("       - …还有 \(issues.count - shown) 处（加 -v 看全部）")
            }
        case .passed:
            print("    ✓ 元数据校验通过")
        case .notVerified:
            break
        }
        // 状态说明单独一行，不混进上面的差异列表。
        if let note = r.note { print("    \(note)") }
    case .skipped(let why):
        print("跳过 \(input.lastPathComponent): \(why)")
    case .failed(let why):
        FileHandle.standardError.write(Data("失败 \(input.lastPathComponent): \(why)\n".utf8))
    }
}

for notice in renameNotices { warn(notice) }

if files.count > 1 || opts.verifyEnabled {
    print("---")
    print(tally.summary(unit: "个"))
}

exit(tally.failed > 0 ? 1 : 0)
