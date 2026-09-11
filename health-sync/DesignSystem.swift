import SwiftUI
import UIKit
import Charts

// MARK: - Hex parsing

extension UIColor {
    /// Parse a hex color string. Accepts only 6-char (RRGGBB) or 8-char
    /// (RRGGBBAA) hex; CSS shorthand (3-char #RGB) and other lengths fail
    /// fast in DEBUG builds and fall through to opaque black in Release so
    /// a typo doesn't crash users in the wild. Leading `#` and other
    /// non-alphanumerics are stripped before validation.
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6 || hex.count == 8 else {
            assertionFailure("UIColor(hex:) requires 6- or 8-char hex; got \(hex.count) chars: \"\(hex)\"")
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
            return
        }
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

    // Controls — intentionally separate from accent foreground: metric toggles
    // stay legible on saturated colors, while neutral toggles invert on accent.
    static let dsControlThumb = dsDynamic(lightHex: "#FFFFFF", darkHex: "#F5F5F5")
    static let dsControlThumbShadow = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.15),
        dark: UIColor.black.withAlphaComponent(0.28)
    )

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
    /// Primary score colour for the light, scenic Today surface.
    static let dsReadiness = dsDynamic(lightHex: "#5B5AC8", darkHex: "#AAA7FF")
    // Intentionally night-specific surfaces for the Sleep experience.
    static let dsSleepNightBackground = dsDynamic(lightHex: "#071126", darkHex: "#071126")
    static let dsSleepNightTop = dsDynamic(lightHex: "#13265A", darkHex: "#13265A")
    static let dsSleepNightSurface = dsDynamic(lightHex: "#142244", darkHex: "#142244")
    static let dsSleepNightBorder = dsDynamic(
        light: UIColor.white.withAlphaComponent(0.12),
        dark: UIColor.white.withAlphaComponent(0.12)
    )
    static let dsSleepNightText = dsDynamic(lightHex: "#F4F6FF", darkHex: "#F4F6FF")
    static let dsSleepNightTextSecondary = dsDynamic(
        light: UIColor(hex: "#F4F6FF").withAlphaComponent(0.68),
        dark: UIColor(hex: "#F4F6FF").withAlphaComponent(0.68)
    )
    static let dsCardio   = dsDynamic(lightHex: "#0284c7", darkHex: "#38bdf8")
    // Chart band for `sleep_unspecified` — coarse asleep time from sources
    // without stage tracking. Neutral grey-blue, deliberately muted so it
    // reads as "not classified" next to the saturated stage colours.
    // Mirrors `#9ba3b0` from health_dashboard PR #74.
    static let dsSleepUnspecified = dsDynamic(lightHex: "#9ba3b0", darkHex: "#5b6378")
    /// Fixed sleep-stage hues. They must not inherit the page accent: a stage
    /// keeps the same meaning in the nightly structure and historical chart.
    static let dsSleepStageCore = dsDynamic(lightHex: "#AFA6F4", darkHex: "#AFA6F4")
    static let dsSleepStageAwake = dsDynamic(lightHex: "#F2B45B", darkHex: "#F2B45B")
}

// MARK: - Typography

extension Font {
    // Headings — system serif text styles keep the visual language while
    // allowing Dynamic Type to scale the hierarchy.
    static let dsTitle    = Font.system(.largeTitle, design: .serif)
    static let dsHeading  = Font.system(.title2, design: .serif)
    static let dsSubhead  = Font.system(.headline, design: .serif)

    // Body — SF Pro text styles, scaled by the user's accessibility setting.
    static let dsBody     = Font.system(.body)
    static let dsBodySm   = Font.system(.callout)
    static let dsCaption  = Font.system(.footnote)
    static let dsMono     = Font.system(.footnote, design: .monospaced)
}

// MARK: - Radius & Spacing

