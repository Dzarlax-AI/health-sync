import SwiftUI

// MARK: - Colors

extension Color {
    // Backgrounds
    static let dsBackground  = Color(hex: "#FCFAF7")
    static let dsSurface     = Color(hex: "#FFFFFF")
    static let dsSurface2    = Color(hex: "#E8E6E3")

    // Text
    static let dsText            = Color(hex: "#1A1A1E")
    static let dsTextSecondary   = Color(hex: "#1A1A1E").opacity(0.7)
    static let dsTextTertiary    = Color(hex: "#1A1A1E").opacity(0.5)

    // Accent
    static let dsAccent      = Color(hex: "#18181B")

    // Borders
    static let dsBorder      = Color.black.opacity(0.08)
    static let dsBorderHover = Color.black.opacity(0.12)

    // Status
    static let dsGood        = Color(hex: "#16a34a")
    static let dsGoodBg      = Color(hex: "#f0fdf4")
    static let dsWarn        = Color(hex: "#d97706")
    static let dsWarnBg      = Color(hex: "#fffbeb")
    static let dsDanger      = Color(hex: "#dc2626")
    static let dsDangerBg    = Color(hex: "#fef2f2")

    // Health categories
    static let dsHeart       = Color(hex: "#e11d48")
    static let dsActivity    = Color(hex: "#059669")
    static let dsSleep       = Color(hex: "#7c3aed")
    static let dsCardio      = Color(hex: "#0284c7")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
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
            .foregroundStyle(Color.white)
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
