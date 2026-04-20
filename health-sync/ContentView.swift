import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Status", systemImage: "arrow.trianglehead.2.clockwise") {
                StatusView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tint(.dsAccent)
    }
}

#Preview {
    ContentView()
}
