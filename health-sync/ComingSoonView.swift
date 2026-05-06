import SwiftUI

struct ComingSoonView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: .dsSpacing) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.dsTextTertiary)
            Text(title)
                .font(.dsHeading)
                .foregroundStyle(Color.dsText)
            Text(message)
                .font(.dsBodySm)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, .dsSpacingLg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
    }
}
