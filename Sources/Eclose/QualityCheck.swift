// 转完核对画质（只对 JPEG）：产物写进临时文件之后、挪到目标位置之前，源和产物各解码一遍，
// 算 PSNR 与「最差 1% 的局部 SSIM」，两项都不低于门槛才交出产物。流程里怎么用见 convert，
// 判据与门槛的来由见 README「转完核对画质」。

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 门槛与处理方式

/// 画质核对的两个门槛。命令行 --min-ssim / --min-psnr 与界面「高级」里的两个输入框都落到这里，
/// 取值的合法范围与解析也只在这里定义。
public struct QualityThresholds: Equatable {
    /// 最差 1% 局部 SSIM 的下限。
    public var minSSIM: Double
    /// PSNR 的下限，单位 dB。
    public var minPSNR: Double

    public init(minSSIM: Double, minPSNR: Double) {
        self.minSSIM = minSSIM
        self.minPSNR = minPSNR
    }

    public static let ssimRange: ClosedRange<Double> = 0...1
    public static let psnrRange: ClosedRange<Double> = 0...100

    /// 文本解析成 SSIM 门槛：去掉首尾空白后是 0–1 之间的数字（NaN、无穷不算）；否则 nil。
    public static func parseSSIM(_ text: String) -> Double? { parse(text, in: ssimRange) }
    /// 文本解析成 PSNR 门槛（dB）：0–100 之间的数字；否则 nil。
    public static func parsePSNR(_ text: String) -> Double? { parse(text, in: psnrRange) }

    private static func parse(_ text: String, in range: ClosedRange<Double>) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return nil }
        return v
    }

    /// 达标：局部 SSIM 不低于 minSSIM，且 PSNR 不低于 minPSNR。恰好等于门槛算达标。
    public func accepts(_ m: QualityMeasurement) -> Bool {
        m.worstSSIM >= minSSIM && m.psnr >= minPSNR
    }

    /// `门槛 0.90 / 33 dB`。
    public var description: String {
        "门槛 \(thresholdText(minSSIM, minimumFraction: 2)) / \(thresholdText(minPSNR, minimumFraction: 0)) dB"
    }
}

/// 门槛的写法：至少 `minimumFraction` 位小数，多出来的有效位照写（最多 4 位），末尾的 0 去掉。
/// 0.9 → `0.90`，0.925 → `0.925`，33 → `33`，33.5 → `33.5`。
public func thresholdText(_ value: Double, minimumFraction: Int) -> String {
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0"), let dot = text.firstIndex(of: "."),
          text.distance(from: dot, to: text.endIndex) - 1 > minimumFraction {
        text.removeLast()
    }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

/// 不达标时怎么办。
public enum QualityDropAction: String, CaseIterable {
    /// 不转：删掉产物，保留 JPEG。
    case skip
    /// 用 qualityRetryLevel 重编一次再判，仍不达标才不转。
    case retry
}

/// 「提高质量再试」重编时用的质量。常量，不做成设置；用户设的质量已经不低于它时不重试。
public let qualityRetryLevel = 0.95

// MARK: - 量出来的数

/// 一次核对量出的两个数。
public struct QualityMeasurement: Equatable {
    /// RGB 三通道 8 位的 PSNR（dB）；两边逐像素相同时是 +∞。
    public let psnr: Double
    /// 16×16 不重叠块的亮度 SSIM，升序排好后下标 ⌊块数 / 100⌋ 的那一个。
    public let worstSSIM: Double

    public init(psnr: Double, worstSSIM: Double) {
        self.psnr = psnr
        self.worstSSIM = worstSSIM
    }

    /// `PSNR 43.5 dB，局部 SSIM 0.979`。两个数都向下截断（PSNR 1 位、SSIM 3 位小数），
    /// 不达标的数不会被四舍五入成看上去够门槛的样子。
    public var description: String {
        let p = psnr.isInfinite ? "∞" : String(format: "%.1f", (psnr * 10).rounded(.down) / 10)
        return "PSNR \(p) dB，局部 SSIM \(String(format: "%.3f", (worstSSIM * 1000).rounded(.down) / 1000))"
    }
}

/// 图像的宽高（像素）。
public struct PixelSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)×\(height)" }
}

