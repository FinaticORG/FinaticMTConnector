# Runbook: Secret Rotation

- Trigger: routine rotation or suspected secret leak.
- Triage: confirm connector `secret_version` and overlap window.
- Mitigation: issue new secret, reconfigure EA, invalidate stale sessions.
- Sequence state is scoped to connector ID, not secret version. After rotation,
  confirm the same connector resumes from its persisted next sequence. A new
  connector ID starts separate state and can converge only through the bounded
  server-directed 409 recovery.
