import SwiftUI

enum TabSelection: Hashable {
    case today, sleep, trends, metrics, settings
}

struct ContentView: View {
    @State private var selection: TabSelection = .today

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max", value: TabSelection.today) {
                TodayView(selection: $selection)
            }
            Tab("Sleep", systemImage: "moon.zzz", value: TabSelection.sleep) {
                SleepView()
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: TabSelection.trends) {
                TrendsView()
            }
            Tab("Metrics", systemImage: "list.bullet", value: TabSelection.metrics) {
                MetricsView()
            }
            Tab("Settings", systemImage: "gearshape", value: TabSelection.settings) {
                SettingsView()
            }
        }
        .tint(.dsAccent)
    }
}

#Preview {
    ContentView()
}