/// 核对一次的结果：量出了两个数，或者量不了（量不了一律算不达标）。
public enum QualityReading: Equatable {
    case measured(QualityMeasurement)
    /// 两边宽高不同。
    case sizeChanged(source: PixelSize, product: PixelSize)
    /// 有一边解不出像素；附带是哪一边。
    case undecodable(String)

    /// 按门槛判：量出的数两项都达标才算；量不了的不达标。
    public func accepted(by thresholds: QualityThresholds) -> Bool {
        guard case .measured(let m) = self else { return false }
        return thresholds.accepts(m)
    }

    public var description: String {
        switch self {
        case .measured(let m): return m.description
        case let .sizeChanged(source, product): return "尺寸变了（\(source.description) → \(product.description)）"
        case .undecodable(let why): return why
        }
    }
}

// MARK: - 报告里的两种结局

/// 核对通过的产物带着的结果（ConversionReport.quality）。没核对（RAW、预演、关掉了）是 nil。
public enum QualityOutcome: Equatable {
    /// 按用户设的质量编出来就达标。
    case passed(QualityMeasurement)
    /// 用户设的质量 `firstQuality` 不达标（`first`），按 qualityRetryLevel 重编后达标（`retried`）。
    case passedAfterRetry(first: QualityReading, firstQuality: Double, retried: QualityMeasurement)

    /// -v 时显示的那一行（不含缩进）。
    public var description: String {
        switch self {
        case .passed(let m):
            return "画质：\(m.description)"
        case let .passedAfterRetry(first, q, retried):
            return "画质：质量 \(qualityText(q)) 不达标（\(first.description)），用 \(qualityText(qualityRetryLevel)) 重编后 \(retried.description)"
        }
    }

    /// 不带 -v 也要留在状态说明里的那一句：用了比设定更高的质量。只有重编过的有。
    public var note: String? {
        guard case .passedAfterRetry(_, let q, _) = self else { return nil }
        return "质量 \(qualityText(q)) 画质不达标，改用 \(qualityText(qualityRetryLevel)) 重编"
    }
}

/// 画质不达标、没有转换的那一张（ConvertResult.qualityDropped）。源原样留着，没有产物。
public struct QualityDrop: Equatable {
    /// 「提高质量再试」那一步的经过。
    public enum Retry: Equatable {
        /// 用户设的质量已经不低于 qualityRetryLevel，不重试。
        case notNeeded
        /// 重编那一遍编码失败。
        case encodeFailed
        /// 重编了，仍不达标。
        case stillBelow(QualityReading)
    }

    /// 按用户设的质量编出来的那份的核对结果。
    public let first: QualityReading
    /// 第一遍实际编码用的质量：用户设的质量，高于 qualityCeiling 时是 qualityCeiling。
    public let firstQuality: Double
    public let thresholds: QualityThresholds
    /// 处理方式是「不转」时是 nil。
    public let retry: Retry?

    /// 一行说明（不含文件名）：
    /// `画质下降明显（PSNR 31.2 dB，局部 SSIM 0.862，门槛 0.90 / 33 dB），没有转换，保留原 JPEG`，
    /// 重编过的在「没有转换」前加 `用质量 0.95 重编后仍不达标（…）`。
    public var description: String {
        let head = first.measurement != nil ? "画质下降明显" : "画质核对不通过"
        var parts = ["\(head)（\(first.description)，\(thresholds.description)）"]
        switch retry {
        case nil: break
        case .notNeeded?: parts.append("质量已不低于 \(qualityText(qualityRetryLevel))，没有重编")
        case .encodeFailed?: parts.append("用质量 \(qualityText(qualityRetryLevel)) 重编失败")
        case .stillBelow(let again)?:
            parts.append("用质量 \(qualityText(qualityRetryLevel)) 重编后仍不达标（\(again.description)）")
        }
        parts.append("没有转换，保留原 JPEG")
        return parts.joined(separator: "，")
    }
}

extension QualityReading {
    /// 量出的数；量不了是 nil。
    public var measurement: QualityMeasurement? {
        if case .measured(let m) = self { return m }
        return nil
    }
}

