# Health Sync iOS — Specification

iOS app for syncing Apple Health data to a `health_processing` server,
with native read-only views of the server-side dashboard.

**Target**: iOS 26+, Swift 6, SwiftUI  
**Repo**: `health-sync-ios` (separate from `health_processing`)

---

## Goals

- Replace Health Auto Export dependency with a first-party client
- Filter data at source (e.g. skip RingConn midnight summaries when Watch data exists)
- Add workout sync (not available in Health Auto Export)
- One-endpoint, one-payload design — no artificial metric splits
- Show the same data the web dashboard shows, natively, without duplicating
  business logic — server stays the single source of truth, the app is a
  thin Chart/List renderer over its JSON APIs

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

## Dashboard / Read-only Views

The app renders the same data the web dashboard shows, using server JSON
APIs. **No business logic is duplicated client-side** — readiness scoring,
aggregations, source priority, sleep dedup, AI briefing are all computed
on the server and shipped as ready-to-render JSON. The client only does
chart rendering, list formatting, and navigation.

Auth: same `X-API-Key` already stored in Keychain for `POST /health`.
All `/api/*` endpoints accept it via `guard()` on the server.

### Localization

Two layers, independent on purpose:

- **UI chrome** (tab labels, section titles, buttons, error banners, settings)
  is localized client-side via a String Catalog (`Localizable.xcstrings`),
  languages: `en`, `ru`, `sr`. Follows iOS locale; iOS provides a per-app
  language toggle in Settings → Health Sync (enabled via
  `UIPrefersShowingLanguageSettings`).

- **Server-side content** (briefing text, alert wording, section names,
  metric labels) is localized **on the server** — the iOS app passes
  `?lang=…` and the server returns ready-to-render strings. The lang value
  comes from the user's `report_lang` on the server (`/api/settings`),
  not from the device locale. Rationale: when new metrics or copy ship,
  no app update is needed — the server's `internal/health/i18n_*.go`
  catalogues are the single source of truth.

The two layers can disagree (e.g. iOS UI in Russian, server content in
Serbian if the user set `report_lang=sr` on the web). That's intentional.

### TabBar (5 tabs)

| Tab | Endpoints | Purpose |
|---|---|---|
| Today | `/api/health-briefing` (+ planned `ai_insight` field) | Hero ribbon, today's tiles, alerts, AI insight, section overview |
| Sleep | `/api/metrics/latest`, `/api/metrics/data?name=sleep_*` | Last night detail + 7/30d trend |
| Trends | `/api/readiness-history`, `/api/metrics/data` | Readiness history + push to Cardio/Activity/Recovery |
| Metrics | `/api/metrics?lang=…`, `/api/metrics/data`, `/api/metrics/range` | Full metric list (with localized `display_name`) and detail charts |
| Settings | `/api/settings` + local `SyncEngine` state | Sync controls, server config, app prefs (combined with former Status tab) |

### Today

Scrollable, organised top-to-bottom:

All five blocks are powered by `/api/health-briefing` (the server returns
`BriefingResponse` with `readiness_today`, `headline`, `energy_bank`,
`metric_cards`, `alerts`, `sections`, `insights`, `correlation`, `sleep`).
The AI Insight block requires a new server field — see Server Changes.

1. **Hero (header)** — `readiness_today`, status label, `headline` chip with
   detail, `energy_bank` verdict + bar (current/capacity), 30d readiness
   sparkline (from `/api/readiness-history`). Status colour mirrors web
   (`good ≥70`, `fair ≥40`, `low <40`).
2. **At a glance** — grid of `metric_cards` with current value, unit, mini
   sparkline, 7d/30d trend chips. Tap → Metric Detail.
3. **Health alerts** — banner list from `alerts` (when present).
4. **AI Insight** — collapsible, Gemini-generated narrative. Currently
   only embedded in the server-rendered HTML (`db.GetAIBriefing(today,
   lang)`); needs to be exposed via API — preferred approach: add
   `ai_insight string` field to `BriefingResponse`. Cached server-side in
   `ai_briefings` table.
5. **Health overview** — `sections` rows (Sleep / Cardio / Activity /
   Recovery) with status badge, summary, 2–3 deltas. Tap → corresponding
   tab (Sleep tab for Sleep, Trends → push view for Cardio / Activity /
   Recovery).

Pull-to-refresh refetches `/api/health-briefing` and
`/api/readiness-history` in parallel.

### Sleep

- Last night: total / deep / REM / core / awake hours, efficiency.
- 7 / 30 / 90d chart (segmented control), stacked stages or total bar.
- Source row: which device's data was used (Apple Watch / RingConn /
  cross-validated) — uses the same priority the server applied.

### Trends

Root view:
- Readiness history chart (`/api/readiness-history`) with 7/30/90d range.
- List rows pushing to:
  - **CardioDetailView** — RHR, HRV, VO2, respiratory rate.
  - **ActivityDetailView** — steps, active energy, exercise minutes,
    distance, flights.
  - **RecoveryDetailView** — sleep summary, HRV CV, wrist temperature.

Push (not segmented) — each detail has multiple charts and benefits from
its own scroll context and back gesture.

### Metrics

- Full list with search (`/api/metrics`).
- Tap → Metric Detail: chart over selectable range
  (`/api/metrics/data?range=...`), summary stats (`/api/metrics/range`).

### Settings (merged with former Status tab)

Single scrollable list, top-to-bottom:

