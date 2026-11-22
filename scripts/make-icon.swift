#!/usr/bin/env swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let background = NSRect(x: 36, y: 36, width: size - 72, height: size - 72)
let backgroundPath = NSBezierPath(roundedRect: background, xRadius: 210, yRadius: 210)
NSGradient(colors: [
    NSColor(srgbRed: 0.05, green: 0.07, blue: 0.12, alpha: 1),
    NSColor(srgbRed: 0.08, green: 0.14, blue: 0.26, alpha: 1)
])?.draw(in: backgroundPath, angle: -60)

NSColor(srgbRed: 0.10, green: 0.18, blue: 0.32, alpha: 0.9).setStroke()
backgroundPath.lineWidth = 8
backgroundPath.stroke()

// Subtle grid
NSColor(srgbRed: 0.24, green: 0.38, blue: 0.62, alpha: 0.18).setStroke()
for index in 0..<7 {
    let y = 180 + CGFloat(index) * 105
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 130, y: y))
    line.line(to: NSPoint(x: 894, y: y))
    line.lineWidth = 2
    line.stroke()
}

// Prompt chevron
let accent = NSColor(srgbRed: 0.45, green: 0.66, blue: 1.0, alpha: 1)
accent.setStroke()
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 250, y: 620))
chevron.line(to: NSPoint(x: 390, y: 512))
chevron.line(to: NSPoint(x: 250, y: 404))
chevron.lineWidth = 58
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
chevron.stroke()

// Cursor underscore
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 450, y: 396))
cursor.line(to: NSPoint(x: 700, y: 396))
cursor.lineWidth = 58
cursor.lineCapStyle = .round
cursor.stroke()

// Network nodes
let dot = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.75, alpha: 1)
for point in [NSPoint(x: 742, y: 690), NSPoint(x: 820, y: 600), NSPoint(x: 742, y: 510)] {
    let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
    dot.setFill()
    circle.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: "Resources/icon-1024.png")
try png.write(to: output)
print("wrote \(output.path)")