extension CGFloat {
    static let dsRadius: CGFloat   = 8
    static let dsRadiusLg: CGFloat = 12
    /// Large, calm corners for primary Bevel surfaces such as the Today hero.
    static let dsRadiusHero: CGFloat = 28
    /// Rounded corners for cards that sit above the page surface.
    static let dsRadiusElevatedCard: CGFloat = 20
    /// Soft shadow blur for a card raised one level above its parent surface.
    static let dsElevationCard: CGFloat = 10
    /// Slightly stronger shadow blur for a primary hero surface.
    static let dsElevationHero: CGFloat = 18
    static let dsElevationOffset: CGFloat = 6
    static let dsSpacingXs: CGFloat = 4
    static let dsSpacingSm: CGFloat = 8
    static let dsSpacing: CGFloat   = 16
    static let dsSpacingLg: CGFloat = 24
    static let dsSpacingXl: CGFloat = 32
    /// iOS 26's floating tab bar intentionally overlays scroll content. Keep
    /// the final row/action above it rather than relying on the system fade.
    static let dsTabBarClearance: CGFloat = 76
}

// MARK: - Quiet Bevel

extension Color {
    /// Opaque base and highlight for the gradient-only hero fallback.
    static let dsHeroSurface = dsDynamic(lightHex: "#5965D9", darkHex: "#303B8C")
    static let dsHeroHighlight = dsDynamic(lightHex: "#95A2EE", darkHex: "#5869BD")

    /// Use these for text that appears over `DSHeroVeil`, including an image-backed hero.
    static let dsHeroForeground = dsDynamic(lightHex: "#FFFFFF", darkHex: "#F8F8FC")
    static let dsHeroForegroundSecondary = dsDynamic(
        light: UIColor.white.withAlphaComponent(0.78),
        dark: UIColor.white.withAlphaComponent(0.76)
    )

    /// A dark adaptive veil keeps hero content readable over either a gradient or future scenery.
    static let dsHeroVeil = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.24),
        dark: UIColor.black.withAlphaComponent(0.38)
    )
    static let dsHeroVeilStrong = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.60),
        dark: UIColor.black.withAlphaComponent(0.70)
    )

    static let dsElevatedSurface = dsDynamic(lightHex: "#FFFFFF", darkHex: "#292D34")
    static let dsElevatedBorder = dsDynamic(
        light: UIColor.white.withAlphaComponent(0.72),
        dark: UIColor.white.withAlphaComponent(0.12)
    )
    static let dsElevatedShadow = dsDynamic(
        light: UIColor.black.withAlphaComponent(0.14),
        dark: UIColor.black.withAlphaComponent(0.32)
    )
}

/// Selects the backing treatment for a Quiet Bevel hero.
/// Use `.scenic` only when the caller already provides an image or other decorative backing.
enum DSHeroBackdrop {
    case gradient
    case scenic
}

/// The gradient-only fallback for a primary hero. It intentionally needs no image asset.
struct DSHeroGradient: View {
    var body: some View {
        LinearGradient(
            colors: [.dsHeroHighlight, .dsHeroSurface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Apply above a scenic backing to preserve contrast before placing hero content on top.
struct DSHeroVeil: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.dsHeroVeil, .dsHeroVeilStrong],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle()
                .fill(.thinMaterial)
                .opacity(0.18)
        }
    }
}

/// A light wash for the selected scenic Today direction. Unlike `DSHeroVeil`,
/// it preserves the morning scene and keeps dark score text legible.
struct DSMorningHeroVeil: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.dsSurface.opacity(0.10),
                Color.dsSurface.opacity(0.42),
                Color.dsSurface.opacity(0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Styles a primary hero. The default is self-contained and gradient-only;
/// `.scenic` retains an already-supplied backdrop while adding the same safe veil.
struct DSHeroContainer: ViewModifier {
    let backdrop: DSHeroBackdrop

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.dsHeroForeground)
            .background {
                ZStack {
                    if backdrop == .gradient {
                        DSHeroGradient()
                    }
                    DSHeroVeil()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: .dsRadiusHero, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: .dsRadiusHero, style: .continuous)
                    .stroke(Color.dsElevatedBorder, lineWidth: 1)
            }
            .shadow(color: .dsElevatedShadow, radius: .dsElevationHero, y: .dsElevationOffset)
    }
}

