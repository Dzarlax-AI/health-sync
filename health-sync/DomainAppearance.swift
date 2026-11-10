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
        case .sleep: .dsHorizonSleepStart
        case .recovery: .dsHorizonRecoveryStart
        case .energy: .dsHorizonEnergyStart
        case .activity: .dsHorizonActivityStart
        case .cardio: .dsHorizonCardioStart
        }
    }

    var ringColors: [Color] {
        switch self {
        case .sleep: [.dsHorizonSleepStart, .dsHorizonSleepEnd]
        case .recovery: [.dsHorizonRecoveryStart, .dsHorizonRecoveryEnd]
        case .energy: [.dsHorizonEnergyStart, .dsHorizonEnergyEnd]
        case .activity: [.dsHorizonActivityStart, .dsHorizonActivityEnd]
        case .cardio: [.dsHorizonCardioStart, .dsHorizonCardioEnd]
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
    var body: some View {
        ZStack(alignment: .top) {
            Color.dsHorizonBackground
            DomainLandscape(appearance: appearance)
                .frame(height: 550)
        }
        .ignoresSafeArea()
    }
}

/// Asset appearance and semantic veils adapt together to the system theme.
struct DomainLandscape: View {
    let appearance: DomainAppearance
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            Image(appearance.imageName).resizable().scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                .overlay(Color.dsHorizonVeil)
                .overlay(Color.dsHorizonBackground.opacity(contrast == .increased ? 0.65 : 0))
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .dsHorizonBackground.opacity(0), location: 0),
                        .init(color: .dsHorizonBackground.opacity(0.10), location: 0.38),
                        .init(color: .dsHorizonBackground, location: 1)
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
    }
}

struct DomainSurface: ViewModifier {
    let appearance: DomainAppearance
    func body(content: Content) -> some View {
        content.horizonSurface()
    }
}

extension View {
    /// Keep foreground below the system inset. The stationary page backdrop
    /// spans the whole window, avoiding a second, discontinuous landscape crop.
    func domainScrollViewport(_ appearance: DomainAppearance) -> some View {
        clipped()
    }

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
                .foregroundStyle(Color.dsHorizonText)
            if let date, let parsed = try? Date(date, strategy: .iso8601.year().month().day()) {
                Text(parsed, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.dsBodySm).foregroundStyle(Color.dsHorizonText)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(label).font(.callout).fixedSize()
                        Spacer(minLength: 0)
                        accessibleValue.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(.callout).fixedSize(horizontal: false, vertical: true)
                        accessibleValue
                    }
                }
                .foregroundStyle(Color.dsHorizonText)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ring
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var accessibleValue: some View {
        Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }

    private var ring: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.dsHorizonGaugeCenter.opacity(0.94))
                Circle().stroke(Color.dsHorizonGaugeTrack, lineWidth: size * 0.055)
                    .padding(size * 0.04)
                if let fraction, fraction.isFinite, fraction > 0 {
                    Circle().trim(from: 0, to: min(1, fraction))
                        .stroke(AngularGradient(colors: appearance.ringColors.reversed(),
                                                center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                                style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(size * 0.04)
                        .shadow(color: .dsHorizonGaugeGlow, radius: 5)
                }
                VStack(spacing: 2) {
                    Text(value).font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(Color.dsHorizonText)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if showsCaption && compact {
                        Text(label).font(.caption2.weight(.medium))
                            .foregroundStyle(Color.dsHorizonTextSecondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, size * 0.15)
            }
            .frame(width: size, height: size)
            if showsCaption && !compact {
                Text(label).font(.body).foregroundStyle(Color.dsHorizonText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .font(.dsCaption).foregroundStyle(Color.dsHorizonTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(appearance.accent.opacity(0.07))
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.dsHorizonText).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let note, !note.isEmpty {
                    Text(note).font(.dsCaption).foregroundStyle(Color.dsHorizonTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .horizonSurface(cornerRadius: 18)
    }
}
