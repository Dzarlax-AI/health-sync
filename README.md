# health-sync

Native iOS app for the self-hosted [health_dashboard](https://github.com/Dzarlax-AI/health_dashboard) server. It uploads selected Apple Health data and displays a read-only dashboard built from the server's JSON API.

## Dashboard

- **Today:** daily overview, domain score rings, server insights and optional AI insights.
- **Sleep:** sleep duration, stages, sources and 7/30/90-day trends.
- **Trends:** readiness history and detailed Recovery, Activity and Cardio screens.
- **Energy:** current energy, capacity, drain, strain and stress, with 14 days of daily history. Missing values remain unavailable; negative energy values are preserved.
- **Metrics:** server-provided metric catalog and individual history charts.
- **Settings:** server connection, account information, sync controls, recent activity and background diagnostics.

The five main tabs are Today, Sleep, Trends, Metrics and Settings. Domain detail screens share landscape headers, score rings and chart cards. The interface supports light and dark appearances, with consistent ring colors across themes and layouts for larger text.

**The server owns the health interpretation.** Scores, metric names, section explanations and insight content come from the server. Server Insight and AI Insight remain separate: unavailable, generating or invalid AI content does not replace the server's facts. The app respects the server's insight mode and feature gates.

**Two localization layers are intentional.** Interface controls follow the iOS app language (English, Russian or Serbian). Dashboard content follows the server's `report_lang` setting. These languages may differ.

## Health data sync

- Select metric categories in Settings: vitals, body measurements, sleep, activity and other supported HealthKit data.
- Enable workout uploads separately, including optional routes and heart-rate timelines.
- Metrics are batched into `POST /health`; workouts use `POST /health/workouts`.
- Each channel has its own persisted progress, pending ranges and retry state. A successful metrics upload does not hide a failed workout upload.
- Sync state is scoped to the server/account configuration. Local timestamps and pending ranges drive resumption; the app does not fetch a server checkpoint.
- HealthKit collection includes source filtering, sleep deduplication and an initial sleep-history backfill.
- The API key is stored in Keychain. Temporarily inaccessible credentials are distinguished from missing credentials, allowing pending work to recover after unlock.
- Recent activity distinguishes server acceptance, no new data, partial delivery and failures. Server acceptance is not proof that downstream processing has finished.

### Background behavior

Background sync combines HealthKit observers for **steps, heart rate, active energy and sleep** with scheduled processing tasks. A separate daily task requests a seven-day resync to collect delayed or corrected data. Pending full-resync date ranges survive a delayed unlock or app restart.

Settings controls the sync interval: **1 minute, 15 minutes, 30 minutes, 1 hour, 3 hours or 6 hours**, with a 15-minute default. Foreground checks follow this interval while the app is open. For background processing it specifies the earliest scheduling opportunity, **not a guaranteed execution frequency**. iOS decides when background work can run; neither HealthKit notifications nor scheduled tasks guarantee immediate delivery.

“Sync on launch” is a separate setting. Recovery of previously blocked background work is handled independently of that preference. Optional sync notifications are local notifications.

Settings includes background status and recent diagnostic events to help distinguish scheduling, credential-access and execution problems. These diagnostics do not contain health payloads or API keys. Simulator tests and a successful device installation cannot establish reliable background delivery over time; that requires observing sync on a real iPhone.

## Setup

1. Open `health-sync.xcodeproj` in Xcode and select your signing team.
2. Verify the **HealthKit**, **HealthKit Background Delivery** and **Background Modes** capabilities. The repository includes HealthKit entitlements and the `fetch` / `processing` background modes.
3. Build and run on your iPhone.
4. In Settings, enter your server URL (for example, `https://your-health-dashboard.example.com`) and the API key issued for your server account. Check the displayed account information.
5. Grant HealthKit read access, choose the metric categories and workout options you want to upload, then run a manual sync.
6. Check recent activity for delivery results. Enable background sync and choose the interval; enable local notifications only if wanted.

The app reads HealthKit data; it does not write health records. HealthKit permissions and background behavior need real-device validation.

The following scheduler identifiers are already declared in [Info.plist](health-sync/Info.plist):

- `com.health-sync.background-sync`
- `com.health-sync.daily-resync`

## Build and test

Use Xcode 26 with an SDK/runtime compatible with the project. The app deployment target is iOS 26.0; test targets require iOS 26.4 or later. The project currently uses Swift 5 language mode with the Swift 6 toolchain and MainActor default isolation for the app. It has no third-party package dependencies.

Choose an installed simulator from `xcodebuild -scheme health-sync -showdestinations`. For example:

```bash
# Build
xcodebuild -scheme health-sync \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Unit tests
xcodebuild -scheme health-sync \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:health-syncTests test

# Dashboard appearance and domain navigation tests
xcodebuild -scheme health-sync \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:health-syncUITests/InsightParityUITests test
```

UI tests use `--ui-test-mode` with fixtures such as `--insights-fixture` to exercise dashboard states without real HealthKit access or production network requests. These runs verify rendering and interaction, not delivery of real health data.

## Architecture

```text
HealthKit observers / scheduled tasks / foreground checks / manual sync
                                  |
                              SyncEngine
                                  |
                    account-scoped local sync state
                         /                   \
               selected metrics           workouts
                  POST /health       POST /health/workouts

Server JSON API -> ServerClient -> dashboard models/controllers -> SwiftUI
```

| Source | Responsibility |
| --- | --- |
| [SyncEngine.swift](health-sync/SyncEngine.swift) | Coordinates metrics/workout delivery, retries, resyncs and foreground checks. |
| [SyncStateStore.swift](health-sync/SyncStateStore.swift) | Persists account-scoped channel progress and pending ranges. |
| [HealthKitManager.swift](health-sync/HealthKitManager.swift) | Reads and aggregates selected HealthKit metrics. |
| [HealthSyncTransport.swift](health-sync/HealthSyncTransport.swift) | Uploads payloads and interprets server receipts. |
| [WorkoutSync.swift](health-sync/WorkoutSync.swift) | Collects and serializes workouts. |
| [BackgroundSyncManager.swift](health-sync/BackgroundSyncManager.swift) | Integrates HealthKit observers and background task execution. |
| [BackgroundScheduling.swift](health-sync/BackgroundScheduling.swift) | Applies scheduling preferences and preserves earlier pending requests. |
| [BackgroundUnlockRetry.swift](health-sync/BackgroundUnlockRetry.swift) | Persists work deferred until credentials are accessible. |
| [KeychainStore.swift](health-sync/KeychainStore.swift) | Stores credentials and reports credential-access failures. |
| [ServerClient.swift](health-sync/ServerClient.swift) | Loads dashboard JSON with account and language context. |
| [TodayInsightsController.swift](health-sync/TodayInsightsController.swift) | Loads server/AI insight pairs and handles generation states. |
| [EnergyView.swift](health-sync/EnergyView.swift) | Renders current energy and daily history. |
| [DesignSystem.swift](health-sync/DesignSystem.swift) | Defines shared colors, typography, rings and themed surfaces. |

The dashboard uses `/api/health-briefing`, `/api/today-insights`, `/api/energy-history`, `/api/section/{key}`, `/api/readiness-history`, `/api/metrics`, `/api/metrics/data` and `/api/settings`, with additional supporting endpoints in `ServerClient`.

## Related

- [health_dashboard](https://github.com/Dzarlax-AI/health_dashboard) — ingestion, storage, health calculations, web dashboard and insights.
- [Native design review](docs/reviews/2026-09-26-bevel-native/index.html) — appearance review and screenshots.
- [Background and insight follow-up review](docs/reviews/2026-09-26-pr-21-follow-up.md) — fixes, regression checks and verification limits.
