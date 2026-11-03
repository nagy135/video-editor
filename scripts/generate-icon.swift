import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift generate-icon.swift <AppIcon.iconset>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawEditor() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
    NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.41, blue: 0.91, alpha: 1),
               ending: NSColor(calibratedRed: 0.19, green: 0.19, blue: 0.56, alpha: 1))!
        .draw(in: tile, angle: -70)
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 436, y: 550))
    play.line(to: NSPoint(x: 436, y: 764))
    play.curve(to: NSPoint(x: 458, y: 777), controlPoint1: NSPoint(x: 436, y: 778), controlPoint2: NSPoint(x: 446, y: 784))
    play.line(to: NSPoint(x: 634, y: 670))
    play.curve(to: NSPoint(x: 634, y: 645), controlPoint1: NSPoint(x: 647, y: 662), controlPoint2: NSPoint(x: 647, y: 653))
    play.line(to: NSPoint(x: 458, y: 538))
    play.curve(to: NSPoint(x: 436, y: 550), controlPoint1: NSPoint(x: 446, y: 531), controlPoint2: NSPoint(x: 436, y: 537))
    play.close()
    NSColor.white.setFill()
    play.fill()

    let film = NSBezierPath(roundedRect: NSRect(x: 224, y: 268, width: 576, height: 230), xRadius: 28, yRadius: 28)
    NSColor.white.withAlphaComponent(0.95).setFill()
    film.fill()
    let ink = NSColor(calibratedRed: 0.21, green: 0.28, blue: 0.65, alpha: 1)
    ink.withAlphaComponent(0.45).setFill()
    for x in stride(from: 248, through: 756, by: 46) {
        for y in [286, 462] {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 22, height: 16), xRadius: 4, yRadius: 4).fill()
        }
    }
    let curve = NSBezierPath()
    curve.move(to: NSPoint(x: 255, y: 334))
    curve.curve(to: NSPoint(x: 510, y: 433), controlPoint1: NSPoint(x: 390, y: 334), controlPoint2: NSPoint(x: 385, y: 433))
    curve.curve(to: NSPoint(x: 767, y: 354), controlPoint1: NSPoint(x: 635, y: 433), controlPoint2: NSPoint(x: 636, y: 354))
    curve.lineWidth = 15
    curve.lineCapStyle = .round
    ink.setStroke()
    curve.stroke()
    for point in [NSPoint(x: 288, y: 336), NSPoint(x: 510, y: 433), NSPoint(x: 735, y: 356)] {
        NSColor.white.setFill()
        let node = NSBezierPath(ovalIn: NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        node.fill()
        ink.setStroke()
        node.lineWidth = 7
        node.stroke()
    }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawEditor()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
