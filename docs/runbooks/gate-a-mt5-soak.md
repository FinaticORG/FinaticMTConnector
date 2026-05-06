# Gate A — MT5 stability and ingress invariants (24h soak)

Gate A is the decision point before treating MT5 as production-ready for customer-hosted connectors and before prioritizing MT4 rollout at scale. **Engineering owner** runs or supervises the soak; **sign-off** requires clean metrics and the checklist below.

## Scope

- **Ingress**: HTTPS webhook path (`/v1/mt/connectors/{id}/events|snapshot|heartbeat|replay`) with HMAC, monotonic sequence, dedupe, and rate limits as implemented in Finatic Background.
- **Polling / trading**: Workers using broker id `mt5` remain stable (no unbounded errors, no stuck connections) for the soak window.
- **Duration**: Minimum **24 continuous hours** with representative traffic (at least one connector sending heartbeats on schedule and periodic events or snapshots as in production).

## Monitoring (what to watch)

- Background logs: rate limit (`MT_CONNECTOR_RATE_LIMITED`), sequence (`MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER`), signature failures (when verification is enabled end-to-end).
- Application metrics or traces for ingestion latency and worker job failures, if available in your environment.
- Database: connector state transitions, `last_sequence`, `last_heartbeat_at` advancing as expected.

## Pass criteria

- No sustained spike in 4xx/5xx on ingress attributable to server bugs (isolated client misconfiguration may be documented separately).
- No memory or connection leaks on Background or workers requiring restart.
- Sequence and idempotency: replays and duplicate deliveries do not corrupt projected state (manual spot-check or automated reconciliation diff).
- Trading path: at least one successful place + cancel or modify roundtrip via the MT5 command channel during or immediately after the soak, on a demo account.

## Sign-off

When all pass criteria hold for the full window, record the time range, environment (staging vs production), and monitoring links, then mark Gate A approved in the program plan. If anything fails, file issues, fix, and **restart the soak** from a clean window.
