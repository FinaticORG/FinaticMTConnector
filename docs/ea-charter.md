# EA Minimal Responsibility Charter

## Required

- Build and sign envelopes.
- Send heartbeat, snapshot, events, and replay-request payloads.
- Execute command envelopes and emit command-result payloads.
- Persist the connector-scoped next sequence in terminal global state.
- On `MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER`, accept a validated server
  `expected_sequence`, rebuild and re-sign the same payload, and retry once.
- Parse recovery fields only as direct, correctly typed JSON members. Stop
  before sending when the persisted next sequence has reached its platform
  ceiling; never wrap or reuse the exhausted value.

## Forbidden

- No normalization decisions.
- No dedupe decisions.
- No business logic or policy interpretation.
- No secret logging.
- No unbounded retry or relaxation of signature, timestamp, replay, or
  rate-limit enforcement.

## Principle

Keep the EA thin and deterministic. Finatic server-side components own semantics.

## Supported release contract

- MT4 and MT5 source and executable assets must come from the same immutable reviewed tag.
- The package version, EA description, startup log version, source assets, checksums, and provenance record must agree.
- A release candidate is not supported until both compiled EAs pass the controlled signed-ingress staging checklist.
- Never weaken signing or log connector credentials to diagnose a release.
