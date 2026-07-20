# DRY and Observability Audit

This runbook captures the Phase 3 DRY/observability audit for MT connector work across:

- `FinaticMTConnector`
- `FinaticBackground`
- `FinaticCore`
- `finaticAPI` (control-plane verification pass)

## Audit Date

- 2026-05-06 (UTC)

## DRY Findings and Actions

1. Shared MT inbound adapter logic in BrokerFactory:
   - Action: Introduced `BaseMtInboundStreamAdapterClass` under `brokers/mt_common/streaming/`.
   - MT4 and MT5 inbound adapters now only declare broker identity (`BROKER_ID`) and reuse shared normalization behavior.
   - Outcome: Removed duplicated payload/event-type/metadata shaping logic across MT4 and MT5.

2. Connector state model consistency in MTConnector:
   - Action: Removed `LIVE_WEBSOCKET` state and websocket-only transitions from connector state machine.
   - Outcome: State model now reflects webhook-only transport policy used in v1.

3. Ingestion dedupe and sequence ownership:
   - Verified that dedupe/sequence/replay/cooldown checks remain centralized in `FinaticBackground/src/streaming/mt_ingestion/*`.
   - Outcome: No duplicate dedupe engine introduced in other repos.

## Observability Findings and Actions

1. MT ingestion telemetry namespace consistency:
   - Verified CloudWatch counters are emitted through `CloudWatchMetrics.emit_custom_counter` in `FinaticBackground` namespace.
   - Added/validated MT ingestion counters for request, accepted, duplicate, replay-window exceeded, cooldown set, error totals, command backlog, and ingestion latency.

2. Stable structured logging fields:
   - Verified MT ingestion logs include stable dimensions such as:
     - `connector_id`
     - `kind`
     - `connector_tier`
     - `pending_command_count`
     - `processing_latency_ms`
   - Outcome: Log fields align with dashboard/alert correlation requirements.

## finaticAPI Check

- Verified current `finaticAPI` scope remains MT control-plane aligned (no duplicate data-plane ingestion implementation in API).
- Outcome: Service ownership split remains intact (`finaticAPI` control plane, `FinaticBackground` data plane).

## Result

- DRY audit status: PASS
- Observability audit status: PASS
