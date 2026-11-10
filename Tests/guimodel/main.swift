// 界面模型层的集成测试：用真实文件跑真实转换。
//
// 不走 uisnapshot 驱动窗口，是因为「输出到指定文件夹」要经过 NSOpenPanel，
// 模态面板没法自动化；而 ConversionModel 只依赖 Foundation，把它直接驱动起来
// 覆盖的是同一套逻辑（start 里怎么拼 ConversionOptions、怎么调度、取消后怎么收尾），
// 又不必往生产代码里塞测试钩子。
//
// 用法: guimodel <工作目录>   目录里需要已有若干 .jpg

import Foundation


guard let work = CommandLine.arguments.dropFirst().first.map({ URL(fileURLWithPath: $0) }) else {
    FileHandle.standardError.write(Data("用法: guimodel <工作目录>\n".utf8))
    exit(2)
}
let fm = FileManager.default

/// 目录里扩展名匹配的文件。`deep` 为真时连子目录一起找。
/// 原先这里是三个只差一个字面量（jpg/heic）和一处深浅的函数。
func files(in dir: URL, ext: String, deep: Bool = false) -> [URL] {
    let all: [URL] = deep
        ? (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?
             .compactMap { $0 as? URL }) ?? []
        : (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.pathExtension.lowercased() == ext }.sorted { $0.path < $1.path }
}
/// 模型的回调走 DispatchQueue.main，必须把主 runloop 转起来才等得到结果。
func wait(until done: () -> Bool, timeout: TimeInterval = 60) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return done()
}
/// 转换中断时留下的半成品临时文件。
func temporaryLeftovers(in dir: URL) -> [URL] {
    ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix(".jpeg2heif-") }
}

func runningCount(_ m: ConversionModel) -> Int {
    m.rows.filter { if case .running = $0.status { return true }; return false }.count
}
func statusCounts(_ m: ConversionModel) -> (done: Int, pending: Int, other: Int) {
    var d = 0, p = 0, o = 0
    for r in m.rows {
        switch r.status {
        case .done: d += 1
        case .pending: p += 1
        default: o += 1
        }
    }
    return (d, p, o)
}

// MARK: - 1. 输出到指定文件夹

print("界面模型：输出到指定文件夹")
let srcDir = work.appendingPathComponent("源")
let outDir = work.appendingPathComponent("指定输出")
let sources = files(in: srcDir, ext: "jpg")
guard sources.count >= 2 else { fail("工作目录里的测试图不够（\(sources.count) 张）"); exit(1) }

let m1 = ConversionModel()
m1.outputMode = .chosenFolder
m1.outputFolder = outDir
m1.add(urls: sources)
check(m1.rows.count == sources.count, "拖入的文件都进了列表（\(m1.rows.count) 张）")
m1.start()
check(wait(until: { !m1.isRunning }), "转换结束")

let produced = files(in: outDir, ext: "heic", deep: true)
check(produced.count == sources.count, "产物都落在指定文件夹（\(produced.count)/\(sources.count)）")
check(files(in: srcDir, ext: "heic", deep: true).isEmpty, "源文件夹里没有留下产物")
let counts1 = statusCounts(m1)
check(counts1.done == sources.count, "每一行都标记为完成")

// MARK: - 2. 取消

print("界面模型：取消转换")
let cancelDir = work.appendingPathComponent("取消")
let cancelSources = files(in: cancelDir, ext: "jpg")
guard !cancelSources.isEmpty else { fail("取消测试没有素材"); exit(1) }

let m2 = ConversionModel()
m2.add(urls: cancelSources)
m2.start()
check(m2.isRunning, "start() 后立刻处于运行中")
m2.cancel()
check(wait(until: { !m2.isRunning }), "取消后干净停止")

let c2 = statusCounts(m2)

// 关键断言：取消必须真的阻止后续工作。少了这条，即使 cancel() 是空操作、
// 所有文件照转不误，下面那些"状态干净"的检查也照样全过——测试会变成摆设。
// 素材数远多于并发度，调度循环必然还卡在信号量上，所以这条不会偶发失败。
check(c2.done < m2.rows.count,
      "取消确实阻止了后续转换（\(c2.done)/\(m2.rows.count) 张在取消前完成）")

