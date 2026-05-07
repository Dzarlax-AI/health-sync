import SwiftUI
import UIKit

// MARK: - Hex parsing

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((int >> 24) & 0xFF) / 255
            g = CGFloat((int >> 16) & 0xFF) / 255
            b = CGFloat((int >> 8)  & 0xFF) / 255
            a = CGFloat( int        & 0xFF) / 255
        } else {
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8)  & 0xFF) / 255
            b = CGFloat( int        & 0xFF) / 255
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

// MARK: - Dynamic color helper

private func dsDynamic(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    })
}

private func dsDynamic(lightHex: String, darkHex: String) -> Color {
    dsDynamic(light: UIColor(hex: lightHex), dark: UIColor(hex: darkHex))
}

// MARK: - Colors (mirror of dzarlax design-system tokens, light + dark)

extension Color {
    // Backgrounds
    static let dsBackground = dsDynamic(lightHex: "#FCFAF7", darkHex: "#1A1D21")
    static let dsSurface    = dsDynamic(lightHex: "#FFFFFF", darkHex: "#22252A")
    static let dsSurface2   = dsDynamic(lightHex: "#E8E6E3", darkHex: "#2A2D32")
    // Elevated surface — for sheets, popovers, layered cards over dsSurface
    static let dsSurface3   = dsDynamic(lightHex: "#DCDAD7", darkHex: "#33363B")

    // Text
    static let dsText = dsDynamic(lightHex: "#1A1A1E", darkHex: "#F5F5F5")
    static let dsTextSecondary = dsDynamic(
        light: UIColor(hex: "#1A1A1E").withAlphaComponent(0.7),
        dark:  UIColor(hex: "#F5F5F5").withAlphaComponent(0.7)
    )
    static let dsTextTertiary = dsDynamic(
        light: UIColor(hex: "#1A1A1E").withAlphaComponent(0.5),
        dark:  UIColor(hex: "#F5F5F5").withAlphaComponent(0.5)
    )

    // Accent — graphite on light, off-white on dark (CSS --accent inverted)
    static let dsAccent = dsDynamic(lightHex: "#18181B", darkHex: "#F5F5F5")
    // Foreground that reads on dsAccent (i.e. inverse of accent)
    static let dsAccentForeground = dsDynamic(lightHex: "#FFFFFF", darkHex: "#1A1A1E")

    // Borders
    static let dsBorder = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.08),
        dark:  UIColor.white.withAlphaComponent(0.08)
    )
    static let dsBorderHover = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.12),
        dark:  UIColor.white.withAlphaComponent(0.12)
    )

    // Status — foreground brightened on dark for readability;
    // bg uses translucent tint on dark to avoid neon pastels.
    static let dsGood = dsDynamic(lightHex: "#16a34a", darkHex: "#22c55e")
    static let dsGoodBg = dsDynamic(
        light: UIColor(hex: "#f0fdf4"),
        dark:  UIColor(red: 22/255, green: 163/255, blue: 74/255, alpha: 0.15)
    )
    static let dsWarn = dsDynamic(lightHex: "#d97706", darkHex: "#f59e0b")
    static let dsWarnBg = dsDynamic(
        light: UIColor(hex: "#fffbeb"),
        dark:  UIColor(red: 217/255, green: 119/255, blue: 6/255, alpha: 0.15)
    )
    static let dsDanger = dsDynamic(lightHex: "#dc2626", darkHex: "#ef4444")
    static let dsDangerBg = dsDynamic(
        light: UIColor(hex: "#fef2f2"),
        dark:  UIColor(red: 220/255, green: 38/255, blue: 38/255, alpha: 0.15)
    )

    // Health categories — slightly brightened on dark so they read on #1A1D21
    static let dsHeart    = dsDynamic(lightHex: "#e11d48", darkHex: "#fb7185")
    static let dsActivity = dsDynamic(lightHex: "#059669", darkHex: "#34d399")
    static let dsSleep    = dsDynamic(lightHex: "#7c3aed", darkHex: "#a78bfa")
    static let dsCardio   = dsDynamic(lightHex: "#0284c7", darkHex: "#38bdf8")
}

// MARK: - Typography

extension Font {
    // Headings — Georgia serif
    static let dsTitle    = Font.custom("Georgia", size: 28).weight(.regular)
    static let dsHeading  = Font.custom("Georgia", size: 20).weight(.regular)
    static let dsSubhead  = Font.custom("Georgia", size: 17).weight(.regular)

    // Body — SF Pro (system)
    static let dsBody     = Font.system(size: 16)
    static let dsBodySm   = Font.system(size: 14)
    static let dsCaption  = Font.system(size: 12)
    static let dsMono     = Font.system(size: 13, design: .monospaced)
}

// MARK: - Radius & Spacing

extension CGFloat {
    static let dsRadius: CGFloat   = 8
    static let dsRadiusLg: CGFloat = 12
    static let dsSpacingXs: CGFloat = 4
    static let dsSpacingSm: CGFloat = 8
    static let dsSpacing: CGFloat   = 16
    static let dsSpacingLg: CGFloat = 24
    static let dsSpacingXl: CGFloat = 32
}

// MARK: - Card modifier

struct DSCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: .dsRadius))
            .overlay(
                RoundedRectangle(cornerRadius: .dsRadius)
                    .stroke(Color.dsBorder, lineWidth: 1)
            )
    }
}

extension View {
    func dsCard() -> some View {
        modifier(DSCard())
    }
}

// MARK: - Status badge

struct DSStatusBadge: View {
    enum Status { case good, warn, danger, neutral }

    let text: LocalizedStringKey
    let status: Status

    var body: some View {
        Text(text)
            .font(.dsCaption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bgColor)
            .foregroundStyle(fgColor)
            .clipShape(Capsule())
    }

    private var bgColor: Color {
        switch status {
        case .good:    return .dsGoodBg
        case .warn:    return .dsWarnBg
        case .danger:  return .dsDangerBg
        case .neutral: return .dsSurface2
        }
    }

    private var fgColor: Color {
        switch status {
        case .good:    return .dsGood
        case .warn:    return .dsWarn
        case .danger:  return .dsDanger
        case .neutral: return .dsTextSecondary
        }
    }
}

// MARK: - Primary button style

struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsBody.weight(.medium))
            .foregroundStyle(Color.dsAccentForeground)
            .padding(.horizontal, .dsSpacingLg)
            .padding(.vertical, 12)
            .background(Color.dsAccent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: .dsRadius))
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsBody.weight(.medium))
            .foregroundStyle(Color.dsAccent.opacity(configuration.isPressed ? 0.5 : 1))
            .padding(.horizontal, .dsSpacingLg)
            .padding(.vertical, 12)
            .background(Color.dsSurface2.opacity(configuration.isPressed ? 0.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: .dsRadius))
    }
}
