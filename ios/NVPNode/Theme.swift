import SwiftUI
import UIKit

/// Adaptive brand palette: clean **light** + **dark** (follows the system).
/// Same property names everywhere, so views adapt automatically.
enum Theme {
    // Fintech identity: deep teal surfaces + lime/chartreuse accent.
    static let bg = dynamic(light: 0xF4F7F2, dark: 0x0E1F1A)
    static let elev = dynamic(light: 0xFFFFFF, dark: 0x14342B)
    static let elev2 = dynamic(light: 0xEDF2EC, dark: 0x1C4A3B)
    static let border = dynamic(light: 0xE4EAE2, dark: 0x255043)
    static let green = dynamic(light: 0x12A05E, dark: 0x4FE0A0)
    static let red = dynamic(light: 0xD64545, dark: 0xFF6B6B)
    static let text = dynamic(light: 0x10231C, dark: 0xEAF3EE)
    static let muted = dynamic(light: 0x5C7268, dark: 0x9DB8AC)

    /// Brand accent for headings / highlights (teal on light, lime on dark).
    static let gold = dynamic(light: 0x0F7A55, dark: 0xC9F24E)
    /// Primary action fill — signature lime, always with dark text.
    static let accent = dynamic(light: 0xC9F24E, dark: 0xC9F24E)
    static let onAccent = Color(red: 0.055, green: 0.13, blue: 0.106) // deep teal
    /// Deep-teal "feature" surface (balance / hero cards in the design).
    static let teal = dynamic(light: 0x143A32, dark: 0x0B2A22)
    static let onTeal = Color(red: 0.91, green: 0.95, blue: 0.93)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light)
        })
    }

    private static func uiColor(_ hex: Int) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension View {
    /// Standard elevated card styling (adapts to light/dark).
    func card() -> some View {
        self
            .padding(18)
            .background(Theme.elev)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
