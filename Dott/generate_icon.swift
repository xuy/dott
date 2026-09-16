#!/usr/bin/swift
// Renders Dott.icns: a simple dark rounded-square with a centered dot,
// echoing the menu-bar glyph. Run directly; build_app.sh calls this if
// Dott.icns doesn't exist yet.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
let background = NSGradient(
    starting: NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.20, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.38, alpha: 1.0))
background?.draw(in: path, angle: -90)

let dotDiameter = size * 0.32
let dotRect = NSRect(
    x: (size - dotDiameter) / 2, y: (size - dotDiameter) / 2,
    width: dotDiameter, height: dotDiameter)
NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.30, alpha: 1.0).setFill()
NSBezierPath(ovalIn: dotRect).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon PNG")
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = scriptDir.appendingPathComponent("icon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let masterPath = iconset.appendingPathComponent("master.png")
try png.write(to: masterPath)

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in sizes {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", "\(px)", "\(px)", masterPath.path,
        "--out", iconset.appendingPathComponent("\(name).png").path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
try? FileManager.default.removeItem(at: masterPath)

let icns = scriptDir.appendingPathComponent("Dott.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()

print("Wrote \(icns.path)")