/// 质量的写法：0.8 → `0.8`，0.95 → `0.95`。
public func qualityText(_ q: Double) -> String { thresholdText(q, minimumFraction: 1) }

// MARK: - 判据（纯计算）

/// 一幅 8 位 RGB 像素：每像素 4 字节，R、G、B 分别在像素内第 `offsets` 字节，剩下那一字节不看。
/// 每行 `rowBytes` 字节（≥ 4 × 宽）。默认是 RGBX：依次 R、G、B、不用的一字节。
struct RGBPixels {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let rowBytes: Int
    var offsets = (r: 0, g: 1, b: 2)

    /// 第 `y` 行起、`rows` 行的那一段。
    func rows(_ y: Int, _ rows: Int) -> RGBPixels {
        RGBPixels(base: base + y * rowBytes, width: width, height: rows, rowBytes: rowBytes, offsets: offsets)
    }
}

/// 局部 SSIM 的块边长。
let ssimBlockSide = 16

/// 两幅同样宽高的像素的 PSNR 与最差 1% 局部 SSIM。
///
/// - PSNR：RGB 三通道 8 位的均方误差 MSE，`10·log10(255² / MSE)`；MSE 为 0 时 +∞。
/// - 局部 SSIM：亮度 `Y = 0.299R + 0.587G + 0.114B`；从左上角起切成不重叠的 16×16 块，右边、
///   下边凑不满 16 的部分不算；宽或高不到 16 时整张图当一块。每块
///   `((2μaμb + C1)(2σab + C2)) / ((μa² + μb² + C1)(σa² + σb² + C2))`，`C1 = (0.01·255)²`、
///   `C2 = (0.03·255)²`，方差、协方差用 n−1（块里只有 1 个像素时取 0）。所有块升序排好，取下标
///   ⌊块数 / 100⌋ 的那一个。
func qualityMeasurement(_ a: RGBPixels, _ b: RGBPixels) -> QualityMeasurement {
    precondition(a.width == b.width && a.height == b.height, "两幅像素宽高不同")
    let tally = QualityTally(width: a.width, height: a.height)
    tally.add(a, b)
    return tally.result()
}

