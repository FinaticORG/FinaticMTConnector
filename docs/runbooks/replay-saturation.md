# Runbook: Replay Saturation

- Trigger: replay requests exceed policy window or high replay frequency.
- Triage: inspect sequence gap metrics and connector offline duration.
- Correlate replay pressure with the optional `connector_version` only after
  signature validation. The authenticated semantic version can distinguish
  release cohorts, but it must not authorize replay, relax sequence policy, or
  cause legacy envelopes without the field to be rejected.
- Mitigation: enforce snapshot bootstrap and clear replay backlog.
- Recovery boundary: only an exact `MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER` 409
  with direct, correctly typed `error.code` and
  `error.details.expected_sequence` members may reseed the client. The expected
  value must leave a reloadable persisted successor, and the original payload
  is retried once. A second 409 remains a failure and must not create an
  in-call retry loop.
- Record only bounded version/sequence diagnostics. Never log secrets,
  signatures, or the full customer payload during replay triage.
