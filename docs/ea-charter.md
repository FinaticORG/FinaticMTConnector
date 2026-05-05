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
