import SwiftUI

/// Keep complete stage names together as the available width and text size change.
struct SleepStageLegend: View {
    let hasUnspecified: Bool
    var nightStyle = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .leading), count: dynamicTypeSize >= .xxxLarge ? 1 : 2),
                  alignment: .leading, spacing: .dsSpacingSm) {
            item("Deep", color: .dsSleep)
            item("Core", color: .dsSleepStageCore)
            item("REM", color: .dsCardio)
            if hasUnspecified { item("Asleep", color: .dsSleepUnspecified) }
            item("Awake", color: .dsSleepStageAwake)
        }
    }

    private func item(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(LocalizedStringKey(label))
                .font(.dsCaption)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(nightStyle ? Color.dsSleepNightTextSecondary : Color.dsTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stage-legend-\(label)")
    }
}
