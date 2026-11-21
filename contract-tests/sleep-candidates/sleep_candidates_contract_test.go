package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"health-receiver/internal/handler"
	"health-receiver/internal/health"
	"health-receiver/internal/storage"
)

func TestHealthSyncSwiftSleepCandidatesContract(t *testing.T) {
	mgr, root := newSleepRolloutFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	key := "rollout_a-key"
	profile, _, _, ok := mgr.DBForAPIKey(ctx, key)
	if !ok {
		t.Fatal("test profile did not resolve")
	}
	ingest := handler.New(mgr, nil, health.HRZones{})
	mux := http.NewServeMux()
	registerHealthIngest(ctx, mux, mgr, ingest, true)
	defer func() {
		cancel()
		if err := ingest.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	}()
	fixture, err := os.ReadFile(os.Getenv("HEALTH_SYNC_SWIFT_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	const batchID = "812eed26-00b4-4075-abff-7f91bafe8d36"
	setMode := func(mode string) {
		t.Helper()
		if err := profile.SaveSettings(map[string]string{storage.SleepRolloutModeSetting: mode, "timezone": "UTC",
			"sleep_rollout_source_priority": `["synthetic-watch","synthetic-ring"]`}); err != nil {
			t.Fatal(err)
		}
	}
	post := func(apiKey, body, expectedACK string) int64 {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/health", strings.NewReader(body))
		req.Header.Set("X-API-Key", apiKey)
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, req)
		var receipt struct {
			ID     int64  `json:"id"`
			Status string `json:"status"`
		}
		if res.Code != 200 || res.Header().Get("X-Health-Sleep-Candidates-Ack") != expectedACK ||
			json.Unmarshal(res.Body.Bytes(), &receipt) != nil || receipt.ID <= 0 || receipt.Status != "ok" {
			t.Fatalf("unexpected receipt: HTTP %d, ACK %q, body %s", res.Code, res.Header().Get("X-Health-Sleep-Candidates-Ack"), res.Body)
		}
		return receipt.ID
	}
	wait := func(want, query string, args ...any) {
		t.Helper()
		var result string
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
			if err := root.QueryRow(ctx, query, args...).Scan(&result); err != nil {
				t.Fatal(err)
			}
			if result == want {
				return
			}
		}
		t.Fatalf("want %q, got %q for %s", want, result, query)
	}
	day := time.Now().UTC().AddDate(0, 0, -3).Format(time.DateOnly)
	legacy := func(kcal int) string {
		return fmt.Sprintf(`{"data":{"metrics":[{"name":"active_energy","units":"kcal","data":[{"date":"%s 10:00:00 +0000","qty":%d,"source":"Synthetic"}]}]}}`, day, kcal)
	}
	const cache = `SELECT COALESCE(MAX(calories)::text,'') FROM rollout_a.daily_scores WHERE date=$1`
	const processed = `SELECT processing_status FROM rollout_a.health_records WHERE id=$1`
	setMode("off")
	post(key, legacy(420), "")
	wait("420", cache, day)
	lostReceipt := post(key, string(fixture), "")
	wait("complete", processed, lostReceipt)
	post(key, legacy(500), "")
	wait("500", cache, day)
	setMode("prepare")
	if got := post(key, string(fixture), batchID); got == lostReceipt {
		t.Fatal("off receipt unexpectedly owns the batch")
	} else if post(key, string(fixture), batchID) != got {
		t.Fatal("prepare replay returned a different receipt")
	}
	wait("1", `SELECT count(*)::text FROM rollout_a.sleep_rollout_batches WHERE batch_id=$1`, batchID)
	wait("4", `SELECT count(*)::text FROM rollout_a.sleep_rollout_candidates WHERE wake_date='2026-11-17' AND revision=1`)
	wait("500", cache, day)
	// This is a known serve blocker: v1 picks source priority before
	// checking whether the source contains a usable night.
	wait("1200", `SELECT sleep_seconds::text FROM rollout_a.sleep_rollout_daily WHERE wake_date='2026-11-17'`)
	wait("3", `SELECT count(*)::text FROM rollout_a.sleep_rollout_candidates WHERE id::jsonb->>0='synthetic-watch' AND wake_date='2026-11-17'`)
	wait("0", `SELECT count(*)::text FROM rollout_b.sleep_rollout_batches`)

	// With candidate delivery disabled, the ordinary ingest retains both
	// sources for the same wake date.
	setMode("off")
	watchAndRing := fmt.Sprintf(`{"data":{"metrics":[{"name":"night_sleep_total","units":"hr","data":[
		{"date":"%s 00:00:00 +0000","qty":0.333,"source":"Apple Watch"},
		{"date":"%s 00:00:00 +0000","qty":6,"source":"RingConn"}
	]}]}}`, day, day)
	legacySleepID := post(key, watchAndRing, "")
	wait("complete", processed, legacySleepID)
	wait("2", `SELECT count(DISTINCT source)::text FROM rollout_a.metric_points
		WHERE health_record_id=$1 AND source IN ('Apple Watch','RingConn')`, legacySleepID)

	// A mixed request first handled in off owns no candidate receipt. Its
	// original metric can overwrite a more recent value when retried in prepare.
	const mixedID = "912eed26-00b4-4075-abff-7f91bafe8d36"
	metric := strings.SplitN(legacy(420), "[", 2)[1]
	metric = strings.TrimSuffix(metric, "]}}")
	mixed := strings.ReplaceAll(string(fixture), batchID, mixedID)
	mixed = strings.Replace(mixed, `"metrics":[]`, `"metrics":[`+metric+`]`, 1)
	setMode("off")
	post(key, mixed, "")
	wait("420", cache, day)
	post(key, legacy(500), "")
	wait("500", cache, day)
	setMode("prepare")
	post(key, mixed, mixedID)
	wait("420", cache, day)
}
