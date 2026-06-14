// make_appicon.swift —— 生成 7-Zip.app 的高清应用图标（1024×1024 PNG）。
// macOS 风格：圆角 squircle 渐变底 + 居中白色「7z」+ 底部压缩箭头点缀。
// 运行：swift make_appicon.swift  → 输出 /tmp/appicon_1024.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// 圆角矩形（留边距，符合 Big Sur 图标网格）
let m: CGFloat = S * 0.094
let rect = CGRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
let radius = (S - 2*m) * 0.2237
let rp = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 轻微投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.03,
              color: NSColor(white: 0, alpha: 0.28).cgColor)
NSColor.white.setFill()
rp.fill()
ctx.restoreGState()

// 渐变底（深蓝 → 青，对角）
rp.addClip()
let c1 = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.36, alpha: 1)
let c2 = NSColor(calibratedRed: 0.16, green: 0.52, blue: 0.69, alpha: 1)
NSGradient(starting: c1, ending: c2)!.draw(in: rect, angle: -52)

// 居中「7z」
let para = NSMutableParagraphStyle(); para.alignment = .center
let font = NSFont.systemFont(ofSize: S * 0.44, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
  .font: font,
  .foregroundColor: NSColor.white,
  .paragraphStyle: para,
]
let text = "7z" as NSString
let tsize = text.size(withAttributes: attrs)
text.draw(in: CGRect(x: 0, y: (S - tsize.height)/2 + S*0.045, width: S, height: tsize.height),
          withAttributes: attrs)

// 底部「压缩」点缀：两道向中心的箭头托一条横线
let lineY = S * 0.30
let cx = S/2
let aw = S * 0.052            // 箭头臂长
let gap = S * 0.085          // 中心间隙
NSColor(white: 1, alpha: 0.9).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = S * 0.018
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
// 左箭头 ▸
arrow.move(to: NSPoint(x: cx - gap - aw, y: lineY + aw))
arrow.line(to: NSPoint(x: cx - gap, y: lineY))
arrow.line(to: NSPoint(x: cx - gap - aw, y: lineY - aw))
// 右箭头 ◂
arrow.move(to: NSPoint(x: cx + gap + aw, y: lineY + aw))
arrow.line(to: NSPoint(x: cx + gap, y: lineY))
arrow.line(to: NSPoint(x: cx + gap + aw, y: lineY - aw))
arrow.stroke()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!); exit(2)
}
try! png.write(to: URL(fileURLWithPath: "/tmp/appicon_1024.png"))
print("✓ /tmp/appicon_1024.png")