/// 按条带累计 qualityMeasurement 的两个数：两幅图从上往下一条一条喂进来（add），全部喂完取 result。
/// 每条带的行数除最后一条外都得是 16 的倍数（块不跨条带）；整张图当一块时（宽或高不到 16）只能一次喂完。
///
/// 块里的像素一次读 16 个（一行 64 字节），用 SIMD 一遍算完平方误差与五个和（Σa、Σb、Σa²、Σb²、Σab）：
/// 平方误差是整数，精确；亮度先减 128 再累加（Float，每条 SIMD 通道只累加一列的 16 个数），块的五个和
/// 换成 Double 再算 SSIM。块以外的像素（右边、下边凑不满 16 的）只进平方误差，逐个算。除了喂进来的那一条，只多占每块一个数。
final class QualityTally {
    let width: Int
    let height: Int
    /// 宽或高不到 16：整张图当一块。
    private let wholeImage: Bool
    private let blocksAcross: Int
    /// 落在块里的行数（16 的倍数）。
    private let blockRows: Int
    /// 已经喂进来的行数。
    private(set) var rowsSeen = 0
    /// 平方误差的和（整数）。
    private var squaredError: UInt64 = 0
    private var ssims: [Double] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        wholeImage = width < ssimBlockSide || height < ssimBlockSide
        blocksAcross = wholeImage ? 0 : width / ssimBlockSide
        blockRows = wholeImage ? 0 : height / ssimBlockSide * ssimBlockSide
        ssims.reserveCapacity(wholeImage ? 1 : blocksAcross * (height / ssimBlockSide))
    }

    /// 接着喂一条：`a`、`b` 宽与整幅相同、行数相同，是第 rowsSeen 行起的那一段。
    func add(_ a: RGBPixels, _ b: RGBPixels) {
        precondition(a.width == width && b.width == width && a.height == b.height, "条带的宽高不对")
        precondition(rowsSeen + a.height <= height, "喂进来的行数超过了整幅")
        precondition(wholeImage ? a.height == height : (rowsSeen + a.height == height || a.height % ssimBlockSide == 0),
                     "条带行数不对")
        // 这一条里落在块里的行（16 的倍数，rowsSeen 也是 16 的倍数）。
        let inBlocks = max(0, min(a.height, blockRows - rowsSeen))
        var y = 0
        while y < inBlocks {
            addBlockRow(a.rows(y, ssimBlockSide), b.rows(y, ssimBlockSide))
            y += ssimBlockSide
        }
        // 块以外的像素只进平方误差。
        let blockColumns = blocksAcross * ssimBlockSide
        for r in 0..<a.height {
            let from = r < inBlocks ? blockColumns : 0
            if from < width { squaredError += rowSquaredError(a.rows(r, 1), b.rows(r, 1), from: from) }
        }
        if wholeImage { ssims.append(wholeImageSSIM(a, b)) }
        rowsSeen += a.height
    }

    /// 一行 16 行高的块：每块的平方误差与 SSIM。
    private func addBlockRow(_ a: RGBPixels, _ b: RGBPixels) {
        let shiftsA = channelShifts(a), shiftsB = channelShifts(b)
        let wr: Float = 0.299, wg: Float = 0.587, wb: Float = 0.114
        let rowsA = (0..<ssimBlockSide).map { UnsafeRawPointer(a.base + $0 * a.rowBytes) }
        let rowsB = (0..<ssimBlockSide).map { UnsafeRawPointer(b.base + $0 * b.rowBytes) }
        for j in 0..<blocksAcross {
            var sa = SIMD16<Float>(), sb = sa, saa = sa, sbb = sa, sab = sa
            var err = SIMD16<Int32>()
            let offset = j * ssimBlockSide * 4
            for r in 0..<ssimBlockSide {
                let pa = rowsA[r].loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt32>.self)
                let pb = rowsB[r].loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt32>.self)
                let ra = channel(pa, shiftsA.r), ga = channel(pa, shiftsA.g), ba = channel(pa, shiftsA.b)
                let rb = channel(pb, shiftsB.r), gb = channel(pb, shiftsB.g), bb = channel(pb, shiftsB.b)
                let dr = ra &- rb, dg = ga &- gb, db = ba &- bb
                err &+= dr &* dr &+ dg &* dg &+ db &* db
                let ya = wr * SIMD16<Float>(ra) + wg * SIMD16<Float>(ga) + wb * SIMD16<Float>(ba) - 128
                let yb = wr * SIMD16<Float>(rb) + wg * SIMD16<Float>(gb) + wb * SIMD16<Float>(bb) - 128
                sa += ya
                sb += yb
                saa += ya * ya
                sbb += yb * yb
                sab += ya * yb
            }
            squaredError += UInt64(err.wrappedSum())
            let n = ssimBlockSide * ssimBlockSide
            let ma = laneSum(sa), mb = laneSum(sb)
            // 亮度减过 128：方差、协方差不受影响；均值加回 128。
            ssims.append(blockSSIM(n: n, sa: ma + 128 * Double(n), sb: mb + 128 * Double(n),
                                   centeredA: ma, centeredB: mb, saa: laneSum(saa), sbb: laneSum(sbb), sab: laneSum(sab)))
        }
    }

    /// 整张图当一块时的 SSIM（宽或高不到 16，像素不多，逐个算）。
    private func wholeImageSSIM(_ a: RGBPixels, _ b: RGBPixels) -> Double {
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        for r in 0..<height {
            for x in 0..<width {
                let ya = luma(a, x, r) - 128, yb = luma(b, x, r) - 128
                sa += ya; sb += yb; saa += ya * ya; sbb += yb * yb; sab += ya * yb
            }
        }
        let n = width * height
        return blockSSIM(n: n, sa: sa + 128 * Double(n), sb: sb + 128 * Double(n),
                         centeredA: sa, centeredB: sb, saa: saa, sbb: sbb, sab: sab)
    }

    /// 两个数。要在全部行喂完之后取。
    func result() -> QualityMeasurement {
        precondition(rowsSeen == height, "还有行没喂进来")
        guard width > 0, height > 0 else { return QualityMeasurement(psnr: .infinity, worstSSIM: 1) }
        let mse = Double(squaredError) / Double(3 * width * height)
        let psnr = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
        var sorted = ssims
        vDSP_vsortD(&sorted, vDSP_Length(sorted.count), 1)
        return QualityMeasurement(psnr: psnr, worstSSIM: sorted[sorted.count / 100])
    }
}

