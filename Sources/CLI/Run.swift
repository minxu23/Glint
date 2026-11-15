// 两个命令（jpeg2heif、raw2heif）共用的流程。转换逻辑全部在 Eclose 模块
// （Sources/Eclose/Converter.swift），这里只负责解析参数和把结果打印出来。
// 各自的 main.swift 只有一行：runCommandLine(该命令)。

import Eclose
import Foundation

func usage(for command: Command) -> String {
    switch command {
    case .jpeg2heif:
        return """
        用法: jpeg2heif [选项] <文件或目录> ...

        把 JPEG 转换成 HEIF(.heic)，同时完整保留 EXIF（拍摄时间/相机参数）、
        GPS（拍摄位置）、IPTC、XMP（备注/标题/版权）以及文件时间戳、访达备注与标签。

        选项:
          -q, --quality <0.0-1.0>  有损压缩质量，默认 \(qualityText(ConversionOptions.default.quality))，上限 \(qualityText(qualityCeiling))（越高越清晰、文件越大）。
                                   高于 \(qualityText(qualityCeiling)) 时按 \(qualityText(qualityCeiling)) 转并提示一次：再高编码器改用 4:4:4，
                                   文件翻倍、画质反降
          -o, --output <路径>       输出目录；单个输入时也可以是产物的文件名（以 .heic 或 .heif 结尾）。
                                   默认输出到源文件同一目录
          -r, --recursive          递归处理目录中的所有 JPEG
          -f, --overwrite          覆盖已存在的输出文件
              --delete-original    删除源 JPEG（会自动先做 --verify，只有完全无损、
                                   且 HEIF 不比原图大才删）
              --keep-stale-mpf     原图的 MPF 索引登记的附加图像（如 HDR 增益图）已不在文件里时，
                                   --delete-original 也不删源。默认照删：那张图转换前就没了，
                                   转换没丢东西；不管加不加，都会写一句说明
              --verify             转换后逐条比对元数据，报告任何丢失或变化的条目
              --no-raw-exif        EXIF 交给系统重写，不整块照搬源文件的 EXIF。
                                   遇到读不了产物的软件时用
              --embed-caption      把「照片」App 的说明（文件扩展属性里的那段）写进 HEIF 的
                                   XMP 说明字段 dc:description，让它离开 Mac 也跟着文件走。
                                   文件里已有说明时不写（不覆盖、不追加）
              --allow-cmyk         CMYK 的 JPEG 也转。默认跳过：HEIF 只能存 RGB，转了颜色会变
                                   （校验照样报出色彩模型和色彩描述文件的变化，不删源）
              --no-quality-check   转完不核对画质。默认核对：产物交出之前与源比 PSNR 和最差 1% 的
                                   局部 SSIM，任一项低于门槛就算画质下降明显
              --min-ssim <0-1>     局部 SSIM 的门槛，默认 \(thresholdText(ConversionOptions.default.qualityThresholds.minSSIM, minimumFraction: 2))（16×16 小块亮度的结构相似度，
                                   取最差的那 1% 的块；1 是完全相同）
              --min-psnr <dB>      PSNR 的门槛，默认 \(thresholdText(ConversionOptions.default.qualityThresholds.minPSNR, minimumFraction: 0))（0–100，越高越接近原图）
              --on-quality-drop <skip|retry>
                                   画质不达标时：skip 不转、保留原 JPEG（默认）；retry 用质量 \(thresholdText(qualityRetryLevel, minimumFraction: 1))
                                   重编一次再判，仍不达标才不转。不转的不算失败
          -n, --dry-run            只打印将要做什么，不实际写文件
          -j, --jobs <n>           并发任务数，默认 \(ConversionOptions.default.jobs)
          -v, --verbose            输出每张图保留的元数据条目数，以及 EXIF 整块照搬了没有；
                                   产物比原图大而重编过一次的，再说明两次的大小；
                                   核对了画质的，再给出 PSNR 和局部 SSIM；
                                   开了 --embed-caption 的，再说明说明写了没有
          -h, --help               显示本帮助

        示例:
          jpeg2heif photo.jpg                          转单张
          jpeg2heif ~/Pictures/2024                    转该文件夹顶层的所有 JPEG
          jpeg2heif -r ~/Pictures/2024 -o ~/输出       递归整个文件夹，输出到别处
          jpeg2heif --verify --delete-original -r ./相册   校验无损后替换源文件
        """
    case .raw2heif:
        return """
        用法: raw2heif [选项] <文件或目录> ...

        把相机 RAW（CR3、CR2、NEF、ARW、RAF、RW2、ORF、DNG 等）按系统默认的显影转换成
        10 位 HEIF(.heic)，同时保留 EXIF（拍摄时间/相机参数）、GPS（拍摄位置）、XMP
        以及文件时间戳、访达备注与标签。RAW 原片永远保留，不提供删除。JPEG 用 jpeg2heif。

        选项:
          -q, --quality <0.0-1.0>  有损压缩质量，默认 \(qualityText(ConversionOptions.default.quality))，上限 \(qualityText(qualityCeiling))（越高越清晰、文件越大）。
                                   高于 \(qualityText(qualityCeiling)) 时按 \(qualityText(qualityCeiling)) 转并提示一次：再高编码器改用 4:4:4，
                                   文件翻倍、画质反降
          -o, --output <路径>       输出目录；单个输入时也可以是产物的文件名（以 .heic 或 .heif 结尾）。
                                   默认输出到源文件同一目录
          -r, --recursive          递归处理目录中的所有 RAW
          -f, --overwrite          覆盖已存在的输出文件。RAW 与同名 JPEG 放在一起时，
                                   两个命令都输出同一个 .heic，后转的那个因「输出已存在」跳过
              --verify             转换后逐条比对元数据，报告任何丢失或变化的条目
              --no-raw-exif        EXIF 交给系统重写，不整块照搬从 RAW 里取出的 EXIF
              --embed-caption      把「照片」App 的说明（文件扩展属性里的那段）写进 HEIF 的
                                   XMP 说明字段 dc:description，让它离开 Mac 也跟着文件走。
                                   文件里已有说明时不写（不覆盖、不追加）
          -n, --dry-run            只打印将要做什么，不实际写文件
          -j, --jobs <n>           并发任务数，默认 \(ConversionOptions.defaultRAWJobs)（RAW 显影吃内存，比核数保守）
          -v, --verbose            输出每张图保留的元数据条目数，以及 EXIF 整块照搬了没有；
                                   开了 --embed-caption 的，再说明说明写了没有
          -h, --help               显示本帮助

        示例:
          raw2heif IMG_0001.CR3                    转单张
          raw2heif ~/Pictures/RAW                  转该文件夹顶层的所有 RAW
          raw2heif -r ~/Pictures/RAW -o ~/输出     递归整个文件夹，输出到别处
          raw2heif --verify IMG_0001.CR3           转完逐条核对元数据
        """
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("错误: \(msg)\n".utf8))
    exit(2)
}

