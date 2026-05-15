# Spec: split coarse sleep from `sleep_core` (server + dashboard + iOS)

Handoff document for the cross-repo rollout. iOS work is in this repo
(`health-sync`); server work in `health_processing`; dashboard work in
`health_dashboard`. Steps are ordered so each is backward-compatible
in isolation.

## Context

iOS (`HealthKitManager.sleepPhaseName(for:)`, line ~948) currently maps
three HK sleep values into a single wire name:

```swift
case .asleepCore, .asleepUnspecified, .asleep:  return "sleep_core"
```

So `daily_scores.sleep_core_hours` server-side mixes:
- real core minutes from Apple Watch with stage tracking, AND
- coarse "just asleep" hours from RingConn / iPhone Sleep Schedule /
  older Apple Watch.

Stages-stacked chart on the dashboard shows the mix as "Core". PR #10
(`8e18618`) capped the *double-counting* (a single 8h night reported
as ~16h) by skipping coarse rows when stages exist in the same
session. It did NOT remove the lie about what `sleep_core` represents
for sources that *only* emit coarse data.

This spec removes the lie by introducing a fifth phase metric
`sleep_unspecified`.

## Wire contract

iOS will start emitting:

```json
{
  "data": {
    "metrics": [
      {
        "name": "sleep_unspecified",
        "units": "hr",
        "data": [
          {"date": "2026-05-14 23:00:00 +0200", "qty": 7.5, "source": "RingConn"}
        ]
      }
    ]
  }
}
```

- **Name:** `sleep_unspecified`
- **Units:** `hr`
- **Kind:** SUM (additive within a day, identical to `sleep_core`)
- **Field:** `qty`
- **Per-segment shape:** identical to existing `sleep_core` segments
- **Date convention:** wake-up date (same rule as other sleep_* metrics)

**Emission condition (iOS):** only when the HK session has no
`.asleepDeep` / `.asleepREM` / `.asleepCore` markers anywhere. Sources
with stage tracking continue to emit `sleep_core` as the real
measurement. After the iOS PR ships, RingConn-only and iPhone-only
nights will stop landing in `sleep_core` and start landing in
`sleep_unspecified` instead.

---

## Server changes (`health_processing`, Go)

### 1. Accept the metric in `/health` handler

The pipeline is likely already metric-name-driven (UPSERT on
`(metric_name, date, source)` — that's the "overlap idempotent"
property from CLAUDE.md). If so, no whitelist change needed; the new
name flows through.

Verify by searching:
- `internal/handler/health.go` (or wherever the POST handler lives)
  for any allow-list / switch on `metric_name`.
- DB schema for a CHECK constraint or enum on the metric_name column.

If an allowlist exists, add `"sleep_unspecified"`.

### 2. `daily_scores` aggregation

```sql
ALTER TABLE daily_scores ADD COLUMN sleep_unspecified_hours DOUBLE DEFAULT 0;
```

Update the `sleep_total` formula. Current (likely):
```
sleep_total = sleep_deep + sleep_rem + sleep_core
```
After:
```
sleep_total = sleep_deep + sleep_rem + sleep_core + sleep_unspecified
```

Invariant: `stages_sum == sleep_total` (excluding awake). It currently
holds because the coarse layer sits in `sleep_core`. After the iOS
fix it must hold via the new column.

Find the aggregator (probably `internal/aggregate/*.go` or a periodic
job) and add a read of `metric_name='sleep_unspecified'` rows next to
the three existing stage reads.

### 3. API endpoints

#### `/api/metrics?lang={en|ru|sr}`

Add catalogue entry:

```json
{
  "name": "sleep_unspecified",
  "display_name": {
    "en": "Asleep (no stages)",
    "ru": "Сон (без стадий)",
    "sr": "San (bez faza)"
  },
  "units": "hr",
  "category": "sleep",
  "description": {
    "en": "Sleep time from sources that don't report deep/REM/core breakdown (RingConn, iPhone-only, older Apple Watch).",
    "ru": "Время сна от источников, которые не разбивают сон на фазы (RingConn, только iPhone, старый Apple Watch).",
    "sr": "Vreme spavanja iz izvora koji ne prijavljuju faze (RingConn, samo iPhone, stariji Apple Watch)."
  }
}
```

#### `/api/metrics/data?name=sleep_unspecified&from=…&to=…&bucket=day`

Should work automatically after the storage + aggregator changes.

#### `/api/section/sleep` (if a "sleep" section exists with copy)

Add a sentence to the "How it works" copy:

> Sources that don't measure stages (RingConn, iPhone alone) appear
> as Asleep without a breakdown; stage rings come from Apple Watch only.

Localize en/ru/sr.

#### `/api/health-briefing`

If the LLM prompt enumerates sleep metrics explicitly, add
`sleep_unspecified` to the list. If the briefing just reads from the
dashboard payload, no change.

### 4. Historical migration (optional, recommended)

Existing `sleep_core` rows for source-date pairs that have no
`sleep_deep` / `sleep_rem` siblings are pure coarse data — should be
moved to the new metric so historical days on the dashboard stop
looking "all core".