```
Sync
  ▶ Sync Now
  Last sync: 2 min ago / Failed (3 retries)
  Recent activity (collapsible — last 5 from SyncHistory)

Server
  URL          https://health.example.com
  API Key      ••••••••••
  [Test Connection]                  ✓ OK

Account
  Username, tenant, timezone, language       (read-only, /api/settings)

Sync settings
  Background sync                      ON
  On app launch                        ON
  Source filtering                     ON
  Metrics                              [Customize…]

Workouts
  Sync workouts                        ON
  Include HR timeline                  ON
  Include GPS route                   OFF

About
  Version, build, logs
```

Telegram config, AI model, admin controls (backfill, quality audit, user
management) stay on the web — out of scope for the mobile app.

API Key in Keychain. URL and prefs in SwiftData. Sync history in SwiftData
(last 50). On sync error → red badge on the Settings tab icon.

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
  ├── POST /health/workouts
  ├── GET  /api/dashboard
  ├── GET  /api/health-briefing
  ├── GET  /api/readiness-history
  ├── GET  /api/metrics
  ├── GET  /api/metrics/latest
  ├── GET  /api/metrics/data
  ├── GET  /api/metrics/range
  └── GET  /api/settings

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

- **Background Tasks** (`BGProcessingTask`) — best-effort sync at system-selected times
- **HKObserverQuery** + `enableBackgroundDelivery` — system-limited wakeups on new data
- **App Intents** — `SyncNowIntent` for Shortcuts / Siri
- **WidgetKit** — proposed, not implemented

### Background recovery (September 2026)

The user-selected interval drives the foreground timer and the earliest requested
background sync time. It is not a guaranteed background cadence. HealthKit
observer events can trigger additional syncs independently of that interval.
Pending earlier requests, including overdue daily requests, are retained on
configuration refresh. A changed interval replaces the regular request; daily
work remains independent. The daily request becomes eligible after 03:00 local
time, with actual execution determined by iOS.

Observer queries register synchronously at launch using nonsecret preferences.
Registration and scheduling do not require reading the API key. Temporary
credential unavailability must never disable HealthKit delivery or cancel queued
system tasks. Only an explicit background-sync off transition does that.
Asynchronous delivery enable/disable and scheduler reconciliation are serialized
to prevent an old callback from resurrecting disabled work or undoing reenable.
Failed delivery setup is retried on launch, activation, protected-data recovery,
or a system background task, rather than every configuration refresh.

The existing Keychain item is updated in place to
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` while protected data is
available. New writes use the same accessibility. This allows credentials to be
read after the first unlock following boot, including later lock periods. The
key remains in Keychain and does not migrate to a different device through
backup restore. Missing, locked, and failed Keychain operations are distinct;
failed migration preserves the item and can retry. HealthKit itself may still
be unreadable while the device is locked.

Each background execution acknowledges its callback once, including expiration,
and cancels only its own sync owner. Deferred ranges remain in the existing
account-scoped sync state, with no checkpoint advancement on locked reads or
unconfirmed uploads. Protected-data availability retries work deferred for lock
or credentials when this process receives the notification; it is not a promise
that unlocking the phone launches the app.

Settings shows system background refresh availability, Low Power Mode, the last
device-level background receipt, and recent background events. The local journal
retains at most 40 fixed-vocabulary timestamped events and never includes keys,
URLs, payloads, health values, or free-form errors. A no-data scan is not a server
receipt. Upload transport remains a normal URLSession with durable range retry,
not a background file-upload queue. Real-device delivery and dashboard freshness
must be verified separately from Simulator tests.

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
| `BriefingResponse.ai_insight` field | ❌ expose Gemini briefing text via API for native Today screen |

---

## Out of Scope (v1)

- HealthKit cross-check (compare server values against HealthKit on device
  to detect ingest gaps) — deferred to a later phase
- Admin / config that lives on the web: Telegram, AI model, backfill,
  quality audit, user management
- Android
- Apple Watch app
- Settings export/import
- Multiple server profiles

### Native Server Insight / AI Insight and Energy (2026-09-26)

The Today snapshot remains server-authored. iOS decodes the optional top-level
and domain `ai_insight` objects, `generation.narrative_mode`, and per-slot
state/freshness/retry metadata. Server and AI opinions are separate labeled
cards; an AI alternative action never replaces the server action. Preview is
visible on Today, Sleep, Recovery, and Energy. Missing or failed AI retains
server facts; stale AI is not presented as current. Legacy AI briefing is used
only when the optional Today endpoint is unavailable.

Today domain cards show server summaries and data states, plus nonempty daily
changes. Sleep opens the native Sleep tab, Recovery opens its existing detail
screen, and Energy opens a dedicated screen rather than Activity. Domain
insights carry their current-day date independently of historical chart ranges.

Energy displays server-provided current reserve/capacity and details, with
14 daily snapshots from `/api/energy-history?granularity=day&days=14`.
Daily values may be negative and are not interpreted as hourly observations.
Energy history, current values, and insights load independently; a missing
optional resource does not hide other data. No energy formula is computed on
the client.

Insight refresh runs only while its screen is visible and active. Disabled
AI is rechecked every 60 seconds without consuming generation retries;
cold/generating/failed states have a ten-retry budget and honor server backoff.
Late results after cancellation or account/language/day changes are discarded.
Transient failures may retain visibly stale facts from the same context;
authorization failures clear them. A lightweight local context check detects
rollover without repeatedly fetching already-ready snapshots.

UI fixtures use synthetic data and require both `--ui-test-mode` and
`--insights-fixture`; real credentials, HealthKit, notifications, and network
requests remain disabled in test mode. User interface labels support EN/RU/SR;
server text continues to use `report_lang` independently of the iOS locale.
