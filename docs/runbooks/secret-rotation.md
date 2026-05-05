# Runbook: Secret Rotation

- Trigger: routine rotation or suspected secret leak.
- Triage: confirm connector `secret_version` and overlap window.
- Mitigation: issue new secret, reconfigure EA, invalidate stale sessions.
