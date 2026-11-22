import AppKit
import SwiftUI
import NimbusCore
import SwiftTerm

enum Theme {
    struct Palette {
        var foreground: NSColor
        var background: NSColor
        var cursor: NSColor
        var selection: NSColor
        var accent: SwiftUI.Color
    }

    static func palette(for theme: TerminalTheme) -> Palette {
        switch theme {
        case .nimbus:
            return Palette(
                foreground: NSColor(hex: 0xD8DEE9),
                background: NSColor(hex: 0x0F1420),
                cursor: NSColor(hex: 0x7AA2F7),
                selection: NSColor(hex: 0x33415E),
                accent: SwiftUI.Color(red: 0.48, green: 0.64, blue: 0.97)
            )
        case .solarizedDark:
            return Palette(
                foreground: NSColor(hex: 0x839496),
                background: NSColor(hex: 0x002B36),
                cursor: NSColor(hex: 0x93A1A1),
                selection: NSColor(hex: 0x073642),
                accent: SwiftUI.Color(red: 0.15, green: 0.55, blue: 0.55)
            )
        case .solarizedLight:
            return Palette(
                foreground: NSColor(hex: 0x657B83),
                background: NSColor(hex: 0xFDF6E3),
                cursor: NSColor(hex: 0x586E75),
                selection: NSColor(hex: 0xEEE8D5),
                accent: SwiftUI.Color(red: 0.15, green: 0.55, blue: 0.55)
            )
        case .dracula:
            return Palette(
                foreground: NSColor(hex: 0xF8F8F2),
                background: NSColor(hex: 0x282A36),
                cursor: NSColor(hex: 0xF8F8F2),
                selection: NSColor(hex: 0x44475A),
                accent: SwiftUI.Color(red: 0.74, green: 0.58, blue: 0.98)
            )
        case .system:
            return Palette(
                foreground: .textColor,
                background: .textBackgroundColor,
                cursor: .selectedControlColor,
                selection: .selectedTextBackgroundColor,
                accent: .accentColor
            )
        }
    }

    static func ansiPalette(for theme: TerminalTheme) -> [SwiftTerm.Color]? {
        switch theme {
        case .nimbus:
            return palette([
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
                0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5
            ])
        case .dracula:
            return palette([
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
                0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
                0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
            ])
        case .solarizedDark, .solarizedLight:
            return palette([
                0x073642, 0xDC322F, 0x859900, 0xB58900,
                0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
                0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
            ])
        case .system:
            return palette([
                0x000000, 0xCD0000, 0x00CD00, 0xCDCD00,
                0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00,
                0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF
            ])
        }
    }

    private static func palette(_ hexes: [UInt32]) -> [SwiftTerm.Color] {
        hexes.map { hex in
            SwiftTerm.Color(
                red: UInt16((hex >> 16 & 0xFF) * 257),
                green: UInt16((hex >> 8 & 0xFF) * 257),
                blue: UInt16((hex & 0xFF) * 257)
            )
        }
    }

    static func font(_ settings: AppSettings) -> NSFont {
        NSFont(name: settings.fontName, size: settings.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
