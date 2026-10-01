// Generates App/Resources/AppIcon.icns: run `swift Scripts/MakeIcon.swift` (needs only AppKit).
import AppKit
import Foundation

func render(_ size: Int) -> Data {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    // macOS icon grid: the artwork fills about 80% of the canvas and is a continuous rounded rectangle.
    let inset = side * 0.1
    let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = side * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.95, alpha: 1), ending: NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.72, alpha: 1))?
        .draw(in: path, angle: -60)
    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.14, green: 0.58, blue: 0.88, alpha: 1), NSColor.white]))
    if let symbol = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let target = NSRect(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: target)
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return bitmap.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("MACSPACE.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let output = URL(fileURLWithPath: "App/Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? fileManager.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
