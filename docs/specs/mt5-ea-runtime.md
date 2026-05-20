# MT5 EA runtime contract

Source: `FinaticMT5ConnectorEA.mq5` (v3.00).

## Inputs

- `FinaticConnectorId` — UUID from portal `agent_configuration.connector_id`
- `FinaticConnectorSecret` — one-time secret from connect response
- `FinaticIngestUrl` — Background base + path prefix from `agent_configuration.ingest_url`

## Loop

1. POST heartbeat to ingest URL on timer.
2. POST full snapshot when `snapshot_required` or supervisor requests reconcile.
3. POST incremental `events` when trade activity occurs (OnTradeTransaction in production builds).

## Security

Production stacks should enable signed envelopes (`FINATIC_PUSH_REQUIRE_INGEST_SIGNATURE`) once EA v0.3.x ships HMAC headers.