/// 一个像素按小端读成 UInt32 时 R、G、B 各在哪几位。
private func channelShifts(_ p: RGBPixels) -> (r: UInt32, g: UInt32, b: UInt32) {
    (UInt32(p.offsets.r * 8), UInt32(p.offsets.g * 8), UInt32(p.offsets.b * 8))
}

private func channel(_ pixels: SIMD16<UInt32>, _ shift: UInt32) -> SIMD16<Int32> {
    SIMD16<Int32>(truncatingIfNeeded: (pixels &>> shift) & 0xFF)
}

/// 16 个 Float 换成 Double 再加。
private func laneSum(_ v: SIMD16<Float>) -> Double {
    var s = 0.0
    for i in 0..<16 { s += Double(v[i]) }
    return s
}

/// 一行里从第 `from` 列起的平方误差（整数）。
private func rowSquaredError(_ a: RGBPixels, _ b: RGBPixels, from: Int) -> UInt64 {
    var sum: UInt64 = 0
    for x in from..<a.width {
        let pa = a.base + x * 4, pb = b.base + x * 4
        for (oa, ob) in [(a.offsets.r, b.offsets.r), (a.offsets.g, b.offsets.g), (a.offsets.b, b.offsets.b)] {
            let d = Int(pa[oa]) - Int(pb[ob])
            sum += UInt64(d * d)
        }
    }
    return sum
}

/// 第 `y` 行第 `x` 个像素的亮度 Y = 0.299R + 0.587G + 0.114B（Double，整张图当一块时用）。
private func luma(_ p: RGBPixels, _ x: Int, _ y: Int) -> Double {
    let px = p.base + y * p.rowBytes + x * 4
    return 0.299 * Double(px[p.offsets.r]) + 0.587 * Double(px[p.offsets.g]) + 0.114 * Double(px[p.offsets.b])
}

/// 一块的 SSIM。`sa`、`sb` 是块里 n 个亮度值的和；`centeredA`、`centeredB`、`saa`、`sbb`、`sab` 是同一批值
/// 都减去同一个常数以后的 Σa、Σb、Σa²、Σb²、Σab（减常数不改方差、协方差，只让累加的数小、误差小）。
/// 不减时 centeredA = sa、centeredB = sb。
func blockSSIM(n: Int, sa: Double, sb: Double, centeredA: Double, centeredB: Double,
               saa: Double, sbb: Double, sab: Double) -> Double {
    let c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255)
    let count = Double(n)
    let ma = sa / count, mb = sb / count
    let dof = count - 1
    let va = n > 1 ? max(0, (saa - centeredA * centeredA / count) / dof) : 0
    let vb = n > 1 ? max(0, (sbb - centeredB * centeredB / count) / dof) : 0
    let cov = n > 1 ? (sab - centeredA * centeredB / count) / dof : 0
    return ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
}

// MARK: - 核对用的缓冲

/// 核对时画源图用的内存，按「槽」复用。
///
/// 解一张 2400 万像素的图要近百 MB，每张都向系统新要一块，CPU 就大把花在缺页清零和归还上（系统态）。
/// 所以每个同时进行的核对占一个槽，槽里的内存在一批里反复用，只增不减到这一批用到的最大尺寸。
/// 槽数就是同时做核对的张数上限（`shared` 是核数的三分之一，至少 2）：`acquire` 在没有空槽时等。
///
/// 内存什么时候还给系统：没有批量在跑时，槽一放回（`release`）就还；有批量在跑时（`beginBatch` 与
/// `endBatch` 之间，runConversions 包着整批），放回的槽留着内存给下一张用，最后一批结束时（`endBatch`
/// 把在跑的批数减到 0）全部还掉。界面是常驻进程，转完一批不会一直占着这几百 MB。内存直接向系统要
/// （mmap），还的时候 munmap，一定回到系统，不留在 malloc 的缓存里。
///
/// 线程安全：空槽表、在跑的批数、占着的总字节数都只在 `lock` 里读写；一个槽从 `acquire` 到 `release`
/// 只归一个核对，槽里的内存只由它读写，不用锁。单测「核对用的缓冲」守着：同时拿到的两个槽内存不重叠、
/// 槽用完时 acquire 等着、一批结束后一个字节都不占。
final class QualityBuffers {
    /// 一个槽。
    final class Slot {
        fileprivate unowned let pool: QualityBuffers
        fileprivate var base: UnsafeMutableRawPointer?
        fileprivate var bytes = 0
        fileprivate init(pool: QualityBuffers) { self.pool = pool }

