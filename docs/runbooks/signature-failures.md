# Runbook: Signature Failures

- Trigger: repeated `MT_CONNECTOR_SIGNATURE_INVALID`.
- Triage: verify sigver, canonical body, and active secret version.
- Mitigation: rotate secret and reconfigure EA if mismatch persists.
