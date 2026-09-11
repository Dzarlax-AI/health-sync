import SwiftUI

enum TabSelection: Hashable {
    case today, sleep, trends, metrics, settings
}

struct ContentView: View {
    @State private var selection: TabSelection = .today
    @AppStorage("health-sync.config-revision") private var configRevision = 0

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max", value: TabSelection.today) {
                TodayView(selection: $selection)
                    .id("today-\(configRevision)")
            }
            Tab("Sleep", systemImage: "moon.zzz", value: TabSelection.sleep) {
                SleepView()
                    .id("sleep-\(configRevision)")
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: TabSelection.trends) {
                TrendsView()
                    .id("trends-\(configRevision)")
            }
            Tab("Metrics", systemImage: "list.bullet", value: TabSelection.metrics) {
                MetricsView()
                    .id("metrics-\(configRevision)")
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
