# Runbook: Signature Failures

- Trigger: repeated `MT_CONNECTOR_SIGNATURE_INVALID`.
- Triage: verify the installed `.ex4` / `.ex5` checksum against its immutable release, confirm the displayed EA version matches the release source, then verify sigver, exact transmitted body, terminal clock, connector ID, and active secret version.
- `connector_version` is part of the canonical signed body for current
  releases. Compare it only after the server has validated the signature; a
  changed value changes the HMAC input. Missing version telemetry is expected
  from legacy envelopes and is not itself a signature or authorization
  failure.
- Confirm the release used the expected `FinaticSignEnvelopes=true` default and that the terminal WebRequest allowlist contains the exact ingest scheme and host.
- Mitigation: restore the prior immutable release if the new artifact is suspect. Rotate a secret only after proving a credential mismatch; do not disable signature enforcement or print the secret.
- Sequence note: a sequence 409 retry is rebuilt and signed with a fresh
  timestamp. Never treat `MT_CONNECTOR_SIGNATURE_INVALID` as a sequence error,
  and never log the signature, secret, or full connector ID while diagnosing.
  Do not log the full signed body or customer payload merely to capture the
  version. Wrong-typed or nested lookalike recovery fields are ignored without
  retry.
