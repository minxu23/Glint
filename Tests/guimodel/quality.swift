// 界面模型：画质核对的设置（默认值、记住与读回、门槛填错）、结果分类与文案、真转一张不达标的图。

@testable import Eclose
import Foundation

func runQualityTests(work: URL) {
    print("画质核对：设置的默认值、记住与读回")
    let store = MemoryStore()
    let fresh = PanelSettings.load(from: store)
    let o = ConversionOptions.default
    check("默认值取自 ConversionOptions.default：开着核对", fresh.qualityCheck, o.qualityCheck)
    check("默认开着核对", fresh.qualityCheck, true)
    check("默认门槛取自 ConversionOptions.default", fresh.qualityThresholds, o.qualityThresholds)
    check("默认不达标就不转", fresh.onQualityDrop, .skip)
    check("门槛输入框一开始的文字", [fresh.ssimText, fresh.psnrText], ["0.90", "33"])
    var s = fresh
    s.qualityCheck = false
    s.qualityThresholds = QualityThresholds(minSSIM: 0.85, minPSNR: 30.5)
    s.onQualityDrop = .retry
    s.save(to: store)
    let back = PanelSettings.load(from: store)
    check("关掉核对记住了", back.qualityCheck, false)
    check("门槛记住了", back.qualityThresholds, QualityThresholds(minSSIM: 0.85, minPSNR: 30.5))
    check("不达标时的处理记住了", back.onQualityDrop, .retry)
    check("读回的门槛照样显示", [back.ssimText, back.psnrText], ["0.85", "30.5"])
    let odd = MemoryStore(["panel.minSSIM": 3.0, "panel.minPSNR": -1.0, "panel.onQualityDrop": "以后删掉的处理方式"])
    let oddBack = PanelSettings.load(from: odd)
    check("存的门槛越界、处理方式不认识：用默认的", [oddBack.qualityThresholds == o.qualityThresholds, oddBack.onQualityDrop == .skip],
          [true, true])
    var opts = ConversionOptions.default
    back.apply(to: &opts)
    check("落到 ConversionOptions 上", [opts.qualityCheck == false, opts.qualityThresholds == back.qualityThresholds,
                                        opts.onQualityDrop == .retry], [true, true, true])

    print("画质核对：门槛填错")
    var input = PanelSettings.defaults
    check("合法的输入：没有说明，写进设置", input.takeThresholdInput(ssim: "0.95", psnr: " 40 "), nil)
    check("合法的输入：门槛换成了新值", input.qualityThresholds, QualityThresholds(minSSIM: 0.95, minPSNR: 40))
    let problem = input.takeThresholdInput(ssim: "1.5", psnr: "40")
    check("局部相似度越界：说明", problem, "局部相似度要填 0 到 1 之间的数")
    check("填错的那个保持原值", input.qualityThresholds.minSSIM, 0.95)
    check("填错时不让开始转换", input.blocksStart(thresholdProblem: problem), true)
    check("两个都填错：两句都说", input.takeThresholdInput(ssim: "", psnr: "高"),
          "局部相似度要填 0 到 1 之间的数，PSNR 要填 0 到 100 之间的数")
    input.qualityCheck = false
    check("没勾核对时门槛用不上，不拦", input.blocksStart(thresholdProblem: problem), false)
    input.qualityCheck = true
    check("都填对了就能开始", input.blocksStart(thresholdProblem: input.takeThresholdInput(ssim: "0.9", psnr: "33")), false)

    print("画质核对：结果分类与文案")
    let gate = QualityThresholds(minSSIM: 0.90, minPSNR: 33)
    let low = QualityReading.measured(QualityMeasurement(psnr: 31.25, worstSSIM: 0.8625))
    let drop = QualityDrop(first: low, firstQuality: 0.8, thresholds: gate, retry: nil)
    let retried = QualityDrop(first: low, firstQuality: 0.8, thresholds: gate,
                              retry: .stillBelow(.measured(QualityMeasurement(psnr: 32.5, worstSSIM: 0.95))))
    let mb = 1024 * 1024
    var passedRow = row("ok.jpg", .done, inBytes: 4 * mb, outBytes: mb, verification: .passed, dest: "/库/ok.heic")
    passedRow.quality = .passed(QualityMeasurement(psnr: 43.56, worstSSIM: 0.9791))
    let rows = [passedRow, row("差.jpg", .qualityDropped(drop)), row("差2.jpg", .qualityDropped(retried)),
                row("fail.jpg", .failed("无法读取图像"))]
    check("画质不达标算有结局", RowStatus.qualityDropped(drop).isSettled, true)
    check("副标题就是那一行说明", rows[1].detailText,
          "画质下降明显（PSNR 31.2 dB，局部 SSIM 0.862，门槛 0.90 / 33 dB），没有转换，保留原 JPEG")
    check("标记与失败、跳过分开", ConversionRecord.mark(of: rows[1]), .qualityDropped)
    check("网格上标出来", ConversionMark.qualityDropped.showsOnGrid, true)
    check("列表「转换」列", ConversionMark.qualityDropped.listText, "画质不够")
    check("信息栏的结论标题", verdictTitle(.qualityDropped), "画质不达标，没有转换")
    check("无障碍描述", ConversionMark.qualityDropped.spokenText, "画质不达标，没有转换")
    check("信息栏里的两个数和门槛", qualityDropLines(drop).map { "\($0.0)=\($0.1)" },
          ["质量 0.8=PSNR 31.2 dB\n局部 SSIM 0.862", "门槛=局部 SSIM 不低于 0.90\nPSNR 不低于 33 dB", "源文件=还在，没有产物"])
    check("重编过的：两遍的数都列出来", qualityDropLines(retried).map(\.0), ["质量 0.8", "质量 0.95", "门槛", "源文件"])
    check("转成了的：信息栏「画质」一行", qualityLine(passedRow.quality), "PSNR 43.5 dB\n局部 SSIM 0.979")
    check("重编后转成的：说出第一遍的质量",
          qualityLine(.passedAfterRetry(first: low, firstQuality: 0.8, retried: QualityMeasurement(psnr: 45, worstSSIM: 0.97))),
          "PSNR 45.0 dB\n局部 SSIM 0.970\n质量 0.8 不达标（PSNR 31.2 dB，局部 SSIM 0.862），改用 0.95 重编")
    check("没核对的没有「画质」一行", qualityLine(nil), nil)
    var rec = ConversionRecord(rows: rows)
    let t = rec.tally
    check("计数：转成 1、画质不达标 2、失败 1", [t.converted, t.qualityDropped, t.failed, t.skipped], [1, 2, 1, 0])
    check("各类张数的行", rec.classLines, ["无差异 1 张", "失败 1 张", "画质不达标、没有转换 2 张"])
    check("活动条算上它们", rec.activityText, "转完 1 张，省下 3.0 MB。2 张画质不达标没有转换，1 张失败。")
    rec.deleteRequested = true
    check("开了删除：说源文件都还在", rec.activityText, "转完 1 张，省下 3.0 MB。2 张画质不达标没有转换，1 张失败，它们的源文件都还在。")
    check("没有产物的显示源文件", rec.displayedPaths(.all).map { ($0 as NSString).lastPathComponent },
          ["ok.heic", "差.jpg", "差2.jpg", "fail.jpg"])
    check("不算失败", rec.count(.failures), 1)
    check("源没删", rows.map { rec.sourceDeleted($0) }, [false, false, false, false])
    check("全都画质不达标", ConversionRecord(rows: [rows[1]]).activityText, "一张都没转成。1 张画质不达标没有转换。")

    print("画质核对：真转一张不达标的图")
    // 相机样本按质量 0.4 转，局部 SSIM 约 0.65：不达标。勾着删除，源也得在。
    let sources = files(in: work, ext: "jpg")
    guard sources.count == 1 else {
        fail("「画质」目录里应当恰好有一张相机样本（实际 \(sources.count) 张）")
        return
    }
    let m = ConversionModel()
    m.updateOptions { $0.quality = 0.4; $0.deleteOriginal = true }
    m.add(urls: sources)
    m.start()
    check(wait(until: { !m.isRunning }), "不达标的那一张走完了流程")
    if case .qualityDropped(let d)? = m.rows.first?.status {
        check(d.first.measurement.map { !gate.accepts($0) } == true, "行的状态是画质不达标（\(d.description)）")
    } else {
        fail("行的状态不是画质不达标（\(String(describing: m.rows.first?.status))）")
    }
    check("没有产物", fm.fileExists(atPath: sources[0].deletingPathExtension().appendingPathExtension("heic").path), false)
    check("源还在", fm.fileExists(atPath: sources[0].path), true)
    check(m.summary.contains("1 张画质不达标，保留原 JPEG"), "汇总单列画质不达标（\(m.summary)）")
}
