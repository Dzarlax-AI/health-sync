# Sleep candidate contract rehearsal

The Swift fixture uses the production encoder. Run the fixture and the server's existing ingest and rollback checks against a disposable PostgreSQL cluster on a Unix socket.

```sh
READINESS_TEST_DSN='postgresql://postgres@/postgres?host=/path/to/disposable/socket&port=55437' \
  bash contract-tests/sleep-candidates/run.sh /path/to/server/worktree core
```

Use `core` with the server sleep projection branch. It checks the Swift-to-server contract, XML provenance and snapshot time, revision ordering, confirmed withdrawals, and rollback. Use `early` with the stacked EnergyBank pilot branch to include early observation and shadow replay checks. Either mode fails if a required test did not run. The optional `legacy` mode rehearses the pre-revision contract on the clean release tree from server PR #280.

## Managed pilot

The release app uses an enabled managed app configuration under `healthSleepCandidatesV1` inside `com.apple.configuration.managed`. Supply an array of dictionaries containing:

- `enabled` as a Boolean.
- `endpoint` as the normalized ingest base URL.
- `profileID` as the stable server profile UUID verified by the operator.
- `credentialFingerprint` as the app's existing endpoint and credential fingerprint, provisioned privately.
- `enrollment` as a UUID assigned to the single verified installation for this profile.
- `confirmation` as a UUID changed after an operator verifies that the same installation and credential can write to the profile in `prepare`.
- `allowNewJournal` as a Boolean for first enrollment only. Remove it after the new writer journal is verified.
- `verifiedBundleOnly` as an optional array of bundle IDs with a single source stream verified on the device. Keep the chosen mapping stable throughout the pilot. Bundle-only identities are ineligible for revision-bound coverage proofs.
- `revisionBound` as a Boolean to opt into device-bound coverage and revisions. Enable it on the core projection server or the EnergyBank pilot server.
- `observeConfirmedDeletions` as a Boolean to opt into anchored HealthKit deletion evidence for revision-bound writes. A lost anchor or an unknown sample leaves coverage uncertain.
- `earlyObservations` as a Boolean to opt into early observations. Enable it only with `revisionBound` and a pilot server that has `HEALTH_SLEEP_EARLY_OBSERVATIONS_ENABLED` enabled. Keep it off for the core projection server.

A key rotation needs a managed entry for the new fingerprint, with the same endpoint, profile and enrollment. An absent ACK holds the packet until a fresh confirmation. A foreign ACK, HTTP 400 or HTTP 409 holds it for receipt and revision reconciliation. After verifying the same account, enrollment, and packet with the server operator, rotating the confirmation permits one retry of the original packet. An older hold written without its confirmation marker requires operator reconciliation. The journal keeps the original packet. A device-only Keychain marker and the journal must agree. Loss of either, a second iPhone, or an unresolved split or merge needs operator reconciliation before use. The file-protected journal contains opaque source IDs, local source names, sample identifiers, interval times and sleep stages, anchor and deletion evidence when enabled, and the pending packet bytes.

Debug builds also accept a single JSON entry with the same fields at
`Library/Application Support/health-sync/development-sleep-candidate-pilot.json`.
It requires an HTTPS endpoint and an exact match to the current credential fingerprint.
Managed candidate configuration takes precedence. The Debug file is absent by default.
Remove it to disable the local pilot while preserving its queue.

The initial candidate scan uses the existing query margin for coverage. The Debug pilot
limits initial uploads to observation windows wholly within its 30-day range. A revision needs a completed local noon-to-noon window in the episode's recorded time zone, including both windows for a date correction. Loss of an interval requires evidence of a replacement. A complete read with no evidence for a previous night records it for review. Review counts and delivery holds are available in the `sleep-candidates` log category.

## Before a pilot or reader rollout

Check real HealthKit permissions, metadata, source stability, Watch and RingConn samples, the managed configuration handoff, and background recovery on the authorized iPhone. Measure packet size, time to ACK, queue age and time to a prepared result. Routing to `serve` also requires server-side suitability and main-session selection, revocation and atomic episode replacement, and proof of convergence across arrival orders for ordinary and candidate writes. Review the agreed history range for every active profile before switching readers.