        /// 至少 `bytes` 字节的内存：够就原样用，不够就还掉旧的、要一块新的。要不到是 nil。
        func memory(_ bytes: Int) -> UnsafeMutableRawPointer? {
            if let base, self.bytes >= bytes { return base }
            pool.lock.lock()
            pool.unmapLocked(self)
            pool.lock.unlock()
            guard bytes > 0 else { return nil }
            let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            guard let p, p != MAP_FAILED else { return nil }
            pool.lock.lock()
            (base, self.bytes) = (p, bytes)
            pool.retained += bytes
            pool.lock.unlock()
            return p
        }
    }

    /// 核数的三分之一，至少 2。整幅解一张 JPEG 时解码器自己要多占约一倍于像素的内存，批量按核数并发时
    /// 全都同时解就是几个 GB；限住它，峰值内存减半，墙钟不变甚至略快（解码、编码共用硬件，挤在一起反而
    /// 互相等）。量法与数见 README「转完核对画质」。
    static let shared = QualityBuffers(slots: max(2, ProcessInfo.processInfo.activeProcessorCount / 3))

    fileprivate let lock = NSCondition()
    private var idle: [Slot] = []
    private var batches = 0
    fileprivate var retained = 0

    init(slots: Int) {
        precondition(slots > 0, "槽数至少 1")
        idle = (0..<slots).map { _ in Slot(pool: self) }
    }

    /// 拿一个空槽；没有就等到有槽放回。
    func acquire() -> Slot {
        lock.lock(); defer { lock.unlock() }
        while idle.isEmpty { lock.wait() }
        return idle.removeLast()
    }

    /// 放回槽。没有批量在跑时，槽里的内存当场还给系统。
    func release(_ slot: Slot) {
        lock.lock(); defer { lock.unlock() }
        if batches == 0 { unmapLocked(slot) }
        idle.append(slot)
        lock.signal()
    }

    /// 一批开始：这一批里放回的槽留着内存。可以有几批同时在跑，按次数与 endBatch 配对。
    func beginBatch() {
        lock.lock(); defer { lock.unlock() }
        batches += 1
    }

    /// 一批结束：最后一批结束时，空槽里的内存全部还给系统（还在用的槽放回时自己还）。
    func endBatch() {
        lock.lock(); defer { lock.unlock() }
        precondition(batches > 0, "endBatch 多于 beginBatch")
        batches -= 1
        if batches == 0 { idle.forEach(unmapLocked) }
    }

    /// 所有槽（含正在用的）一共占着的字节数。
    var retainedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return retained
    }

    /// 在 lock 里调：还掉一个槽的内存。
    fileprivate func unmapLocked(_ slot: Slot) {
        guard let base = slot.base else { return }
        munmap(base, slot.bytes)
        retained -= slot.bytes
        (slot.base, slot.bytes) = (nil, 0)
    }
}

// MARK: - 从文件量

/// 解码好的一段像素，连同持有那块内存的对象。
private struct DecodedPixels {
    let pixels: RGBPixels
    /// 持有像素内存的 CFData（ImageIO 解出来的那块）；vImage 转换出来的缓冲由 release 释放。
    let owner: AnyObject?
    let release: () -> Void
}

/// 8 位、每像素 4 字节、第 4 字节不用（不是 alpha）的 RGB 布局里，R、G、B 各在第几字节；别的布局是 nil。
private func rgbOffsets(_ image: CGImage) -> (r: Int, g: Int, b: Int)? {
    guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, !image.bitmapInfo.contains(.floatComponents) else {
        return nil
    }
    let little = image.byteOrderInfo == .order32Little
    switch image.alphaInfo {
    case .noneSkipLast: return little ? (3, 2, 1) : (0, 1, 2)
    case .noneSkipFirst: return little ? (2, 1, 0) : (1, 2, 3)
    default: return nil
    }
}

