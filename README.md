# health-sync

iOS client that streams Apple HealthKit data to a self-hosted [health-dashboard](https://github.com/Dzarlax-AI/health_dashboard) server.

## What it does

Reads 100+ HealthKit metrics (vitals, body, gait, running, cycling, dietary, sleep, activity) and POSTs them as JSON to your own server. Sync runs automatically in background when HealthKit delivers new data, with a foreground timer as fallback while the app is open.

## Features

- **Background sync** via `HKObserverQuery` + `enableBackgroundDelivery` for step/HR/energy trigger metrics
- **Server checkpoint** — queries `/health/checkpoint` to resume from the last known timestamp (avoids gaps on reinstall or lost local state)
- **Configurable interval** (1 min — 6 hours) for foreground/BGProcessingTask fallback
- **Optional local push** after each sync for diagnostics
- **Apple Watch dedup** for sleep across sources (Watch > other)
- Fully editable list of synced metric categories in Settings

## Architecture

```
HealthKit ──► HKObserverQuery (3 trigger types)
                    │
                    ▼
             beginBackgroundTask (~30s window)
                    │
                    ▼
           SyncEngine.syncNow()
                    │
                    ├─► GET /health/checkpoint  (since-date)
                    ├─► HealthKitManager.fetchAll(since:)  (parallel)
                    └─► POST /health  (JSON payload)
```

Key files:

- `SyncEngine.swift` — `@MainActor @Observable` singleton. Coordinates sync, manages `lastSync`, `history`, foreground timer.
- `HealthKitManager.swift` — actor wrapping `HKHealthStore`. Defines all metric types, runs `HKSampleQuery` (AVG) / `HKStatisticsCollectionQuery` (SUM) / sleep aggregation.
- `BackgroundSyncManager.swift` — class (not actor, for fast sync registration). Registers `HKObserverQuery` + `enableBackgroundDelivery` for trigger types, handles `BGProcessingTask`.
- `SyncModels.swift` — `SleepPhases` / `CategoryEventDef` kept out of HealthKit-importing files to avoid Swift 6 `@MainActor` contamination.
- `ServerPayload.swift` — `HealthPayload` / `MetricSample` encoding. Dates formatted as `"YYYY-MM-DD HH:MM:SS ±HHMM"` to match server expectations.
- `DesignSystem.swift` — warm editorial palette (`#FCFAF7` background, `#e11d48` heart, Georgia serif headings).

## Setup

1. Open `health-sync.xcodeproj` in Xcode
2. Signing & Capabilities → select your team, enable **HealthKit** and **Background Modes → Background processing**
3. Info.plist already has `BGTaskSchedulerPermittedIdentifiers = com.health-sync.background-sync`
4. Build & run on device (simulator HealthKit is limited)
5. In app Settings:
   - Server URL: `https://your-health-dashboard.example.com`
   - API Key: matches `API_KEY` env on the server
   - Sync frequency: 15 min default

## Background sync — reality check

iOS aggressively throttles background work. With `HKObserverQuery` + trigger metrics, expect wake-ups during activity (Watch writing HR/steps), but **not** guaranteed every N minutes. `BGProcessingTask` runs maybe once a day, usually while charging.

Full real-time sync would require silent push from the server — not implemented.

## Swift 6 concurrency notes

`@preconcurrency import HealthKit` in a file contaminates types defined there with `@MainActor` inference even when they're pure value types. Workaround: keep such types (e.g. `SleepPhases`) in files without HealthKit imports (`SyncModels.swift`). See commit history for the full saga.

## Related

- [health_dashboard](https://github.com/Dzarlax-AI/health_dashboard) — Go backend (ingestion, storage, dashboard, MCP, AI briefing)
