// draw-icon.swift — renders the 1024pt master PNG for Roost.app's icon.
//
//   swift draw-icon.swift out.png
//
// Run via icon/build-icon.sh, which then scales this into the .iconset and
// packs a .icns. The artwork is deliberately simple: the macOS icon squircle
// with the `bird.fill` SF Symbol knocked out in white. Using the system symbol
// (rather than hand-drawn bezier paths) keeps the app icon and the menu bar
// glyph literally the same shape.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "roost-1024.png"

let canvas: CGFloat = 1024
// Big Sur icon grid: artwork occupies a centred 824pt squircle, leaving the
// shadow margin macOS expects around it.
let plate: CGFloat = 824
let radius: CGFloat = plate * 0.2246

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let origin = (canvas - plate) / 2
    let plateRect = NSRect(x: origin, y: origin, width: plate, height: plate)
    let squircle = NSBezierPath(roundedRect: plateRect, xRadius: radius, yRadius: radius)

    // Dusk gradient: the app sits in the menu bar at the top of the screen, so
    // the icon reads top-lit.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.31, green: 0.44, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.17, green: 0.22, blue: 0.52, alpha: 1),
    ])
    gradient?.draw(in: squircle, angle: -90)

    // The bird, centred and sized to about half the plate.
    let config = NSImage.SymbolConfiguration(pointSize: plate * 0.46, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else { return true }

    let size = symbol.size
    let white = NSImage(size: size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)   // tint the template glyph
        return true
    }
    white.draw(in: NSRect(
        x: (canvas - size.width) / 2,
        y: (canvas - size.height) / 2,
        width: size.width,
        height: size.height
    ))
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("draw-icon: could not encode PNG\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("draw-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
