import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSColor(srgbRed: 0.16, green: 0.40, blue: 0.95, alpha: 1)
background.setFill()
NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()

NSColor.white.withAlphaComponent(0.96).setFill()
NSBezierPath(roundedRect: NSRect(x: 156, y: 196, width: 712, height: 148), xRadius: 74, yRadius: 74).fill()

background.setFill()
for index in 0..<4 {
    let x = 236 + CGFloat(index) * 148
    NSBezierPath(ovalIn: NSRect(x: x, y: 228, width: 84, height: 84)).fill()
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("Could not draw the DockBar icon.\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: output))
} catch {
    fputs("Could not write icon: \(error)\n", stderr)
    exit(1)
}
