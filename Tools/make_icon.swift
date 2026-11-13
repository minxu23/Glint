// 生成 Glint（中文名吉光）的应用图标，极简风格，两款，用户在应用菜单「应用图标」里选：
//
// - 浅色（默认）：米白底，一根粗线勾出羽毛的轮廓和羽轴，线条从羽尖的青渐变到羽根的靛；
//   羽尖上方一颗星芒。
// - 渐变：青到靛的渐变底，同样的羽毛和星芒，白色。
//
// 羽毛取「吉光片羽」，星芒是羽毛化成的光——把格式转换看作「羽化」；青、靛是极光的颜色。
// 圆角方块四周留 5.5%、圆角 22.4%（与用户别的应用图标同一套比例）。
//
// 用法（在仓库根目录）：
//     swiftc -O Tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon Resources
// 或 `make icon`。产物：Resources/AppIcon.icns、AppIcon-Gradient.icns（装进应用包），
// 以及两张 1024 的大图。每个尺寸都按那个尺寸直接画，不是从大图缩小：小尺寸线条加粗。
import AppKit
import CoreGraphics

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
}
let teal: UInt32 = 0x0E8F8C, indigo: UInt32 = 0x2A1C8C, deepIndigo: UInt32 = 0x1C0F5C, paper: UInt32 = 0xF6F5F1

enum Style: CaseIterable {
    case light, gradient
    var name: String { self == .light ? "AppIcon" : "AppIcon-Gradient" }
}

/// 羽毛的轮廓：在「羽轴沿 x 轴」的局部坐标里，羽根在 x=0，羽尖在 x=L；y 向上为上片羽面。
let L: CGFloat = 660
func vaneOutline() -> CGMutablePath {
    let p = CGMutablePath()
    let base = CGPoint(x: 120, y: 0), tip = CGPoint(x: L, y: 0)
    p.move(to: base)
    p.addCurve(to: tip, control1: CGPoint(x: 150, y: 175), control2: CGPoint(x: 520, y: 150))
    // 下片羽面比上片窄，羽毛本来就不对称
    p.addCurve(to: base, control1: CGPoint(x: 540, y: -120), control2: CGPoint(x: 170, y: -140))
    p.closeSubpath()
    return p
}

/// 四角星芒：x=r·cos^e t, y=r·sin^e t，e 取 2.6，身子比星形线粗，小尺寸下也认得出。
func sparkle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0...96 {
        let t = CGFloat(i) / 96 * 2 * .pi, e: CGFloat = 2.6
        let pt = CGPoint(x: c.x + r * copysign(pow(abs(cos(t)), e), cos(t)),
                         y: c.y + r * copysign(pow(abs(sin(t)), e), sin(t)))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

/// 按边长 S 画一张图标。所有坐标按 1024 见方写，再整体缩放。
func render(_ S: CGFloat, _ style: Style) -> CGImage {
    let k = S / 1024
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    // 坐标系换成左上为原点、1024 见方
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: k, y: -k)

    let pad: CGFloat = 1024 * 0.055
    let tile = CGRect(x: pad, y: pad, width: 1024 - 2 * pad, height: 1024 - 2 * pad)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 1024 * 0.224, cornerHeight: 1024 * 0.224, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    switch style {
    case .light:
        ctx.setFillColor(rgb(paper)); ctx.fill(tile)
    case .gradient:
        let g = CGGradient(colorsSpace: cs, colors: [rgb(teal), rgb(deepIndigo)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    }
    ctx.restoreGState()
    if style == .light {
        // 浅底在浅色桌面上会糊成一片，描一圈极淡的边
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(max(2, 1 / k))
        ctx.addPath(tilePath); ctx.strokePath()
    }

    // 线宽：1024 下 34；小尺寸按比例加粗，16 px 时约 1.3 像素
    let lw = 34 * max(1, pow(128 / S, 0.55))
    // 羽毛斜向右上，整体略偏左下，给星芒留位置
    let place = CGAffineTransform(translationX: 236, y: 788).rotated(by: -.pi / 4).scaledBy(x: 1.02, y: 1.02)
    let lines = CGMutablePath()
    lines.addPath(vaneOutline(), transform: place)
    // 羽轴连着羽根，一笔从羽面里伸出来；16 px 下羽面太窄，省掉羽面内那一段
    let shaftEnd: CGFloat = S <= 16 ? 150 : 500
    lines.move(to: CGPoint(x: 0, y: 0).applying(place)); lines.addLine(to: CGPoint(x: shaftEnd, y: 0).applying(place))
    let star = sparkle(CGPoint(x: 806, y: 214), 70 * max(1, pow(64 / S, 0.3)))

    ctx.saveGState()
    ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(lines); ctx.replacePathWithStrokedPath()
    ctx.addPath(star)
    switch style {
    case .light:
        // 线条和星芒一起填一道渐变：右上（羽尖、星芒）青，左下（羽根）靛
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [rgb(teal), rgb(indigo)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 780, y: 240), end: CGPoint(x: 240, y: 790),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    case .gradient:
        ctx.setFillColor(.white); ctx.fillPath()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
for style in Style.allCases {
    let iconset = NSTemporaryDirectory() + "\(style.name)-\(getpid()).iconset"
    try? FileManager.default.removeItem(atPath: iconset)
    try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        writePNG(render(CGFloat(base), style), "\(iconset)/icon_\(base)x\(base).png")
        writePNG(render(CGFloat(base * 2), style), "\(iconset)/icon_\(base)x\(base)@2x.png")
    }
    writePNG(render(1024, style), "\(outDir)/\(style.name)-1024.png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/\(style.name).icns"]
    try! p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(atPath: iconset)
    guard p.terminationStatus == 0 else { FileHandle.standardError.write(Data("iconutil 失败\n".utf8)); exit(1) }
    print("已生成 \(outDir)/\(style.name).icns、\(outDir)/\(style.name)-1024.png")
}
