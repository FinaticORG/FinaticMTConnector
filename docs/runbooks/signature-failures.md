# Runbook: Signature Failures

- Trigger: repeated `MT_CONNECTOR_SIGNATURE_INVALID`.
- Triage: verify the installed `.ex4` / `.ex5` checksum against its immutable release, confirm the displayed EA version matches the release source, then verify sigver, exact transmitted body, terminal clock, connector ID, and active secret version.
- Confirm the release used the expected `FinaticSignEnvelopes=true` default and that the terminal WebRequest allowlist contains the exact ingest scheme and host.
- Mitigation: restore the prior immutable release if the new artifact is suspect. Rotate a secret only after proving a credential mismatch; do not disable signature enforcement or print the secret.
