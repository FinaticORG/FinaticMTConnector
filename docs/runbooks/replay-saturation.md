# Runbook: Replay Saturation

- Trigger: replay requests exceed policy window or high replay frequency.
- Triage: inspect sequence gap metrics and connector offline duration.
- Mitigation: enforce snapshot bootstrap and clear replay backlog.
- Recovery boundary: only an exact `MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER` 409
  with direct, correctly typed `error.code` and
  `error.details.expected_sequence` members may reseed the client. The expected
  value must leave a reloadable persisted successor, and the original payload
  is retried once. A second 409 remains a failure and must not create an
  in-call retry loop.