/// 把图像（或从它裁出的一段）真解码出像素，以 `colorSpace` 解释，不应用方向。解不出是 nil。
///
/// ImageIO 解出来的已经是 8 位 RGB、色彩空间就是 `colorSpace` 时（JPEG 和 HEIC 通常都是 RGBX），直接用
/// 它解出的那块内存，不再拷一份；否则用 vImage 画进一份 8 位 RGBX。调用方用完调 release()。
private func decodedPixels(_ image: CGImage, colorSpace: CGColorSpace) -> DecodedPixels? {
    if image.colorSpace == colorSpace, let offsets = rgbOffsets(image) {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.bytesPerRow * (image.height - 1) + 4 * image.width
        else { return nil }
        let pixels = RGBPixels(base: base, width: image.width, height: image.height, rowBytes: image.bytesPerRow,
                               offsets: offsets)
        return DecodedPixels(pixels: pixels, owner: data, release: {})
    }
    guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: colorSpace,
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
          let buffer = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
    let pixels = RGBPixels(base: buffer.data.assumingMemoryBound(to: UInt8.self), width: Int(buffer.width),
                           height: Int(buffer.height), rowBytes: buffer.rowBytes)
    return DecodedPixels(pixels: pixels, owner: nil, release: { buffer.free() })
}

/// drawnPixels 的每行字节数：4 × 宽，补到 64 的倍数。
func drawnRowBytes(_ width: Int) -> Int { (width * 4 + 63) / 64 * 64 }

