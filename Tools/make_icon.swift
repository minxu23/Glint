// 生成 Glint（中文名吉光）的应用图标：极光色的渐变圆角方块上，一根粗壮的白色羽毛，羽尖化成几点光。
//
// 名字的三层意思都在图里：「吉光片羽」的羽毛；「极光」（谐音）的底色和那道柔和的光带；
// 羽尖散成光点、再化成星芒——把格式转换看作「羽化」。路子与用户别的应用图标一致：
// 深色渐变底、粗壮的白色图形、一点轻微的立体感；圆角方块四周留 5.5%、圆角 22.4%。
//
// 用法（在仓库根目录）：
//     swiftc -O Tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon Resources
// 或 `make icon`。产物：Resources/AppIcon.icns（装进应用包）、Resources/AppIcon-1024.png。
// 每个尺寸都按那个尺寸直接画，不是从大图缩小。
import AppKit
import CoreGraphics

func rgb(_ h: UInt32) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
}
// 渐变：左上青、右下深靛；投影用比底色深的同色系，不用灰黑；极光带是浅青绿
let top: UInt32 = 0x0E8F8C, bottom: UInt32 = 0x1C0F5C, ink: UInt32 = 0x0B0636
let aurora: UInt32 = 0x5CF2C8

/// 按边长 S 画一张图标。所有坐标按 1024 见方写，再整体缩放。
func render(_ S: CGFloat) -> CGImage {
    let k = S / 1024

    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    // 坐标系换成左上为原点、1024 见方
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: k, y: -k)

    // 圆角方块：四周留 5.5%，圆角 22.4%（与用户别的应用图标同一套比例）
    let pad: CGFloat = 1024 * 0.055
    let tile = CGRect(x: pad, y: pad, width: 1024 - 2 * pad, height: 1024 - 2 * pad)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 1024 * 0.224, cornerHeight: 1024 * 0.224, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    // 极光：一道斜跨的弧形光带。只画它的投影（把光带本身挪到画布外），得到柔和、没有硬边的一片光
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -3000 * k, height: 0), blur: 120 * k, color: rgb(aurora).copy(alpha: 0.55)!)
    ctx.setStrokeColor(rgb(aurora)); ctx.setLineWidth(170); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 2960, y: 600)); ctx.addCurve(to: CGPoint(x: 4100, y: 300), control1: CGPoint(x: 3280, y: 330), control2: CGPoint(x: 3660, y: 660))
    ctx.strokePath()
    ctx.restoreGState()
    // 一层很淡的高光，从左上往下收，给一点立体感
    let gloss = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 300, y: 220), startRadius: 0, endCenter: CGPoint(x: 300, y: 220), endRadius: 620, options: [])
    ctx.restoreGState()

    // ---- 羽毛：先在「羽轴沿 x 轴」的局部坐标里画，再转到斜向右上 ----
    // 局部坐标：羽根在 x=0，羽尖在 x=L；y 向上为上片羽面
    let L: CGFloat = 700
    func feather() -> CGMutablePath {
        let p = CGMutablePath()
        // 上片羽面：修长，羽尖收成尖
        p.move(to: CGPoint(x: 150, y: 0))
        p.addCurve(to: CGPoint(x: 370, y: 116), control1: CGPoint(x: 170, y: 72), control2: CGPoint(x: 255, y: 116))
        p.addCurve(to: CGPoint(x: L, y: 4), control1: CGPoint(x: 510, y: 116), control2: CGPoint(x: 640, y: 66))
        // 下片羽面：比上片窄，羽毛本来就不对称
        p.addCurve(to: CGPoint(x: 370, y: -92), control1: CGPoint(x: 630, y: -54), control2: CGPoint(x: 500, y: -92))
        p.addCurve(to: CGPoint(x: 150, y: 0), control1: CGPoint(x: 250, y: -92), control2: CGPoint(x: 172, y: -58))
        p.closeSubpath()
        // 羽根：一段收细的硬杆
        p.move(to: CGPoint(x: 0, y: -10)); p.addLine(to: CGPoint(x: 170, y: -17))
        p.addLine(to: CGPoint(x: 170, y: 17)); p.addLine(to: CGPoint(x: 0, y: 10))
        p.addArc(center: CGPoint(x: 0, y: 0), radius: 10, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
        p.closeSubpath()
        return p
    }
    // 羽面上的裂口（羽枝分开的地方），斜着朝羽尖，用透明挖掉
    func splits() -> CGMutablePath {
        let p = CGMutablePath()
        func wedge(_ x0: CGFloat, _ x1: CGFloat, _ side: CGFloat, _ w: CGFloat) {
            p.move(to: CGPoint(x: x0, y: side * 9))
            p.addLine(to: CGPoint(x: x1, y: side * 170))
            p.addLine(to: CGPoint(x: x1 + w, y: side * 170))
            p.addLine(to: CGPoint(x: x0 + w * 0.3, y: side * 9))
            p.closeSubpath()
        }
        wedge(300, 420, 1, 24)
        wedge(470, 575, 1, 22)
        wedge(360, 470, -1, 22)
        return p
    }

    // 斜向右上：羽根在左下，羽尖在右上
    let place = CGAffineTransform(translationX: 196, y: 836).rotated(by: -.pi * 0.25).scaledBy(x: 1.07, y: 1.07)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(ink).copy(alpha: 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.concatenate(place)
    // 羽毛本体：白色，上亮下稍冷，一点点体积感
    ctx.addPath(feather()); ctx.clip()
    let body = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE6EEFF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: 160), end: CGPoint(x: 0, y: -140), options: [])
    ctx.resetClip()
    // 挖掉羽轴（一条细线）和裂口
    ctx.setBlendMode(.clear)
    ctx.addPath(splits()); ctx.fillPath()
    ctx.setLineWidth(14); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 180, y: 0)); ctx.addLine(to: CGPoint(x: 600, y: 2)); ctx.strokePath()
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 羽化成光：羽尖外面三点四角星芒，由大到小飘开
    func sparkle(_ c: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
        let p = CGMutablePath()
        let n = 64
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            // 星芒曲线 x=r·cos³t, y=r·sin³t 的指数取小一点，身子更粗，小尺寸下也认得出
            let e: CGFloat = 2.4
            let x = r * copysign(pow(abs(cos(t)), e), cos(t)), y = r * copysign(pow(abs(sin(t)), e), sin(t))
            let pt = CGPoint(x: c.x + x, y: c.y + y)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(ink).copy(alpha: 0.35))
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha)); ctx.addPath(p); ctx.fillPath()
        ctx.restoreGState()
    }
    // 羽尖到星芒之间，几粒由大到小、越来越淡的光点：羽毛正在化成光
    for (c, r, al) in [(CGPoint(x: 738, y: 292), 15.0, 0.95), (CGPoint(x: 768, y: 258), 11.0, 0.8), (CGPoint(x: 792, y: 232), 7.5, 0.65)] as [(CGPoint, CGFloat, CGFloat)] {
        ctx.setFillColor(CGColor(gray: 1, alpha: al)); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    sparkle(CGPoint(x: 836, y: 196), 78, 1)
    sparkle(CGPoint(x: 722, y: 136), 36, 0.92)
    sparkle(CGPoint(x: 892, y: 318), 26, 0.85)


    return ctx.makeImage()!
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = NSTemporaryDirectory() + "AppIcon-\(getpid()).iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(CGFloat(base)), "\(iconset)/icon_\(base)x\(base).png")
    writePNG(render(CGFloat(base * 2)), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
writePNG(render(1024), "\(outDir)/AppIcon-1024.png")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
guard p.terminationStatus == 0 else { FileHandle.standardError.write(Data("iconutil 失败\n".utf8)); exit(1) }
print("已生成 \(outDir)/AppIcon.icns、\(outDir)/AppIcon-1024.png")
