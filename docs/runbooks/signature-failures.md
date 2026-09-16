# Runbook: Signature Failures

- Trigger: repeated `MT_CONNECTOR_SIGNATURE_INVALID`.
- Triage: verify sigver, canonical body, and active secret version.
- Mitigation: rotate secret and reconfigure EA if mismatch persists.
- Sequence note: a sequence 409 retry is rebuilt and signed with a fresh
  timestamp. Never treat `MT_CONNECTOR_SIGNATURE_INVALID` as a sequence error,
  and never log the signature, secret, or full connector ID while diagnosing.
