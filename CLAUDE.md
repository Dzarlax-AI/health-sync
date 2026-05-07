# CLAUDE.md

## Project

iOS app (iOS 26+, Swift 6, SwiftUI) that syncs Apple Health data to a
`health_processing` server **and** renders a native read-only dashboard
over the same server's JSON API (Today / Sleep / Trends / Metrics /
Settings). See `SPEC.md` for full specification.

Companion server: https://github.com/Dzarlax-AI/health_dashboard  
Local server path: `/Users/dzarlax/Projects/Code/Personal/health_processing`

## Commands

```bash
# Open in Xcode
open health-sync.xcodeproj

# Build from CLI (simulator)
xcodebuild -scheme health-sync -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -scheme health-sync -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Architecture

```
health-sync/
  Core/
    HealthKitManager.swift   — actor, HKObserverQuery + AnchoredObjectQuery
    SyncEngine.swift         — actor, debounce + batch + retry
    ServerClient.swift       — URLSession async/await
  Models/
    Settings.swift           — SwiftData: server URL, API key (Keychain)
    SyncHistory.swift        — SwiftData: last 50 sync entries
    QueryAnchors.swift       — SwiftData: per-metric HKQueryAnchor
    RetryQueue.swift         — SwiftData: failed payloads
    Workout.swift            — HKWorkout serialization
  Views/
    SettingsView.swift
    StatusView.swift
    MetricsPickerView.swift
  Intents/
    SyncNowIntent.swift      — App Intents for Shortcuts/Siri
```

## Key Design Decisions

- **One request per sync cycle** — no per-metric requests; all changed metrics
  batched into a single `POST /health` payload
- **No vitals/hourly split** — client handles aggregation internally
  (AVG metrics → raw samples, SUM metrics → hourly HKStatisticsCollection)
- **Source filtering at client** — if Apple Watch data exists for a date,
  skip RingConn midnight summaries before sending
- **HKQueryAnchor per metric** — incremental sync, only new samples since
  last successful delivery
- **Keychain for API key** — never stored in SwiftData or UserDefaults

### UI / Theming

All UI colors must go through `Color.ds*` helpers from `DesignSystem.swift`.
They are dynamic (`UIColor(dynamicProvider:)`-backed) and switch automatically
with iOS dark mode — no `@Environment(\.colorScheme)` plumbing needed at call
sites. Never use literal `Color.white` / `Color.black` / `Color.red` etc. in
views — it breaks dark mode silently. `DesignSystem.swift` mirrors
`tokens/ios/DesignSystemColors.swift` from the `dzarlax/design-system` repo;
when tokens change, update both.

### Read-only dashboard

- **Server is the single source of truth.** No business logic on the
  client: scoring, aggregation, source priority, sleep dedup, metric
  display names, section narratives, "How it works" copy and AI insights
  all come from server JSON (`/api/health-briefing`, `/api/section/{key}`,
  `/api/metrics?lang=…`, `/api/metrics/data`, `/api/readiness-history`,
  `/api/settings`). iOS only renders charts + handles navigation.
- **Two-layer localization** is intentional. UI chrome follows iOS
  locale via `Localizable.xcstrings` (en/ru/sr); content follows the
  server-side `report_lang` from `/api/settings`, which `ServerClient`
  caches and forwards as `?lang=` on content endpoints. Per-app
  language toggle on iOS is independent from `report_lang`. When new
  metrics or copy ship, no app update is needed.
- **`ServerClient` is a `@MainActor final class`, NOT `actor`.** The
  project uses Swift 6 default actor isolation = MainActor, so all
  Decodable conformances become MainActor-isolated. An actor
  `ServerClient` couldn't call them or access MainActor-isolated
  `KeychainStore.apiKey`. URLSession.data() releases the main actor
  while awaiting, so concurrent network overlap is preserved anyway.

## Payload Format

Compatible with existing server (`POST /health`):
```json
{
  "data": {
    "metrics": [
      {"name": "heart_rate", "units": "bpm", "data": [
        {"date": "2026-04-20 07:01:00 +0200", "Avg": 62.0, "source": "Alexey's Ultra"}
      ]}
    ]
  }
}
```

## HealthKit Entitlements Required

Add to `health-sync.entitlements`:
- `com.apple.developer.healthkit`
- `com.apple.developer.healthkit.background-delivery`

Add to `Info.plist`:
- `NSHealthShareUsageDescription`
- `NSHealthUpdateUsageDescription` (if writing back)

## Environment

- Xcode 26+
- iOS 26+ deployment target
- Swift 6 strict concurrency (`-strict-concurrency=complete`)
- No third-party dependencies (pure Apple frameworks)
