# Runbook: Secret Rotation

- Trigger: routine rotation or suspected secret leak.
- Triage: confirm connector `secret_version` and overlap window.
- After a request signature validates, record the optional
  `connector_version` alongside the secret-version transition to distinguish
  immutable release cohorts. The connector version is provenance only: it does
  not select a secret, authorize the request, or replace checksum verification,
  and legacy envelopes may omit it.
- Mitigation: issue new secret, reconfigure EA, invalidate stale sessions.
- Sequence state is scoped to connector ID, not secret version. After rotation,
  confirm the same connector resumes from its persisted next sequence. A new
  connector ID starts separate state and can converge only through the bounded
  server-directed 409 recovery.
- If the stored next sequence is at the platform ceiling, rotation alone does
  not reset it; reprovision the connector identity rather than reusing a value.
- Do not log the connector secret, HMAC, full signed body, or customer payload
  when correlating release and rotation telemetry.
