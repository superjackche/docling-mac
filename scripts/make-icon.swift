import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.90, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202).fill()
        NSColor(calibratedRed: 0.11, green: 0.38, blue: 0.33, alpha: 1).setFill()
        let page = NSBezierPath()
        page.move(to: NSPoint(x: 292, y: 230)); page.line(to: NSPoint(x: 732, y: 230))
        page.line(to: NSPoint(x: 732, y: 638)); page.line(to: NSPoint(x: 574, y: 796))
        page.line(to: NSPoint(x: 292, y: 796)); page.close(); page.fill()
        NSColor(calibratedRed: 0.65, green: 0.79, blue: 0.68, alpha: 1).setFill()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 574, y: 796)); fold.line(to: NSPoint(x: 574, y: 638))
        fold.line(to: NSPoint(x: 732, y: 638)); fold.close(); fold.fill()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        for (width, y) in [(230, 533), (302, 445), (202, 357)] {
            NSBezierPath(roundedRect: NSRect(x: 360, y: y, width: width, height: 24), xRadius: 12, yRadius: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
