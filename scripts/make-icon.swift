import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let source = NSImage(contentsOfFile: "Assets/AppIcon-source.png")!
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        // Standard macOS icon packaging: resize the generated source into the rounded tile.
        let tile = NSRect(x: 64, y: 64, width: 896, height: 896)
        NSBezierPath(roundedRect: tile, xRadius: 202, yRadius: 202).addClip()
        source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
