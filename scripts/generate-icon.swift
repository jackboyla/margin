import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
    NSColor(srgbRed: 0.97, green: 0.94, blue: 0.87, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 232, y: 214, width: 560, height: 620), xRadius: 44, yRadius: 44).fill()
    NSColor(srgbRed: 0.80, green: 0.36, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 332, y: 288, width: 16, height: 472), xRadius: 8, yRadius: 8).fill()
    NSColor(srgbRed: 0.48, green: 0.50, blue: 0.53, alpha: 1).setFill()
    for (y, width) in [(710, 304), (622, 260), (534, 304), (446, 216)] {
        NSBezierPath(roundedRect: NSRect(x: 388, y: CGFloat(y), width: CGFloat(width), height: 24), xRadius: 12, yRadius: 12).fill()
    }
    NSColor(srgbRed: 0.94, green: 0.65, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 624, y: 190, width: 220, height: 168), xRadius: 48, yRadius: 48).fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 662, y: 218))
    tail.line(to: NSPoint(x: 650, y: 154))
    tail.line(to: NSPoint(x: 728, y: 218))
    tail.close()
    tail.fill()
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1).setFill()
    for x in [676, 724, 772] {
        NSBezierPath(ovalIn: NSRect(x: CGFloat(x), y: 262, width: 20, height: 20)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        try render(size: size * scale).write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
