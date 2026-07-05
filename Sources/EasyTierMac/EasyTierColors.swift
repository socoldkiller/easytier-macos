import AppKit
import SwiftUI

enum EasyTierColors {
    static let statusConnected = Color(dynamicNSColor(
        light: NSColor(red: 0x34/255, green: 0xC7/255, blue: 0x59/255, alpha: 1),
        dark: NSColor(red: 0x30/255, green: 0xD1/255, blue: 0x58/255, alpha: 1),
        highContrastLight: NSColor(red: 0, green: 0xA0/255, blue: 0, alpha: 1),
        highContrastDark: NSColor(red: 0, green: 0xC8/255, blue: 0, alpha: 1)
    ))

    static let statusConnecting = Color(dynamicNSColor(
        light: NSColor(red: 1.0, green: 0x95/255, blue: 0, alpha: 1),
        dark: NSColor(red: 1.0, green: 0x9F/255, blue: 0x0A/255, alpha: 1),
        highContrastLight: NSColor(red: 0xE0/255, green: 0x80/255, blue: 0, alpha: 1),
        highContrastDark: NSColor(red: 1.0, green: 0x90/255, blue: 0, alpha: 1)
    ))

    static let statusError = Color(dynamicNSColor(
        light: NSColor(red: 1.0, green: 0x3B/255, blue: 0x30/255, alpha: 1),
        dark: NSColor(red: 1.0, green: 0x45/255, blue: 0x3A/255, alpha: 1),
        highContrastLight: NSColor(red: 0xD0/255, green: 0, blue: 0, alpha: 1),
        highContrastDark: NSColor(red: 1.0, green: 0, blue: 0, alpha: 1)
    ))

    static let metricUpload = Color(dynamicNSColor(
        light: NSColor(red: 0x3D/255, green: 0xBD/255, blue: 0x80/255, alpha: 1),
        dark: NSColor(red: 0x4D/255, green: 0xCF/255, blue: 0x90/255, alpha: 1),
        highContrastLight: NSColor(red: 0, green: 0xA0/255, blue: 0x40/255, alpha: 1),
        highContrastDark: NSColor(red: 0x10/255, green: 0xC0/255, blue: 0x50/255, alpha: 1)
    ))

    static let metricDownload = Color(dynamicNSColor(
        light: NSColor(red: 0x59/255, green: 0x91/255, blue: 0xF5/255, alpha: 1),
        dark: NSColor(red: 0x6D/255, green: 0xA5/255, blue: 1.0, alpha: 1),
        highContrastLight: NSColor(red: 0x10/255, green: 0x70/255, blue: 0xE0/255, alpha: 1),
        highContrastDark: NSColor(red: 0x30/255, green: 0x90/255, blue: 1.0, alpha: 1)
    ))

    static let menuBarSelectedRow = Color(dynamicNSColor(
        light: NSColor(red: 0x1A/255, green: 0x5E/255, blue: 0xC7/255, alpha: 1),
        dark: NSColor(red: 0x33/255, green: 0x80/255, blue: 0xE8/255, alpha: 1),
        highContrastLight: NSColor(red: 0, green: 0x40/255, blue: 0xD0/255, alpha: 1),
        highContrastDark: NSColor(red: 0x20/255, green: 0x80/255, blue: 1.0, alpha: 1)
    ))

    static let menuBarConnected = Color(dynamicNSColor(
        light: NSColor(red: 0x59/255, green: 0xC7/255, blue: 0x6B/255, alpha: 1),
        dark: NSColor(red: 0x66/255, green: 0xD8/255, blue: 0x78/255, alpha: 1),
        highContrastLight: NSColor(red: 0x10/255, green: 0xB0/255, blue: 0x30/255, alpha: 1),
        highContrastDark: NSColor(red: 0x20/255, green: 0xD0/255, blue: 0x40/255, alpha: 1)
    ))
}

private func dynamicNSColor(
    light: NSColor,
    dark: NSColor,
    highContrastLight: NSColor,
    highContrastDark: NSColor
) -> NSColor {
    NSColor(name: nil) { appearance in
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        if isDark {
            return isHighContrast ? highContrastDark : dark
        }
        return isHighContrast ? highContrastLight : light
    }
}

private extension Color {
    init(_ nsColor: NSColor) {
        self.init(nsColor: nsColor)
    }
}
