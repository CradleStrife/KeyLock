import Cocoa

// 生成 1024×1024 的应用图标 PNG：深色圆角底 + 白色锁
let out = CommandLine.arguments[1]
let S: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.27, blue: 0.34, alpha: 1),
                    NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)])!
    .draw(in: path, angle: -90)

let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let white = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let scale = 440 / max(sym.size.width, sym.size.height)
    let w = sym.size.width * scale, h = sym.size.height * scale
    white.draw(in: NSRect(x: (S - w) / 2, y: (S - h) / 2, width: w, height: h))
}

NSGraphicsContext.current?.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
