# MT4 EA runtime contract

Source: `FinaticMT4ConnectorEA.mq4`.

## Inputs

- `FinaticConnectorId` — UUID from portal `agent_configuration.connector_id`
- `FinaticConnectorSecret` — one-time secret from connect response
- `FinaticIngestUrl` — Background base + path prefix from `agent_configuration.ingest_url`

## Loop

1. POST heartbeat to ingest URL on timer.
2. POST full snapshot when `snapshot_required` or supervisor requests reconcile.
3. POST incremental `events` when trade activity occurs (OnTradeTransaction in production builds).
4. Load the connector-scoped next sequence from an MT4 terminal global
   variable at startup and persist the next value after every accepted request.
5. For an exact sequence-out-of-order 409, validate the server-provided
   expected sequence, rebuild and re-sign the payload with a fresh timestamp,
   and retry once.

Malformed/unrelated 409s and failed retries do not advance persisted state.
Repeated recovery events emit a redacted duplicate-installation warning; no
connector secret or full connector ID is logged.

Recovery accepts at most `2147483646`, so a successful retry can persist and
reload `2147483647` as the next value. That terminal value is an exhausted
sentinel: the EA refuses to send it and never overflows or wraps the MT4 `int`.

## Security

Production stacks should enable signed envelopes (`FINATIC_PUSH_REQUIRE_INGEST_SIGNATURE`) once EA v0.3.x ships HMAC headers.

Sequence recovery never bypasses HMAC, timestamp, replay, or rate-limit checks.
