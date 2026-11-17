//
//  InstallAppIcon.swift
//  DynamicMenu
//
//  Places full-bleed icon artwork (the iPhone export format, where the shape
//  reaches the canvas edges) on the macOS icon grid: the shape 824 of 1024 px,
//  centred, with the standard soft shadow, so it matches other apps in the Dock.
//  Writes every size the app icon set needs.
//
//      swift Tools/InstallAppIcon.swift <exports folder> [output folder]
//
//  Expects files named "DynamicMenu-iOS-Default-<size>@1x.png".
//

import AppKit

let exports = CommandLine.arguments[1]
let output = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2] : "DynamicMenu/Assets.xcassets/AppIcon.appiconset"

func source(for pixels: Int) -> NSImage {
    // The export at the same size, so small sizes keep the designer's own
    // pixel-fitting; otherwise the largest.
    let exact = "\(exports)/DynamicMenu-iOS-Default-\(pixels)@1x.png"
    let fallback = "\(exports)/DynamicMenu-iOS-Default-1024@1x.png"
    return NSImage(contentsOfFile: exact) ?? NSImage(contentsOfFile: fallback)!
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = CGSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let size = CGFloat(pixels)
    let body = size * 824 / 1024
    // Slightly above centre, leaving room below for the shadow, as Apple's grid does.
    let rect = CGRect(x: (size - body) / 2, y: (size - body) / 2 + size * 0.01, width: body, height: body)
    if pixels >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
        shadow.shadowBlurRadius = size * 0.025
        shadow.shadowOffset = CGSize(width: 0, height: -size * 0.01)
        shadow.set()
    }
    source(for: pixels).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                          (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    try! render(pixels: pixels).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    images.append(["idiom": "mac", "scale": "\(entry.scale)x", "size": "\(entry.size)x\(entry.size)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
print("Installed \(entries.count) icons into \(output)")