// 以下与「取消时来得及转几张」无关，不会偶发失败。
check(runningCount(m2) == 0, "没有行卡在「转换中」")
check(c2.done + c2.pending + c2.other == m2.rows.count, "每一行都有确定状态，没有丢行")
check(c2.pending > 0, "未完成的行退回待转换，可以再次开始")

check(temporaryLeftovers(in: cancelDir).isEmpty, "没有残留的半成品临时文件")

// 取消后再次开始，剩下的应当能接着转完。
// 顺便在整个过程中持续核对进度计数：completedCount 绝不能把还在转的行算成
// 已完成（界面上那个 "x/y" 就是它）。期望值由 pendingCount 和 runningCount
// 独立算出，不是照着实现抄一遍。
var progressMismatch: String?
var sawRunning = false
m2.start()
let finished = wait(until: {
    let inFlight = runningCount(m2)
    if inFlight > 0 { sawRunning = true }
    let settled = m2.rows.count - m2.pendingCount - inFlight
    if m2.completedCount != settled {
        progressMismatch = "进度显示 \(m2.completedCount)，实际已结束 \(settled)"
    }
    return !m2.isRunning
})
check(finished, "取消后可以继续")
check(progressMismatch == nil, "进度计数不把「转换中」算成已完成（\(progressMismatch ?? "全程吻合")）")
// 没抓到任何「转换中」的瞬间，上面那条就是空断言，必须说出来而不是静默通过。
check(sawRunning, "过程中确实观察到了「转换中」的行（否则上一条断言无效）")
check(statusCounts(m2).done == m2.rows.count, "续跑后全部完成（\(m2.rows.count) 张）")

// MARK: - 3. 转到一半再取消

// 上面那一轮里取消总在任何转换开始之前就落地，于是「没有行卡在转换中」是空断言。
// 这一轮先让它跑起来，再取消，才真正走到「正在转的那几行要退回待转换」那条路径。
// 只断言不变式，不断言"取消时完成了几张"——那个数字依机器快慢而变，会偶发失败。
print("界面模型：转到一半再取消")
let midDir = work.appendingPathComponent("中途取消")
let midSources = files(in: midDir, ext: "jpg")
if midSources.isEmpty {
    fail("中途取消测试没有素材")
} else {
    let m3 = ConversionModel()
    m3.add(urls: midSources)
    m3.start()
    _ = wait(until: { statusCounts(m3).done > 0 }, timeout: 5)   // 先转起来
    m3.cancel()
    check(wait(until: { !m3.isRunning }), "运行中途取消后干净停止")
    check(runningCount(m3) == 0, "正在转的行已退回待转换，没有卡住")
    let c3 = statusCounts(m3)
    check(c3.done + c3.pending + c3.other == m3.rows.count, "每一行都有确定状态")
    check(temporaryLeftovers(in: midDir).isEmpty, "中途取消也没有残留临时文件")
    m3.start()
    check(wait(until: { !m3.isRunning }), "中途取消后同样可以继续")
    check(statusCounts(m3).done == m3.rows.count, "续跑后全部完成")
}

// MARK: - 4. 设置项只有一个写入口

// 每个开关原先各有一个只做转发的读写属性，recursive 那个还额外要重扫输入。
// 现在统一走 updateOptions，这一组守两件事：值真的写进去了，
// 以及 recursive 变化确实触发了重扫（不触发的话勾上"递归子文件夹"毫无反应）。
print("界面模型：设置项与递归重扫")
let recursiveDir = work.appendingPathComponent("递归")
let shallowCount = files(in: recursiveDir, ext: "jpg").count
let deepCount = files(in: recursiveDir, ext: "jpg", deep: true).count
if shallowCount == 0 || deepCount <= shallowCount {
    fail("递归测试的素材不对（顶层 \(shallowCount) 张，全部 \(deepCount) 张，必须后者更多）")
} else {
    let m4 = ConversionModel()
    m4.add(urls: [recursiveDir])
    check("默认不递归，只收顶层", m4.rows.count, shallowCount)
    m4.updateOptions { $0.recursive = true }
    check("勾上递归后子目录里的也进来了", m4.rows.count, deepCount)
    m4.updateOptions { $0.recursive = false }
    check("取消勾选后退回顶层", m4.rows.count, shallowCount)
    // 非 recursive 的字段也必须真的写进去——只处理 recursive 的 updateOptions
    // 会让质量滑块、覆盖开关统统失效，而上面三条照样全过。
    m4.updateOptions { $0.quality = 0.95 }
    check("改质量同样写进了 options", m4.options.quality, 0.95)
    check("改质量不动文件列表", m4.rows.count, shallowCount)
}