/// The standard material card for narrative and supporting content that deserves elevation.
/// Keep `dsCard()` for regular, flat dashboard cards.
struct DSElevatedCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsElevatedSurface)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: .dsRadiusElevatedCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: .dsRadiusElevatedCard, style: .continuous)
                    .stroke(Color.dsElevatedBorder, lineWidth: 1)
            }
            .shadow(color: .dsElevatedShadow, radius: .dsElevationCard, y: .dsElevationOffset)
    }
}

extension View {
    /// Wrap readiness/headline content in the primary Quiet Bevel hero treatment.
    func dsHeroContainer(backdrop: DSHeroBackdrop = .gradient) -> some View {
        modifier(DSHeroContainer(backdrop: backdrop))
    }

    /// Raises a card above its parent surface with a restrained material and shadow.
    func dsElevatedCard() -> some View {
        modifier(DSElevatedCard())
    }

    /// Applies a metric-aware domain only when the chart policy supplies one.
    @ViewBuilder
    func dsChartYScale(domain: ClosedRange<Double>?) -> some View {
        if let domain {
            chartYScale(domain: domain)
        } else {
            self
        }
    }
}

/// One scaling policy for dashboard line charts. It avoids a misleading zero
/// baseline for a stable biomarker, but retains zero for accumulated values
/// such as steps and calories. The bounds are always shown on the chart, so a
/// compact scale never hides its actual magnitude.
enum DashboardChartScale {
    static func domain(for metric: String, values: [Double], isBar: Bool) -> ClosedRange<Double>? {
        guard !isBar, let minimum = values.min(), let maximum = values.max() else { return nil }

        // Saturation is expressed as a percentage and is clinically read on
        // this conventional band; a zero baseline makes 94–98% unreadable.
        if metric == "blood_oxygen_saturation" {
            return 80...100
        }

        let magnitude = max(abs(minimum), abs(maximum), 1)
        let observedSpan = maximum - minimum
        let targetSpan = max(observedSpan * 1.4, magnitude * 0.08)
        let step = niceStep(for: targetSpan / 4)
        var lower = floor((minimum - (targetSpan - observedSpan) / 2) / step) * step
        var upper = ceil((maximum + (targetSpan - observedSpan) / 2) / step) * step

        if lower == upper {
            lower -= step * 2
            upper += step * 2
        }
        if minimum >= 0 {
            lower = max(0, lower)
        }
        return lower...upper
    }

    private static func niceStep(for value: Double) -> Double {
        let base = pow(10, floor(log10(max(value, 0.000_001))))
        let normalized = value / base
        let multiplier: Double
        switch normalized {
        case ...1: multiplier = 1
        case ...2: multiplier = 2
        case ...5: multiplier = 5
        default: multiplier = 10
        }
        return multiplier * base
    }
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

/// A consistent quiet container for analytical details. It has the same
/// generous radius as dashboard surfaces, but no material/shadow competition
/// with the data drawn inside it.
struct DSDetailCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: .dsRadiusElevatedCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: .dsRadiusElevatedCard, style: .continuous)
                    .stroke(Color.dsBorder, lineWidth: 1)
            }
    }
}

extension View {
    func dsCard() -> some View {
        modifier(DSCard())
    }

    func dsDetailCard() -> some View {
        modifier(DSDetailCard())
    }
}

// MARK: - Status badge

struct DSStatusBadge: View {
    enum Status { case good, warn, danger, neutral }

    /// Pre-built `Text` so callers can choose between iOS chrome
    /// localization (`Text("Some Key")` — looks up in xcstrings) and
    /// server-provided verbatim text (`Text(verbatim: serverLabel)` —
    /// rendered as-is). The two `init`s below cover both call sites
    /// without forcing callers to construct `Text` explicitly.
    private let text: Text
    let status: Status

    /// Localized via xcstrings. Use for iOS-side chrome strings.
    init(text: LocalizedStringKey, status: Status) {
        self.text = Text(text)
        self.status = status
    }

    /// Verbatim — server already localized the string per `report_lang`,
    /// so a second xcstrings lookup would re-translate it into the iOS
    /// UI locale and violate the content/chrome split (Codex review on
    /// PR #12).
    init(verbatim: String, status: Status) {
        self.text = Text(verbatim: verbatim)
        self.status = status
    }

    var body: some View {
        text
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
