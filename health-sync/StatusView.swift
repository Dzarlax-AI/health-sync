import SwiftUI

/// Compatibility entry point for existing Settings navigation. The detailed
/// status presentation now lives in SyncStatusView so all entry points share
/// the same typed delivery state and action rules.
struct StatusView: View {
    var body: some View {
        SyncStatusView()
    }
}

#Preview {
    StatusView()
}
