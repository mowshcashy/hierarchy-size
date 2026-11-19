import AppKit
import SwiftUI

/// Editorial look: paper and ink, a serif display face (New York), mono labels, one terracotta accent.
enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let paper = dynamic(light: 0xF5F0E6, dark: 0x14120F)
    static let paper2 = dynamic(light: 0xEDE6D8, dark: 0x1C1915)
    static let ink = dynamic(light: 0x16130F, dark: 0xEFE8DA)
    static let ink2 = dynamic(light: 0x4A443B, dark: 0xC9C0B0)
    static let ink3 = dynamic(light: 0x857C6E, dark: 0x8E8576)
    static let accent = dynamic(light: 0xC2410C, dark: 0xF08A4B)
    static var hair: Color { ink.opacity(0.18) }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static let body = Font.system(size: 14, design: .serif)
    static let label = Font.system(size: 10.5, weight: .medium, design: .monospaced)
}

extension View {
    /// Small uppercase monospaced label, like a magazine kicker.
    func kicker(_ color: Color = Theme.ink3) -> some View {
        self.font(Theme.label).tracking(1.4).textCase(.uppercase).foregroundStyle(color)
    }
}

/// Thick rule over a hairline: the masthead divider.
struct MastheadRule: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Theme.ink).frame(height: 2.5)
            Rectangle().fill(Theme.ink).frame(height: 0.75)
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hair).frame(height: 1) }
}

/// Ink-black button with mono uppercase text.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(configuration.isPressed ? Theme.accent : Theme.ink)
            .contentShape(Rectangle())
    }
}
