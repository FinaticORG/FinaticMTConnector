# Runbook: Replay Saturation

- Trigger: replay requests exceed policy window or high replay frequency.
- Triage: inspect sequence gap metrics and connector offline duration.
- Correlate replay pressure with the optional `connector_version` only after
  signature validation. The authenticated semantic version can distinguish
  release cohorts, but it must not authorize replay, relax sequence policy, or
  cause legacy envelopes without the field to be rejected.
- Mitigation: enforce snapshot bootstrap and clear replay backlog.
- Fill recovery boundary: a live fill is only sent when the broker execution
  time is readable — broker deal history on MT5 (`DEAL_TIME` /
  `DEAL_TIME_MSC`), broker order open time on MT4 (`OrderOpenTime()`). No
  synthetic or terminal-clock timestamp is ever sent. Fills without broker
  execution evidence are not sent live and are recovered by history replay,
  so replay load is expected to rise, not the fill volume to stay flat.
- A rejected persistence attempt is answered by Background with the stable
  connector-actionable code `MT_INGESTION_PERSIST_REJECTED`. That rejection
  is retryable after correcting the payload and is never a committed success;
  do not acknowledge it as persisted and do not replay it as an unbounded
  loop.
- Recovery boundary: only an exact `MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER` 409
  with direct, correctly typed `error.code` and
  `error.details.expected_sequence` members may reseed the client. The expected
  value must leave a reloadable persisted successor, and the original payload
  is retried once. A second 409 remains a failure and must not create an
  in-call retry loop.
- Record only bounded version/sequence diagnostics. Never log secrets,
  signatures, or the full customer payload during replay triage.