/// 把图像画进 `memory`（调用方给的内存，至少 drawnRowBytes(宽) × 高 字节）：8 位 RGBX、以 `colorSpace`
/// 解释、`.copy` 混合、不插值，不应用方向。画不了（位图上下文建不起来）是 nil。
///
/// 和 `dataProvider` 解出的像素不是逐字节相同：约一百万像素以上的 JPEG（ImageIO 改用硬件解码）两条路
/// 的颜色转换不同，实测每一行都有差，相机样的 4:2:2 最多 1 个色阶、ImageIO 编的 4:2:0 最多 4 个；量出的
/// PSNR 因此低 0.6–1.3 dB，局部 SSIM 差不到 0.001，都偏向把画质说得略差。小图两条路逐字节相同。
func drawnPixels(_ image: CGImage, colorSpace: CGColorSpace, into memory: UnsafeMutableRawPointer) -> RGBPixels? {
    let w = image.width, h = image.height, rowBytes = drawnRowBytes(w)
    guard let ctx = CGContext(data: memory, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setBlendMode(.copy)
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return RGBPixels(base: UnsafePointer(memory.assumingMemoryBound(to: UInt8.self)), width: w, height: h,
                     rowBytes: rowBytes)
}

/// 不让 ImageIO 缓存解码结果：这边用完那块像素就丢掉。
private let uncachedDecode = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary

/// 产物分几条带解。
let qualityStripCount = 4

/// 高 `height` 的产物一次解的行数：整幅的四分之一，补到 16 的倍数（至少 16）。ImageIO 解从 HEIC 里
/// 裁出的一段时只解那一段，产物于是同一时刻只有一条带的像素在内存里。
///
/// 为什么按高度分四条：每解一段，ImageIO 都要另开、另关一次硬件的像素转换，解码也是整块整块（HEIC
/// 的图块 512 行）地解，上下余量又多碰一两排图块，所以段越多系统态越高；段越高，解码器同时占的内存
/// 越多。在 18 核的 M5 Pro 上按默认并发量过（两组夹具 18 张 6000×4000、36 张 4032×3024，相机样那种
/// 4:2:2 和 ImageIO 编的 4:2:0 各一套），固定 512 行（6000×4000 分 8 段）系统态最高；4032×3024 分 3 段
/// （1024 行）峰值内存比改之前高一成上下；2048 行、整幅解（或整幅画进复用的缓冲）系统态再低一些，峰值
/// 内存高出一到四成。分 4 段在两种尺寸上都是峰值内存与改之前持平（差在几次量的起伏以内）的几种里系统态
/// 最低的；段内的像素占整幅的比例不变，峰值内存跟着图的大小走。画进复用的缓冲对产物没用：ImageIO 解
/// HEIC 照样先解进自己的一块再拷过来，系统态反而略高。数见 README「转完核对画质」。
func qualityStripRows(height: Int) -> Int {
    let rows = (height + qualityStripCount - 1) / qualityStripCount
    return max(ssimBlockSide, (rows + ssimBlockSide - 1) / ssimBlockSide * ssimBlockSide)
}

/// 裁产物时上下各多带的行数。裁出的一段在边上那一两行的色度插值缺了邻行，与整幅解码差 1 个色阶；
/// 多带几行、只用中间那段，解出的像素就与整幅解码逐字节相同（单测「按条带解产物」守着）。
let qualityStripMargin = 16

/// 核对 `product`（刚写好的 HEIC）相对 `source`（编码用的那个图像源）的画质。
///
/// 两边各取第 0 张真解码：源图的色彩空间是 RGB 的就都以它解释，否则 sRGB；不应用方向（两边方向标签
/// 相同）。宽高不同、有一边解不出，都量不了。
///
/// 源整幅解一次，画进槽里复用的内存（drawnPixels）：从 JPEG 里裁一段来解走的是另一套解码，像素和
/// 整幅解码差出几个色阶（实测到 7），会把两套解码器之间的差算到编码器头上。画进去而不取
/// `dataProvider`：相机 JPEG（4:2:2）取 `dataProvider` 要另做一遍颜色转换、每张新分配整幅的内存，系统态
/// 是画进去的四倍多；ImageIO 编的 4:2:0 反过来是画进去略贵（单线程每张多十毫秒上下的系统态，见 README）。
/// 产物按 `stripRows` 行（默认 qualityStripRows）一条一条地解、算完就丢。同时做核对的张数由 `buffers`
/// 的槽数限住。`stripRows`、`buffers` 只供单测替换。
func qualityReading(source: CGImageSource, product: URL, stripRows: Int? = nil,
                    buffers: QualityBuffers = .shared) -> QualityReading {
    precondition(stripRows.map { $0 > 0 && $0 % ssimBlockSide == 0 } ?? true, "条带行数要是 16 的倍数")
    let slot = buffers.acquire()
    defer { buffers.release(slot) }
    guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, uncachedDecode) else {
        return .undecodable("解不出源图的像素")
    }
    guard let productSource = CGImageSourceCreateWithURL(product as CFURL, nil),
          let productImage = CGImageSourceCreateImageAtIndex(productSource, 0, uncachedDecode) else {
        return .undecodable("解不出产物的像素")
    }
    let sourceSize = PixelSize(width: sourceImage.width, height: sourceImage.height)
    let productSize = PixelSize(width: productImage.width, height: productImage.height)
    guard sourceSize == productSize else { return .sizeChanged(source: sourceSize, product: productSize) }
    let space = sourceImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let w = sourceSize.width, h = sourceSize.height
    guard let memory = slot.memory(drawnRowBytes(w) * h),
          let a = drawnPixels(sourceImage, colorSpace: space, into: memory) else {
        return .undecodable("解不出源图的像素")
    }
    let tally = QualityTally(width: w, height: h)
    // 整张图当一块时只能一次喂完（这时图很窄或很矮，整幅也不大）。
    let step = w < ssimBlockSide || h < ssimBlockSide ? h : (stripRows ?? qualityStripRows(height: h))
    var y = 0
    while y < h {
        let rows = min(step, h - y)
        let top = max(0, y - qualityStripMargin), bottom = min(h, y + rows + qualityStripMargin)
        guard let strip = bottom - top == h ? productImage
                : productImage.cropping(to: CGRect(x: 0, y: top, width: w, height: bottom - top)),
              let b = decodedPixels(strip, colorSpace: space), b.pixels.width == w, b.pixels.height == bottom - top else {
            return .undecodable("解不出产物的像素")
        }
        defer { b.release() }
        withExtendedLifetime(b.owner) { tally.add(a.rows(y, rows), b.pixels.rows(y - top, rows)) }
        y += rows
    }
    return .measured(tally.result())
}