// MARK: - 5. 跳过的原因

// 跳过/失败的原因现在挂在状态上（RowStatus.skipped(String)），不再和
// "转换成功但有话要说" 挤在同一个 note 字段里。这一组确认原因真的传到了
// 列表行的副标题——不然界面上只会出现一个没有任何说明的灰圈。
print("界面模型：跳过的原因")
let disguiseDir = work.appendingPathComponent("伪装")
try? fm.createDirectory(at: disguiseDir, withIntermediateDirectories: true)
let disguised = disguiseDir.appendingPathComponent("其实是heic.jpg")
try? fm.removeItem(at: disguised)
if let anyHeic = produced.first, (try? fm.copyItem(at: anyHeic, to: disguised)) != nil {
    let m5 = ConversionModel()
    m5.add(urls: [disguised])
    m5.start()
    check(wait(until: { !m5.isRunning }), "伪装文件也走完了流程")
    check("扩展名是 jpg 但内容不是，应当跳过",
          m5.rows.first?.status, .skipped("不是 JPEG 文件"))
    check(m5.rows.first?.detailText.contains("不是 JPEG 文件") == true,
          "跳过的原因显示在副标题里")
    check(files(in: disguiseDir, ext: "heic", deep: true).isEmpty, "跳过的文件没有产出任何东西")
} else {
    fail("造不出伪装成 .jpg 的非 JPEG 文件")
}

// MARK: - 6. 改设置必须通知视图

// 本文件开头的 Model.swift 写着「状态变化统一通过 onChange 回调通知视图刷新」。
// 被 updateOptions 替换掉的那四个转发属性其实不通知，界面是靠
// MainViewController 两处手工 refresh() 补的。收成一个入口之后这件事得由模型
// 自己保证，否则对未来任何调用方都是静默失效——而那种失效没有任何征兆。
print("界面模型：改设置会通知视图")
let m6 = ConversionModel()
var notices = 0
m6.onChange = { notices += 1 }
m6.updateOptions { $0.quality = 0.9 }
check("改质量通知了一次", notices, 1)
m6.updateOptions { $0.quality = 0.9 }
check("值没变就不通知", notices, 1)
// 先把值读出来再进闭包：在闭包里读 m6.options 会与 updateOptions 持有的
// 独占访问冲突，Swift 运行时直接 abort（实测过，不是理论风险）。
let wasRecursive = m6.options.recursive
m6.updateOptions { $0.recursive = !wasRecursive }
check("递归开关也只通知一次（reexpand 自己会通知）", notices, 2)
// inputs/output 不由 updateOptions 管，改了不作数，也不该留在 options 里。
m6.updateOptions {
    $0.output = URL(fileURLWithPath: "/tmp/不该生效")
    $0.inputs = ["/tmp/也不该生效.jpg"]
}
check("output 改不动", m6.options.output, nil)
check("inputs 改不动", m6.options.inputs, [])
check("改不动的字段不算变化，所以也不通知", notices, 2)

// MARK: - 7. 没校验不等于校验通过

// 关掉"转换后校验元数据"时，一张必然丢数据的图（--lossy 夹具）也不能显示
// 「校验无差异」。第一条是对照：开着校验、无损的图确实会显示这几个字，
// 否则后一条"不含"在文案改掉时也成立。
print("界面模型：没校验就不说「校验无差异」")
check(m1.rows.first?.detailText.contains("校验无差异") == true,
      "开着校验、无损的图显示「校验无差异」（对照）")
let unverified = files(in: work.appendingPathComponent("未校验"), ext: "jpg")
if unverified.count == 1 {
    let m7 = ConversionModel()
    m7.updateOptions { $0.verify = false }
    m7.add(urls: unverified)
    m7.start()
    check(wait(until: { !m7.isRunning }), "关掉校验的那一批走完了流程")
    check("关掉校验时结果是「未校验」", m7.rows.first?.verification, .notVerified)
    check(m7.rows.first?.detailText.contains("校验无差异") == false,
          "关掉校验时副标题不说「校验无差异」")
} else {
    fail("「未校验」目录里应当恰好有一张 --lossy 夹具（实际 \(unverified.count) 张）")
}

finish("界面模型测试")
