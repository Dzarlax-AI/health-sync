import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("backgroundSync") private var backgroundSync = true
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true
    @AppStorage("syncVitals") private var syncVitals = true
    @AppStorage("syncActivity") private var syncActivity = true
    @AppStorage("syncSleep") private var syncSleep = true
    @AppStorage("syncWorkouts") private var syncWorkouts = true
    @AppStorage("workoutHRTimeline") private var workoutHRTimeline = true
    @AppStorage("workoutGPS") private var workoutGPS = false

    @State private var apiKey = KeychainStore.apiKey ?? ""
    @State private var connectionState: ConnectionState = .idle

    enum ConnectionState {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: .dsSpacingLg) {
                    serverSection
                    syncSection
                    metricsSection
                    workoutsSection
                }
                .padding(.dsSpacing)
            }
            .background(Color.dsBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Server")

            VStack(spacing: .dsSpacingSm) {
                DSTextField(label: "URL", placeholder: "https://health.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                DSSecureField(label: "API Key", placeholder: "your-secret-key", text: $apiKey)
                    .onChange(of: apiKey) { _, new in KeychainStore.apiKey = new }

                HStack {
                    Button(action: testConnection) {
                        Label("Test Connection", systemImage: "network")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())

                    Spacer()

                    connectionBadge
                }
                .padding(.top, .dsSpacingXs)
            }
        }
        .dsCard()
        .padding(.horizontal, 0)
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Sync")

            VStack(spacing: 0) {
                DSToggleRow(label: "Background sync", isOn: $backgroundSync)
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(label: "Sync on launch", isOn: $syncOnLaunch)
            }
        }
        .dsCard()
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Metrics")

            VStack(spacing: 0) {
                DSToggleRow(
                    label: "Heart rate, HRV, SpO₂…",
                    subtitle: "Vitals — minutely samples",
                    color: .dsHeart,
                    isOn: $syncVitals
                )
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Steps, calories, distance…",
                    subtitle: "Activity — hourly aggregates",
                    color: .dsActivity,
                    isOn: $syncActivity
                )
                Divider().padding(.leading, .dsSpacing)
                DSToggleRow(
                    label: "Sleep",
                    subtitle: "All phases",
                    color: .dsSleep,
                    isOn: $syncSleep
                )
            }
        }
        .dsCard()
    }

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: .dsSpacing) {
            SectionHeader(title: "Workouts")

            VStack(spacing: 0) {
                DSToggleRow(label: "Sync workouts", isOn: $syncWorkouts)

                if syncWorkouts {
                    Divider().padding(.leading, .dsSpacing)
                    DSToggleRow(
                        label: "Heart rate timeline",
                        subtitle: "Per-minute HR during workout",
                        isOn: $workoutHRTimeline
                    )
                    Divider().padding(.leading, .dsSpacing)
                    DSToggleRow(
                        label: "GPS route",
                        subtitle: "Increases payload size",
                        isOn: $workoutGPS
                    )
                }
            }
        }
        .dsCard()
    }

    // MARK: - Connection test

    @ViewBuilder
    private var connectionBadge: some View {
        switch connectionState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().scaleEffect(0.8)
        case .ok:
            DSStatusBadge(text: "Connected", status: .good)
        case .failed(let msg):
            DSStatusBadge(text: msg, status: .danger)
        }
    }

    private func testConnection() {
        guard let url = URL(string: serverURL.isEmpty ? "" : serverURL + "/health") else {
            connectionState = .failed("Invalid URL")
            return
        }
        connectionState = .testing
        Task {
            do {
                var req = URLRequest(url: url, timeoutInterval: 10)
                let key = KeychainStore.apiKey ?? ""
                if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                connectionState = (200..<300).contains(code) ? .ok : .failed("HTTP \(code)")
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.dsSubhead)
            .foregroundStyle(Color.dsText)
            .padding(.horizontal, .dsSpacing)
            .padding(.top, .dsSpacing)
    }
}

private struct DSTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            TextField(placeholder, text: $text)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, .dsSpacingSm)
    }
}

private struct DSSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
            SecureField(placeholder, text: $text)
                .font(.dsBody)
                .foregroundStyle(Color.dsText)
        }
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, .dsSpacingSm)
    }
}

private struct DSToggleRow: View {
    let label: String
    var subtitle: String? = nil
    var color: Color = .dsAccent
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsText)
                if let subtitle {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
        }
        .tint(color)
        .padding(.horizontal, .dsSpacing)
        .padding(.vertical, 12)
    }
}

// MARK: - Keychain

enum KeychainStore {
    private static let key = "health-sync.api-key"

    static var apiKey: String? {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: AnyObject?
            SecItemCopyMatching(query as CFDictionary, &result)
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
            if let value = newValue, !value.isEmpty {
                let attrs: [CFString: Any] = [kSecValueData: Data(value.utf8)]
                if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
                    SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
                }
            } else {
                SecItemDelete(query as CFDictionary)
            }
        }
    }
}

#Preview {
    SettingsView()
}