func warn(_ msg: String) {
    FileHandle.standardError.write(Data("警告: \(msg)\n".utf8))
}

// MARK: - 被打断时清理

/// 信号源要一直留着，否则被释放就不再响应。
private var interruptSources: [DispatchSourceSignal] = []

/// 谁来让进程退出：信号处理（打断）和主流程（一批转完）只能有一个。信号处理一进来就拿走、不再放回
/// （它最后 exit）；主流程在一批转完、打印汇总之前拿。
///
/// 没有这把锁时两边抢着 exit：打断后信号处理要等正在写的那几张收手（最多 3 秒），这期间主流程手里
/// 剩下的源一登记临时文件就失败、不计进汇总，很快转完，按「没有失败」用 0 退出——比信号处理先退，
/// 「已中断」没说，退出码是 0，脚本以为成功了。实测 300 张、8 路并发，kill 之后一半是这样。
private let exitLock = NSLock()

/// Ctrl-C（SIGINT）、kill（SIGTERM）、关掉终端（SIGHUP）时：删掉还没写完的临时产物
/// （输出目录里以点开头、看不见的 `.glint-*.heic`），说一句，再按惯例的退出码（128 + 信号）退出。
/// 已经转完的那些照常（产物在，开了删源的、合乎条件的源已删）；没转完的源文件没有动——删源只在
/// 一张转完、校验通过之后。
/// 启动时就被忽略的信号照旧忽略：nohup 会忽略 SIGHUP，后台作业会忽略 SIGINT。
func installInterruptCleanup() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        let previous = signal(sig, SIG_IGN)
        // 函数指针不能直接比，比地址（SIG_IGN 是一个固定的哨兵值）。
        guard unsafeBitCast(previous, to: Int.self) != unsafeBitCast(SIG_IGN, to: Int.self) else { continue }
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            exitLock.lock()   // 主流程已经拿走：一批已经转完，它会照常退出，这边就等着
            let removed = removeInFlightTemporaries()
            let note = removed > 0 ? "，删掉了 \(removed) 个没写完的临时文件" : ""
            FileHandle.standardError.write(Data("\n已中断\(note)；已经转完的照常保留，没转完的源文件没有动\n".utf8))
            exit(128 + sig)
        }
        source.resume()
        interruptSources.append(source)
    }
}

// MARK: - 主流程

func runCommandLine(_ command: Command) -> Never {
    var opts: ConversionOptions
    do {
        switch try parseArguments(Array(CommandLine.arguments.dropFirst()), command: command) {
        case .run(let parsed):
            opts = parsed
        case .showUsage(let code):
            print(usage(for: command))
            exit(code)
        }
    } catch {
        fail(error.localizedDescription)
    }
    // 高于上限的质量按上限转，整批说一次（convert 自己也按上限编，这里是让用户知道）。
    if opts.quality > qualityCeiling {
        warn(qualityCeilingNotice)
        opts.quality = qualityCeiling
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
    installInterruptCleanup()

    let renameNotices = runConversions(files, opts: opts, plan: plan) { job, result in
        // 被打断以后还在收手的那几张不逐张报（多半是「已中断」），收尾的那句话会说清楚。
        guard !conversionsInterrupted else { return }
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
                if let rawExif = r.rawExif { print("    \(rawExif.description)") }
                if let reencode = r.reencode { print("    \(reencode.description)") }
                if let quality = r.quality { print("    \(quality.description)") }
                if let caption = r.caption { print("    \(caption.description)") }
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
            let hint = why == cmykSkipReason ? "（用 --allow-cmyk 强制转换）" : ""
            print("跳过 \(input.lastPathComponent): \(why)\(hint)")
        case .failed(let why):
            FileHandle.standardError.write(Data("失败 \(input.lastPathComponent): \(why)\n".utf8))
        case .qualityDropped(let drop):
            print("\(input.lastPathComponent)  \(drop.description)")
        }
    }

    // 打断了的话信号处理已经拿着锁，在等正在写的收手，这里停住，由它说「已中断」、按 128 + 信号退出。
    exitLock.lock()

    for notice in renameNotices { warn(notice) }

    if files.count > 1 || opts.verifyEnabled {
        print("---")
        print(tally.summary(unit: "个"))
    }

    exit(tally.failed > 0 ? 1 : 0)
}
