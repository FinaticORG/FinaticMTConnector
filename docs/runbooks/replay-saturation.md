# Runbook: Replay Saturation

- Trigger: replay requests exceed policy window or high replay frequency.
- Triage: inspect sequence gap metrics and connector offline duration.
- Mitigation: enforce snapshot bootstrap and clear replay backlog.
