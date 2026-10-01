// Turns the 1024px icon artwork into an .iconset on Apple's icon grid.
// Usage: swift make-icon.swift <artwork> <out.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let artwork = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <artwork> <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Apple's grid: the artwork sits in an 824pt square centred on a 1024pt canvas.
    let size = CGFloat(pixels)
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.set()
    artwork.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