```sql
INSERT INTO metric_data (metric_name, date, source, qty, units)
SELECT 'sleep_unspecified', date, source, qty, units
FROM metric_data c
WHERE c.metric_name = 'sleep_core'
  AND NOT EXISTS (
    SELECT 1 FROM metric_data x
    WHERE x.date = c.date
      AND x.source = c.source
      AND x.metric_name IN ('sleep_deep', 'sleep_rem')
  );

DELETE FROM metric_data
WHERE metric_name = 'sleep_core'
  AND NOT EXISTS (
    SELECT 1 FROM metric_data x
    WHERE x.date = metric_data.date
      AND x.source = metric_data.source
      AND x.metric_name IN ('sleep_deep', 'sleep_rem')
  );
```

Then recompute `daily_scores` over the affected date range. Skip the
migration if you'd rather have a clean cutover from a specific date —
old days stay "wrong as-they-were", new days are correct.

### 5. Tests

- Unit: handler accepts a payload containing `sleep_unspecified` and
  UPSERTs it into the metric_data table.
- Unit: aggregator includes `sleep_unspecified` in `sleep_total`.
- Unit: stages-sum invariant — for a mixed-source day
  (Apple Watch full night + RingConn short nap)
  `deep + rem + core + unspecified == sleep_total`.

---

## Dashboard changes (`health_dashboard`)

### 1. SleepView stages-stacked chart

Add a 5th band:

- **Colour:** neutral grey-blue, distinct from both `core` and `awake`.
  Suggestion: `#9BA3B0` light / `#5B6378` dark — translate to your DS
  tokens.
- **Stack order (bottom → top):** `deep → core → rem → unspecified → awake`.
  `unspecified` sits between `rem` and `awake` because it represents
  unclassified *actual sleep* (not awake time).
- **Legend label:** "Asleep (no stages)" / "Сон (без стадий)" — pulled
  from `/api/metrics`.

### 2. Tooltip on the unspecified band

- **en:** "No per-stage breakdown from this source"
- **ru:** "Источник не предоставил разбивку на фазы"
- **sr:** "Izvor nije pružio podelu na faze"

### 3. "Last night" tile (if present)

If the tile shows three rows "Deep / REM / Core", add a fourth row
"Asleep (unspecified)" **only when the value > 0**. Typical Apple
Watch nights keep it hidden.

### 4. AI briefing rendering

If the page renders metrics dynamically from the payload, the new
metric is picked up automatically. Sanity-check that no hardcoded
list like `["deep", "rem", "core", "awake"]` lives in
frontend-aggregation code.

### 5. Source-attribution row (optional)

Existing "source row" on the sleep page (shipped in `7b1dfae`) —
when a night consists only of `sleep_unspecified`, surface a small
badge "stages not measured" next to the source name. Not blocking,
but it's the actual user-visible value of this rollout.

---

## iOS changes (this repo, do AFTER server + dashboard deploy)

Will be a separate PR here.

1. `HealthKitManager.sleepPhaseName(for:)` — split the case:
   ```swift
   case .asleepCore:                          return "sleep_core"
   case .asleepUnspecified, .asleep:          return "sleep_unspecified"
   ```
2. Main aggregation loop (~line 822–828 in `HealthKitManager.swift`):
   replace the fallback `p.core += hrs` with `p.unspecified += hrs`;
   emit a `sleep_unspecified` metric and per-segment entries.
3. `MetricDetailView.swift` line ~11 whitelist: add
   `"sleep_unspecified"`.
4. Test: add a `WorkoutSyncTests`-shape unit pinning the wire-shape
   for `sleep_unspecified` (similar to existing sleep-payload tests
   if any).

---

## Rollout order

Strictly:

1. **Server PR** — schema + handler + aggregator + `/api/metrics`
   catalogue + (optional) historical migration. Deploy.
2. **Dashboard PR** — 5th band + tooltip + legend. Deploy.
3. **iOS PR** — split `sleepPhaseName`, add `p.unspecified`, stop
   routing coarse into `p.core`. TestFlight → App Store.

Each step is backward-compatible:
- After step 1: server accepts the new metric, no iOS sends it yet.
  Existing data unchanged.
- After step 2: dashboard renders the new band, no data shows yet
  except via the optional historical migration.
- After step 3: data starts flowing in for new nights;
  RingConn-only / iPhone-only days appear with the unspecified band.

## What NOT to change

- `sleep_total` metric name — stays. Formula changes, name doesn't.
- `sleep_awake` — unchanged.
- `POST /health` payload format — unchanged. Just a new metric name
  inside the existing structure.
- HKQueryAnchor / sync overlap logic — unchanged. Everything is
  metric-name-driven.

## Checklist

### Server
- [ ] Migration: `daily_scores.sleep_unspecified_hours` column
- [ ] `/health` handler accepts new metric (verify, add to allow-list
      if any)
- [ ] Aggregator includes `sleep_unspecified` in `sleep_total`
- [ ] `/api/metrics` catalogue + i18n en/ru/sr
- [ ] `/api/section/sleep` copy update (if exists)
- [ ] Optional: historical migration script + daily_scores recompute
- [ ] Unit tests: handler, aggregator, invariant
- [ ] Deploy

### Dashboard
- [ ] 5th band in stages chart (correct stack order)
- [ ] Tooltip + legend i18n
- [ ] "Last night" tile shows unspecified row when > 0
- [ ] Optional: source-attribution badge
- [ ] Deploy

### iOS (this repo, after server + dashboard live)
- [ ] `sleepPhaseName(for:)` split
- [ ] `p.unspecified` accumulator + metric emission
- [ ] `MetricDetailView` whitelist
- [ ] Tests
- [ ] TestFlight + App Store
