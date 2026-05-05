# Runbook: Stale Connector

- Trigger: connector heartbeat missing beyond expected interval.
- Triage: verify connector state, last heartbeat, and sequence progression.
- Mitigation: request snapshot bootstrap and confirm heartbeat recovery.
