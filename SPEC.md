# Health Sync iOS — Specification

iOS app for syncing Apple Health data to a `health_processing` server.
Open-source, no data viewing — collect and send only.

**Target**: iOS 26+, Swift 6, SwiftUI  
**Repo**: `health-sync-ios` (separate from `health_processing`)

---

## Goals

- Replace Health Auto Export dependency with a first-party client
- Filter data at source (e.g. skip RingConn midnight summaries when Watch data exists)
- Add workout sync (not available in Health Auto Export)
- One-endpoint, one-payload design — no artificial metric splits

---

## Sync Architecture

`HKObserverQuery` monitors all metrics. On wakeup, the app queries everything
that changed and sends **one batched payload** per sync cycle.

```
HKObserver (all metrics) → wakeup
    ↓
SUM metrics  → HKStatisticsCollectionQuery (hourly buckets)
AVG metrics  → HKSampleQuery (raw samples, minutely)
Workouts     → HKWorkoutQuery + HKWorkoutRoute + HR samples
    ↓
Merge into single payload
    ↓
POST /health  (one request)
```

No per-metric requests. No vitals/hourly split — the custom client handles
aggregation internally, the server receives a single mixed payload.

### Payload format (compatible with existing server)

```json
{
  "data": {
    "metrics": [
      {"name": "heart_rate", "units": "bpm", "data": [...]},
      {"name": "step_count", "units": "count", "data": [...]}
    ]
  }
}
```

Headers: `X-API-Key`, `automation-name: health-sync-ios`, `session-id: <UUID>`

### Since Last Sync

Per-metric `HKQueryAnchor` stored in SwiftData. Each sync only fetches new
samples since the last successful delivery.

---

## HealthKit Metrics

### AVG metrics (raw samples, minutely)

| HealthKit type | Metric name |
|---|---|
| HKQuantityTypeIdentifierHeartRate | heart_rate |
| HKQuantityTypeIdentifierHeartRateVariabilitySDNN | heart_rate_variability |
| HKQuantityTypeIdentifierOxygenSaturation | blood_oxygen_saturation |
| HKQuantityTypeIdentifierRespiratoryRate | respiratory_rate |
| HKQuantityTypeIdentifierRestingHeartRate | resting_heart_rate |
| HKQuantityTypeIdentifierAppleWalkingSteadiness | apple_walking_steadiness |
| HKQuantityTypeIdentifierWristTemperature | wrist_temperature |
| HKQuantityTypeIdentifierVO2Max | vo2_max |
| HKQuantityTypeIdentifierBodyMass | body_mass |
| HKQuantityTypeIdentifierBodyFatPercentage | body_fat_percentage |

### SUM metrics (hourly aggregation via HKStatisticsCollectionQuery)

| HealthKit type | Metric name |
|---|---|
| HKQuantityTypeIdentifierStepCount | step_count |
| HKQuantityTypeIdentifierActiveEnergyBurned | active_energy |
| HKQuantityTypeIdentifierBasalEnergyBurned | basal_energy_burned |
| HKQuantityTypeIdentifierAppleExerciseTime | apple_exercise_time |
| HKQuantityTypeIdentifierAppleStandTime | apple_stand_time |
| HKQuantityTypeIdentifierDistanceWalkingRunning | walking_running_distance |
| HKQuantityTypeIdentifierFlightsClimbed | flights_climbed |
| HKCategoryTypeIdentifierSleepAnalysis | sleep_analysis → sleep_* |

### Source filtering (client-side, before sending)

- **Sleep**: if Apple Watch data exists for a date → skip RingConn midnight
  summaries (`00:00:00`) for that date
- **Steps/calories**: prefer Apple Watch over iPhone over other sources

---

## Workouts Sync

New server endpoint: `POST /health/workouts`

```json
{
  "workouts": [{
    "id": "uuid",
    "type": "running",
    "start": "2026-04-20T07:00:00+02:00",
    "end":   "2026-04-20T08:00:00+02:00",
    "duration_min": 60,
    "distance_km": 10.2,
    "calories_active": 650,
    "calories_total": 720,
    "avg_heart_rate": 148,
    "max_heart_rate": 172,
    "heart_rate_samples": [
      {"t": "2026-04-20T07:01:00+02:00", "bpm": 142}
    ],
    "route": [
      {"t": "2026-04-20T07:01:00+02:00", "lat": 44.81, "lon": 20.45, "alt": 120.0}
    ],
    "source": "Alexey's Ultra"
  }]
}
```

`heart_rate_samples` and `route` are optional, controlled by settings.

---

## Settings UI

```
Server
  URL          https://health.example.com
  API Key      ••••••••••
  [Test Connection]                  ✓ OK

Sync
  Background sync                      ON
  On app launch                        ON

Metrics
  Heart rate, HRV, SpO2…              ON
  Steps, calories, sleep…             ON
  [Customize metrics…]

Workouts
  Sync workouts                        ON
  Include HR timeline                  ON
  Include GPS route                   OFF

[Sync Now]
```

API Key stored in Keychain. URL and preferences in SwiftData.

---

## Status UI

- Last successful sync: timestamp + points sent
- Per-metric last sync date
- Recent sync log (last 50 entries): date, metrics, points, status, error
- Errors shown with human-readable description + retry button

---

## Technical Architecture

```
HealthKitManager (actor)
  ├── ObserverQuery per metric → triggers SyncEngine
  ├── AnchoredObjectQuery for AVG metrics (incremental, since anchor)
  ├── StatisticsCollectionQuery for SUM metrics (hourly, since last date)
  └── WorkoutQuery (HKWorkout + HKWorkoutRoute + HR samples)

SyncEngine (actor)
  ├── Debounce: coalesce multiple observer wakeups into one sync (5s window)
  ├── MetricBatcher: split into AVG/SUM, build payload
  ├── WorkoutSyncJob: serialize workouts
  └── RetryQueue (SwiftData): failed payloads, exponential backoff

ServerClient
  ├── POST /health        (metrics)
  └── POST /health/workouts

Persistence (SwiftData)
  ├── Settings
  ├── HKQueryAnchors (per metric)
  ├── SyncHistory (last 50)
  └── RetryQueue
```

Swift 6 strict concurrency throughout. `HealthKitManager` and `SyncEngine`
are actors. Network calls via `async/await` + `URLSession`.

---

## iOS 26 Features

- **Background Tasks** (`BGProcessingTask`) — periodic sync when app is closed
- **HKObserverQuery** + `enableBackgroundDelivery` — real-time wakeup on new data
- **App Intents** — `SyncNowIntent` for Shortcuts / Siri
- **WidgetKit** — small widget: "Last sync: 5 min ago · 142 pts"

---

## Server Changes Required

| Item | Status |
|---|---|
| `POST /health` — accept mixed AVG+SUM payload | ✅ already works |
| `POST /health/vitals` | ✅ exists, optional to keep |
| `POST /health/hourly` | ✅ exists, optional to keep |
| `POST /health/workouts` | ❌ new endpoint needed |
| `GET /api/workouts` | ❌ new — list workouts for dashboard |
| `workouts` table | ❌ new |
| `workout_hr_samples` table | ❌ new |
| `workout_route` table | ❌ new |

---

## Out of Scope (v1)

- Data viewing in the app (use the web dashboard)
- Android
- Apple Watch app
- Settings export/import
- Multiple server profiles
