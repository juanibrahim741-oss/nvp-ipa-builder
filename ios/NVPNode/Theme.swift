import SwiftUI
import UIKit

/// Adaptive brand palette: clean **light** + **dark** (follows the system).
/// Same property names everywhere, so views adapt automatically.
enum Theme {
    static let bg = dynamic(light: 0xF5F7FB, dark: 0x0B1220)
    static let elev = dynamic(light: 0xFFFFFF, dark: 0x0F1B2E)
    static let elev2 = dynamic(light: 0xEEF2F8, dark: 0x13243B)
    static let border = dynamic(light: 0xE2E8F0, dark: 0x25324A)
    static let gold = dynamic(light: 0xB8862B, dark: 0xE9C46A)
    static let green = dynamic(light: 0x12A05E, dark: 0x3DDC97)
    static let red = dynamic(light: 0xD64545, dark: 0xFF6B6B)
    static let text = dynamic(light: 0x0B1220, dark: 0xE7ECF3)
    static let muted = dynamic(light: 0x5B6B82, dark: 0x9FB0C8)

    /// Accent fill that always pairs with dark text (buttons/pills).
    static let accent = dynamic(light: 0xE9C46A, dark: 0xE9C46A)
    static let onAccent = Color(red: 0.043, green: 0.071, blue: 0.125)

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
            .padding(16)
            .background(Theme.elev)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
