# EA Minimal Responsibility Charter

## Required

- Build and sign envelopes.
- Send heartbeat, snapshot, events, and replay-request payloads.
- Execute command envelopes and emit command-result payloads.

## Forbidden

- No normalization decisions.
- No dedupe decisions.
- No business logic or policy interpretation.
- No secret logging.

## Principle

Keep the EA thin and deterministic. Finatic server-side components own semantics.

## Supported release contract

- MT4 and MT5 source and executable assets must come from the same immutable reviewed tag.
- The package version, EA description, startup log version, source assets, checksums, and provenance record must agree.
- A release candidate is not supported until both compiled EAs pass the controlled signed-ingress staging checklist.
- Never weaken signing or log connector credentials to diagnose a release.
