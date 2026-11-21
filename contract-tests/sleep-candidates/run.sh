#!/bin/bash
set -euo pipefail

client=$(cd "$(dirname "$0")/../.." && pwd)
server=$(cd "${1:?Usage: run.sh SERVER_WORKTREE [core|early|legacy]}" && pwd -P)
: "${READINESS_TEST_DSN:?Set a disposable PostgreSQL Unix-socket DSN}"
mode=${2:-core}
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

case "$mode" in
    core|early)
        swiftc -module-cache-path "$scratch/swift-cache" -swift-version 6 -default-isolation MainActor \
            "$client"/health-sync/{SleepCandidatePacket,SleepCandidateCapture,SleepCandidateJournal,SleepDeletionEvidence,HealthSyncTransport,SyncContracts,ServerPayload}.swift \
            "$client/contract-tests/sleep-candidates/RevisionFixture.swift" -o "$scratch/emit"
        "$scratch/emit" "$scratch"
        required=(
            TestHealthSleepSwiftAndArchiveIntegration
            TestHealthSleepRevisionBoundWithdrawal
            TestSleepRolloutServeAndRollback
            TestRevisionBoundSleepSelectionWithdrawal
            TestArchiveRecordsUseSameSnapshotClockAsImport
        )
        if [[ "$mode" == early ]]; then
            required+=(TestHealthSleepEarlyOrdinarySync TestHealthSleepEarlyWireCompatibility TestHealthSleepEarlyShadowDelivery)
            export HEALTH_SLEEP_EARLY_WIRE_FIXTURES="$scratch"
        fi
        pattern=$(IFS='|'; echo "${required[*]}")
        export HEALTH_DB_TESTS=1 HEALTH_SLEEP_COMBINED_FIXTURES="$scratch"
        cd "$server"
        go test ./cmd/server ./internal/storage ./internal/applehealth -count=1 -v -run "^($pattern)$" | tee "$scratch/output.log"
        for name in "${required[@]}"; do
            if ! grep -Fq -- "--- PASS: $name (" "$scratch/output.log"; then
                echo "Required contract test did not pass: $name" >&2
                exit 1
            fi
        done
        exit 0
        ;;
    legacy) ;;
    *) echo 'Expected core, early, or legacy mode.' >&2; exit 2 ;;
esac

tree=$(git -C "$server" rev-parse 'HEAD^{tree}')
if [[ "$tree" != '5fc62fc72ef4ab9b00f91e69a50b4ac3e5579b9c' ]] ||
   [[ -n $(git -C "$server" status --porcelain) ]]; then
    echo 'A clean checkout of the PR #280 release tree is required.' >&2
    exit 1
fi

swiftc -module-cache-path "$scratch/swift-cache" -swift-version 6 -default-isolation MainActor \
    "$client/health-sync/SleepCandidatePacket.swift" \
    "$client/health-syncTests/SleepCandidateContractFixture.swift" -o "$scratch/generate"
"$scratch/generate" > "$scratch/packet.json"

python3 - "$server" "$scratch" "$client/contract-tests/sleep-candidates/sleep_candidates_contract_test.go" <<'PY'
import json
import sys
from pathlib import Path

server, scratch, fixture = map(Path, sys.argv[1:])
target = server / "cmd/server/health_sleep_candidates_integration_test.go"
original = target.read_text().replace("import (\n", 'import (\n\t"os"\n', 1)
test = fixture.read_text()
bridge = scratch / "contract_overlay.go"
bridge.write_text(original + "\n" + test[test.index("func Test"):])
(scratch / "overlay.json").write_text(json.dumps({"Replace": {str(target): str(bridge)}}))
PY

cd "$server"
export HEALTH_DB_TESTS=1 HEALTH_SYNC_SWIFT_FIXTURE="$scratch/packet.json"
go test -overlay "$scratch/overlay.json" ./cmd/server -count=1 -v \
    -run '^(TestHealthSyncSwiftSleepCandidatesContract|TestHealthSleepCandidates.*|TestHealthSleepPeriodReceiptOrder|TestSleepRolloutServeAndRollback)$' \
    | tee "$scratch/output.log"
if grep -q '^[[:space:]]*--- SKIP:' "$scratch/output.log"; then
    echo 'A required contract test was skipped.' >&2
    exit 1
fi
