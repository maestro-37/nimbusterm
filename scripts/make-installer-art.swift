#!/usr/bin/env swift
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor, centeredIn width: CGFloat? = nil) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = text as NSString
    var x = point.x
    if let width {
        x = (width - string.size(withAttributes: attrs).width) / 2
    }
    string.draw(at: NSPoint(x: x, y: point.y), withAttributes: attrs)
}

func drawGrid(width: CGFloat, height: CGFloat, step: CGFloat, alpha: CGFloat) {
    color(0x8FB4FF, alpha: alpha).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    var x: CGFloat = 0
    while x <= width {
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: height))
        x += step
    }
    var y: CGFloat = 0
    while y <= height {
        path.move(to: NSPoint(x: 0, y: y))
        path.line(to: NSPoint(x: width, y: y))
        y += step
    }
    path.stroke()
}

func drawSlot(center: NSPoint, size: CGFloat, alpha: CGFloat) {
    let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    path.lineWidth = 1.5
    path.setLineDash([6, 6], count: 2, phase: 0)
    color(0x7AA2F7, alpha: alpha).setStroke()
    path.stroke()
}

func drawArrow(from start: NSPoint, to end: NSPoint, color arrowColor: NSColor) {
    let body = NSBezierPath()
    body.move(to: start)
    body.line(to: NSPoint(x: end.x - 14, y: end.y))
    body.lineWidth = 5
    body.lineCapStyle = .round
    arrowColor.setStroke()
    body.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 20, y: end.y + 11))
    head.line(to: end)
    head.line(to: NSPoint(x: end.x - 20, y: end.y - 11))
    head.close()
    arrowColor.setFill()
    head.fill()
}

/// Renders into an explicit 2x bitmap so Finder shows a sharp background on Retina.
func renderPNG(width: CGFloat, height: CGFloat, path: String, draw: () -> Void) {
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fputs("bitmap context failed\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr)
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(Int(width * scale))x\(Int(height * scale)))")
}

func makeDMGBackground(path: String) {
    let width: CGFloat = 660
    let height: CGFloat = 420
    renderPNG(width: width, height: height, path: path) {
        NSGradient(colors: [color(0x0A1020), color(0x101A2E)])?.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            angle: -90
        )

        for center in [NSPoint(x: 170, y: 208), NSPoint(x: 490, y: 208)] {
            let glowRect = NSRect(x: center.x - 120, y: center.y - 120, width: 240, height: 240)
            NSGradient(colors: [color(0x4C7DFF, alpha: 0.18), color(0x4C7DFF, alpha: 0)])?
                .draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
        }

        drawGrid(width: width, height: height, step: 30, alpha: 0.045)
        drawSlot(center: NSPoint(x: 170, y: 208), size: 154, alpha: 0.32)
        drawSlot(center: NSPoint(x: 490, y: 208), size: 154, alpha: 0.32)
        drawArrow(
            from: NSPoint(x: 275, y: 208),
            to: NSPoint(x: 388, y: 208),
            color: color(0x7AA2F7, alpha: 0.85)
        )

        drawText(
            "NimbusTerm",
            at: NSPoint(x: 0, y: 358),
            font: .systemFont(ofSize: 30, weight: .semibold),
            color: color(0xE8EEFF),
            centeredIn: width
        )
        drawText(
            "Drag to Applications  ·  Перетащите в Applications",
            at: NSPoint(x: 0, y: 332),
            font: .systemFont(ofSize: 12.5, weight: .regular),
            color: color(0x9EB0CC),
            centeredIn: width
        )
        drawText(
            "SSH  ·  SFTP  ·  tunnels  ·  X11  ·  RDP/VNC",
            at: NSPoint(x: 0, y: 58),
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: color(0x7186A6),
            centeredIn: width
        )
        drawText(
            "macOS 14+  ·  Apple Silicon",
            at: NSPoint(x: 0, y: 40),
            font: .systemFont(ofSize: 9.5, weight: .regular),
            color: color(0x53657F),
            centeredIn: width
        )
    }
}

func makePKGBackground(path: String) {
    let width: CGFloat = 620
    let height: CGFloat = 418
    renderPNG(width: width, height: height, path: path) {
        NSGradient(colors: [color(0x0A1020), color(0x121C30)])?.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            angle: -90
        )
        drawGrid(width: width, height: height, step: 28, alpha: 0.035)

        let glowRect = NSRect(x: width - 330, y: -40, width: 420, height: 420)
        NSGradient(colors: [color(0x4C7DFF, alpha: 0.16), color(0x4C7DFF, alpha: 0)])?
            .draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: width - 210, y: 300))
        chevron.line(to: NSPoint(x: width - 150, y: 245))
        chevron.line(to: NSPoint(x: width - 210, y: 190))
        chevron.lineWidth = 26
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        color(0x7AA2F7, alpha: 0.10).setStroke()
        chevron.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: width - 130, y: 190))
        cursor.line(to: NSPoint(x: width - 40, y: 190))
        cursor.lineWidth = 26
        cursor.lineCapStyle = .round
        color(0x7AA2F7, alpha: 0.10).setStroke()
        cursor.stroke()

        drawText(
            "NimbusTerm",
            at: NSPoint(x: 28, y: 24),
            font: .systemFont(ofSize: 18, weight: .semibold),
            color: color(0x8FA6C9, alpha: 0.85)
        )
        drawText(
            "нативный терминальный workspace",
            at: NSPoint(x: 28, y: 10),
            font: .systemFont(ofSize: 9.5, weight: .regular),
            color: color(0x5E7392, alpha: 0.9)
        )
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: make-installer-art.swift dmg|pkg output.png\n", stderr)
    exit(2)
}
switch args[1] {
case "dmg": makeDMGBackground(path: args[2])
case "pkg": makePKGBackground(path: args[2])
default:
    fputs("unknown kind \(args[1])\n", stderr)
    exit(2)
}
