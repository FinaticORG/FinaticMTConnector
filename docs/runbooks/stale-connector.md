# Runbook: Stale Connector

- Trigger: connector heartbeat missing beyond expected interval.
- Triage: verify connector state, last heartbeat, and sequence progression.
- After signature validation, compare the optional `connector_version`
  telemetry with the immutable release and checksum expected for that terminal.
  Absence identifies a legacy envelope; a value identifies the signed release
  claim, but neither condition grants authorization or proves artifact integrity
  by itself.
- Mitigation: request snapshot bootstrap and confirm heartbeat recovery.
- Live fill evidence: live `order.fill` payloads carry the broker-native
  `time` field, sourced from broker deal history on MT5 (`DEAL_TIME` /
  `DEAL_TIME_MSC`) or the broker order open time on MT4
  (`OrderOpenTime()`). No synthetic or terminal-clock timestamp is ever
  sent. A live fill that cannot read the broker execution time is not sent
  at all; the EA logs an explicit diagnostic and the history-replay path
  recovers the fill with its broker timestamp.
- A rejected persistence attempt is answered by Background with the stable
  connector-actionable code `MT_INGESTION_PERSIST_REJECTED`. Treat it as
  retryable after correcting the payload, never as a successful ingest, and
  never as proof that the connector is stale.
- Sequence recovery: confirm a single redacted `sequence recovery` diagnostic
  is followed by 2xx progression. Repeated recovery warnings can indicate that
  the same connector configuration is active in another terminal.
- A `sequence exhausted` diagnostic means the EA stopped before sending rather
  than wrapping or reusing a sequence. Reprovision the connector; do not clear
  persisted state to force traffic through.
- Keep diagnostics to the validated semantic version and bounded operational
  fields. Do not log the signed body, connector secret, signature, or customer
  payload while investigating stale traffic.
