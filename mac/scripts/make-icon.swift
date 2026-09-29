// 앱 아이콘 생성: swift scripts/make-icon.swift <출력.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS 아이콘 격자: 1024 캔버스 안 824 둥근 사각형
let inset = 100.0
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1),
                    NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!.draw(in: path, angle: -90)

// 파형 막대
let bars: [Double] = [0.22, 0.42, 0.68, 0.95, 0.62, 0.38, 0.8, 0.5, 0.28]
let barW = 44.0, gap = 22.0
let total = Double(bars.count) * barW + Double(bars.count - 1) * gap
var x = (size - total) / 2
let midY = size / 2 + 40
for (i, h) in bars.enumerated() {
    let bh = h * 360
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2)
    let t = Double(i) / Double(bars.count - 1)
    NSColor(red: 0.2 + 0.1 * t, green: 0.75 - 0.2 * t, blue: 1.0, alpha: 1).setFill()
    bar.fill()
    x += barW + gap
}

// 아래쪽 메모 줄
NSColor(white: 1, alpha: 0.9).setFill()
for (i, w) in [420.0, 320.0].enumerated() {
    let y = 300.0 - Double(i) * 62
    NSBezierPath(roundedRect: NSRect(x: (size - 420) / 2, y: y, width: w, height: 30), xRadius: 15, yRadius: 15).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
