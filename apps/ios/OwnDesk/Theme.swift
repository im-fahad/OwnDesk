import SwiftUI
import UIKit

/// The Mac app's palette and type scale, so the iPhone looks like the same product rather than a
/// different one that happens to talk to it. The values are copied from Theme.swift in the Mac app,
/// as the Android app's Theme.kt copies them: one place decides what OwnDesk looks like.
enum Theme {
    static let header = Color(hex: 0x1B1B1B)
    static let sidebar = Color(hex: 0x181818)
    static let content = Color(hex: 0x1F1F1F)
    static let panel = Color(hex: 0x1A1A1A)
    static let status = Color(hex: 0x161616)
    static let border = Color(hex: 0x2E2E2E)

    static let text = Color(hex: 0xCCCCCC)
    static let textDim = Color(hex: 0x8B8B8B)
    static let textFaint = Color(hex: 0x6A6A6A)

    static let accent = Color(hex: 0x4D8EF7)
    static let online = Color(hex: 0x3FB950)
    static let warn = Color(hex: 0xD29922)
    static let danger = Color(hex: 0xF85149)

    // Sizes follow the Mac's chrome: 13 for primary text, 12 secondary, 11 for status and
    // fingerprints, 10 for section headings.
    static let ui: CGFloat = 13
    static let uiSecondary: CGFloat = 12
    static let uiSmall: CGFloat = 11
    static let section: CGFloat = 10
    static let title: CGFloat = 15
    static let fingerprint: CGFloat = 17
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// A section heading in the Mac's style: small, bold, spaced capitals.
struct SectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: Theme.section, weight: .bold))
            .kerning(1)
            .foregroundStyle(Theme.textFaint)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one filled button: the action a screen exists for.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.uiSecondary, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
