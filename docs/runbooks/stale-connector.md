# Runbook: Stale Connector

- Trigger: connector heartbeat missing beyond expected interval.
- Triage: verify connector state, last heartbeat, and sequence progression.
- Mitigation: request snapshot bootstrap and confirm heartbeat recovery.
- Sequence recovery: confirm a single redacted `sequence recovery` diagnostic
  is followed by 2xx progression. Repeated recovery warnings can indicate that
  the same connector configuration is active in another terminal.
