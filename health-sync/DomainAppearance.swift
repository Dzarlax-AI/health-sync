import SwiftUI

/// Presentation only: domain colors never determine health status or scores.
enum DomainAppearance {
    case sleep, recovery, energy, cardio, activity

    init(key: String) {
        switch key {
        case "sleep": self = .sleep
        case "energy": self = .energy
        case "cardio": self = .cardio
        case "activity": self = .activity
        default: self = .recovery
        }
    }

    var accent: Color {
        switch self {
        case .sleep: .dsSleep
        case .recovery: .dsRecovery
        case .energy: .dsWarn
        case .activity: .dsActivity
        case .cardio: .dsHeart
        }
    }

    var ringColors: [Color] {
        switch self {
        case .sleep: [.dsRingSleepStart, .dsRingSleepEnd]
        case .recovery: [.dsRingRecoveryStart, .dsRingRecoveryEnd]
        case .energy: [.dsRingEnergyStart, .dsRingEnergyEnd]
        case .activity: [.dsRingActivityStart, .dsRingActivityEnd]
        case .cardio: [.dsRingCardioStart, .dsRingCardioEnd]
        }
    }

    var imageName: String {
        switch self {
        case .sleep, .cardio: "DomainNightHero"
        default: "TodayMorningHero"
        }
    }

    var icon: String {
        switch self {
        case .sleep: "moon.stars.fill"
        case .recovery: "heart.circle.fill"
        case .energy: "bolt.fill"
        case .activity: "figure.walk"
        case .cardio: "heart.fill"
        }
    }
}

struct DomainBackdrop: View {
    let appearance: DomainAppearance
    var body: some View { Color.dsDashboardBackground.ignoresSafeArea() }
}

/// The image stays dark in both themes. Only its bottom edge fades into the page.
struct DomainLandscape: View {
    let appearance: DomainAppearance
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            Image(appearance.imageName).resizable().scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                .overlay(Color.dsRingGroove.opacity(contrast == .increased ? 0.70 : 0.54))
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .dsRingGroove.opacity(0.45), location: 0),
                        .init(color: .dsRingGroove.opacity(0), location: 0.70),
                        .init(color: .dsDashboardBackground, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DomainHeroSurface: ViewModifier {
    let appearance: DomainAppearance
    func body(content: Content) -> some View {
        content
            .padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    DomainLandscape(appearance: appearance)
                        .frame(width: proxy.size.width + 32, height: proxy.size.height + 230)
                        .offset(x: -16, y: -130)
                }
            }
    }
}

struct DomainSurface: ViewModifier {
    let appearance: DomainAppearance
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(contrast == .increased ? Color.dsTextSecondary : .dsBorder, lineWidth: 1))
    }
}

extension View {
    func domainSurface(_ appearance: DomainAppearance) -> some View {
        modifier(DomainSurface(appearance: appearance))
    }
    func domainHero(_ appearance: DomainAppearance) -> some View {
        modifier(DomainHeroSurface(appearance: appearance))
    }
}

struct DomainPageHeader: View {
    let title: String
    var date: String?
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(.title, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.dsRingText)
            if let date, let parsed = try? Date(date, strategy: .iso8601.year().month().day()) {
                Text(parsed, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.dsBodySm).foregroundStyle(Color.dsRingText)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// The raw value is never clamped; only the arc is bounded to its track.
struct DomainGauge: View {
    let value: String
    let label: LocalizedStringKey
    let fraction: Double?
    let appearance: DomainAppearance
    var size: CGFloat = 178
    var compact = false
    var showsCaption = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.dsRingShellLight, .dsRingShellMid, .dsRingShellDark],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(Color.dsRingHighlight.opacity(0.65), lineWidth: 1))
                    .shadow(color: .dsRingGroove.opacity(0.4), radius: 10, y: 6)
                Circle().fill(Color.dsRingShellDark).padding(size * 0.11)
                Circle().stroke(LinearGradient(colors: [.dsRingGroove, .dsRingHighlight.opacity(0.55)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: size * 0.066)
                    .padding(size * 0.075)
                if let fraction, fraction.isFinite, fraction > 0 {
                    Circle().trim(from: 0, to: min(1, fraction))
                        .stroke(AngularGradient(colors: appearance.ringColors.reversed(),
                                                center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                                style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(size * 0.075)
                }
                VStack(spacing: 2) {
                    Text(value).font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Color.dsRingText)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if showsCaption && !dynamicTypeSize.isAccessibilitySize {
                        Text(label).font(.system(size: compact ? 10 : 12, weight: .medium))
                            .foregroundStyle(Color.dsRingTextSecondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, size * 0.22)
            }
            .frame(width: size, height: size)
            if showsCaption && dynamicTypeSize.isAccessibilitySize {
                Text(label).font(.dsCaption).foregroundStyle(Color.dsRingText)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct DomainValueCard: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let appearance: DomainAppearance
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(appearance.accent.opacity(0.07))
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.dsText).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let note, !note.isEmpty {
                    Text(note).font(.dsCaption).foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dsBorder, lineWidth: 1))
    }
}
