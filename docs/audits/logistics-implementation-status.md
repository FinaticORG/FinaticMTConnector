# MT customer-hosted connector — implementation status audit

**Purpose:** Map the Cursor plan [`mt_customer_hosted_connector_aea9ef62.plan.md`](file:///home/vscode/.cursor/plans/mt_customer_hosted_connector_aea9ef62.plan.md) (Phase 1 + 1.5 + 1.6) to **concrete code** and call out **gaps**. Last reviewed from repo paths under `/workspaces/Finatic`.

**Verification commands (automated slice):**

- `FinaticBackground`: `uv run pytest tests/unit/test_mt_ingestion.py tests/integration/test_mt_webhook_e2e.py` → **21 passed** (as of audit write).
- `finaticAPI`: `uv run pytest tests/unit/routers/mt_connectors/ tests/unit/test_mt_connector_service.py` → **12 passed** (2026-05-15).
- `FinaticConnect`: `yarn vitest run src/features/mt-connect/MTConnectScreen.test.tsx` → **3 passed**.
- `FinaticBrokerFactoryPKG` (MT4/MT5 slice): `uv run pytest tests/unit/brokers/mt5/test_mt5_mapping_and_stream_adapter.py tests/unit/brokers/mt4/test_mt4_mapping_and_stream_adapter.py` → **16 passed** (2026-05-15; includes `command_result` adapter mapping).
- `FinaticBackground` (MT command queue + command_result store): `uv run pytest tests/unit/test_mt_command_queue.py tests/unit/test_mt_command_result_store.py` → **4 passed** (2026-05-15).

---

## 1. Control plane (`finaticAPI`)

| Plan id | Plan claim | Evidence | Status |
|--------|------------|----------|--------|
| `p1-api-mt-router` | MT REST routes | `codebases/Backend/finaticAPI/src/finaticapi/api/v1/routers/mt_connectors/mt_connectors_router.py` — `POST /mt/connect`, `POST /mt/disconnect`, `GET /mt/connections`, `POST /mt/connectors/{connector_id}/rotate-secret`, `POST /mt/connectors/{connector_id}/revoke`. Mounted via `.../mt_connectors/router.py`. | **Done** |
| `p1-api-connect-service` | Service lifecycle | `.../core/services/mt_connector_service.py` — `create_connector`, `list_connectors`, `rotate_secret`, `revoke_connector`, `build_ea_configuration_payload`; persists `MtConnectors` with encrypted signing secret. | **Done** |
| `p1-api-tests` | Unit tests | `tests/unit/routers/mt_connectors/test_mt_connectors_router.py`, `tests/unit/test_mt_connector_service.py` (see pytest command above). | **Done** |
| `p1-api-mt-order-bridge` | Orders → MT command queue | `.../core/services/broker_service.py` — live `mt4`/`mt5` `place_order` / `cancel_order` / `modify_order`: `MTConnectorService.get_connector_id_for_connection` supplies `connector_id`; `create_broker` passes `redis_client` for executor enqueue. Missing `mt_connectors` row → `MT_CONNECTOR_NOT_FOUND`. Sandbox skips MT order context. **Gap:** `command_result` ingress + blocking API semantics remain Phase 1.5 (`p1-5-command-roundtrip`). | **Partial** |
| `p1-5-control-plane-linkage` | Connect creates **broker connection +** MT row | **Done (2026-05-18):** `BrokerService._connect_push_agent_broker` for `mt4`/`mt5` creates `user_broker_connections`, `company_access`, and `mt_connectors` in one transaction; `POST /api/beta/brokers/connect` returns `agent_configuration`. Portal `MTConnectScreen` uses `connectPushAgentBroker`. Legacy `POST /mt/connect` delegates to the same path. FK `fk_mt_connectors_connection_id` migration `20260518120000_mt_connectors_connection_fk.sql`. | **Done** |

---

## 2. Ingress transport (`FinaticBackground`)

| Plan id | Plan claim | Evidence | Status |
|--------|------------|----------|--------|
| `p1-bg-command-result-endpoint` | `POST .../command-result` | `webhook_routes.py` — `@router.post("/{connector_id}/command-result")`; `command_result_store.py` writes `mt:command:result:{connector_id}:{command_id}`; requires `payload.command_id`. | **Done** |
| `p1-bg-events-endpoint` | `POST .../events` | `webhook_routes.py` — `@router.post("/{connector_id}/events")` (prefix `/v1/mt/connectors`). | **Done** |
| `p1-bg-snapshot-endpoint` | `POST .../snapshot` | Same file — `@router.post("/{connector_id}/snapshot")`. | **Done** |
| `p1-bg-heartbeat-endpoint` | `POST .../heartbeat` | Same file — `@router.post("/{connector_id}/heartbeat")`; `_heartbeat_should_schedule_snapshot`, Postgres heartbeat via `MtConnectorIngressRepositoryService`. | **Done** |
| `p1-bg-replay-endpoint` | `POST .../replay` | Same file — `@router.post("/{connector_id}/replay")`. | **Done** |
| `p1-bg-tests` | Ingress tests | `tests/unit/test_mt_ingestion.py`, `tests/integration/test_mt_webhook_e2e.py`. | **Done** |
| `p1-5-signed-ingress-enforcement` | Always signed in prod | `mt_ingress_verification.py` — `finatic_mt_ingest_requires_signature_verify()` reads `FINATIC_MT_REQUIRE_INGEST_SIGNATURE`. **Gap:** default path can remain unsigned until env is set in every deployed environment. | **Config + policy** |
| `p1-5-bootstrap-live-transition` | LIVE only after snapshot projected | `record_heartbeat_and_maybe_go_live` (repository) + orchestration in `_process_ingress` — **Gap:** confirm state machine matches plan text (AWAITING_FIRST_HEARTBEAT → LIVE only after snapshot acceptance); document exact transitions in follow-up. | **Verify** |

**Projector path**

- `webhook_routes.py` resolves `NormalizedBrokerStreamEvent` and calls `get_registered_stream_projector().enqueue(...)`.
- `stream_projector.py` enqueues **polling sync** work on Redis (`polling:tasks`) with payload `type: websocket_projection` / `source: websocket_stream` naming — **works for MT** but naming is legacy; **no direct broker_data row upsert** here.

| Plan id | Gap | Status |
|--------|-----|--------|
| `p1-5-projector-persistence-integration` | **Done (push path):** `webhook_routes.py` calls `persist_mt_stream_event_to_broker_data` for `mt4`/`mt5` and does **not** enqueue `StreamProjector`. Polling worker skips `mt4`/`mt5` (`SKIPPED:POLL_SYNC_MT_PUSH_INGRESS`). Broker `get_*` raises push-only `NotImplementedError`. | **Done (push-only)** |

---

## 3. Normalization (`FinaticBrokerFactoryPKG`)

| Plan id | Evidence | Status |
|--------|----------|--------|
| `p0-bf-inbound-base`, inbound context | `core/standard_models/streaming/base_inbound_broker_stream_adapter.py`, `inbound_broker_stream_context.py`. | **Done** |
| `p1-bf-mt5-package`, `p1-bf-mt5-register` | `brokers/mt5/__init__.py` — `@BrokerFactory.register("mt5")` `Mt5BrokerClass`; factory imports in `core/broker_factory.py`. | **Done** |
| `p1-bf-mt5-stream-adapter` | `brokers/mt5/streaming/mt5_stream_adapter.py` + mt4 mirror — handles `command_result` ingress kind (`normalized_payload.command_result`). | **Done** |
| `p1-bf-mt5-mapping` | `brokers/mt5/mapping.py` — mappers exist; **coverage** vs full `schema_sql_models_broker_data_latest` is still Phase 1.5 work. | **Partial** |
| `p1-bf-mt5-fetcher` | `brokers/mt5/fetcher.py` + `brokers/mt_common/snapshot_schedule.py` — `reconcile_snapshot` sets `snapshot_request_enqueued` when snapshot is due for **`webhook` or `websocket`**; unknown push modes do not schedule. MT4 fetcher aligned. **Follow-up:** wire this flag into polling supervisor → `snapshot_due_at` / EA hint end-to-end (Phase 1.5). | **Done (scheduling semantics)** |
| `p1-bf-mt5-executor` | `brokers/mt5/executor.py` + `brokers/mt4/executor.py` + `mt_common/mt_command_queue_client.py` — when `redis_client` and `connector_id` are set, commands enqueue as JSON on `mt:commands:{connector_id}` (same keys as Background). `Mt4BrokerClass` / `Mt5BrokerClass` pass `connector_id` from `kwargs` and optional `redis_client` in `__init__`. **Gap:** blocking wait for EA `command_result` / correlation is Phase 1.5. | **Done (enqueue path)** |
| `p1-bf-mt5-tests` | Unit tests cover fetcher scheduling + executor Redis enqueue with fakes; full ingress roundtrip + `command_result` await — **Open**. | **Open** |
| `p1-mt4-parallel` | MT4 mirrors MT5 executor enqueue + broker kwargs; parity bar otherwise same as prior audit. | **Partial** |

---

## 4. Portal & docs (`FinaticConnect`, `FinaticWeb`)

| Plan id | Evidence | Status |
|--------|----------|--------|
| `p1-fc-route-branch` | `src/routes/(portal)/broker/$brokerName/auth.tsx` imports and renders `MTConnectScreen` for MT brokers. | **Done** |
| `p1-fc-mt-screen` | `src/features/mt-connect/MTConnectScreen.tsx` + `mt-download-urls.ts`. | **Done** |
| `p1-fc-credentials-action` | `portal.service.ts` — `POST .../mt/connect`, rotate/revoke/list; screen uses mutations. | **Done** |
| `p1-fc-tests` | `MTConnectScreen.test.tsx`. | **Done** |
| `p1-fw-screenshots` | No `apps/web/public/images/docs/mt/` evidence in this audit pass. | **Open** |
| `p1-5-portal-status-parity` | MT row in manage UI / badges parity with other brokers — **not audited line-by-line**; treat as **Open** until explicit UX review + tests. | **Open** |

---

## 5. EA reference (`FinaticMTConnector`)

| Plan id | Evidence | Status |
|--------|----------|--------|
| `p1-ea-mt5-source`, `p1-ea-mt4-source` | `src/finatic_mt_connector/ea_reference/mt5/`, `mt4/` — files exist; **richness** vs Phase 1.6 spec (full snapshot, signing, retry) still **Open**. | **Partial** |

---

## 6. Phase 1.5 / 1.6 (remaining backbone)

All `p1-5-*` items except this audit file: treat as **Open** until each has an explicit PR + test hook:

- Uniqueness constraints + API validation (`p1-5-uniqueness-constraints`, `p1-5-schema-and-sqlmodel-alignment`).
- Field matrix + canonical expansion (`p1-5-mt-field-coverage-matrix`, `p1-5-canonical-mapping-expansion`).
- Delta / full reconcile / command roundtrip (`p1-5-delta-sync-loop`, `p1-5-full-reconcile-loop`, `p1-5-command-roundtrip`).
- End-to-end integration suite (`p1-5-integration-tests-parity`, Gate A2).

Phase **1.6** OSS baseline docs + EA hardening: **Open** (see plan todos `p1-6-*`).

---

## 7. Recommended execution order (next PRs)

1. **Fix MT5 fetcher for webhook** (`push_mode == "webhook"`) — **done** via `mt_common/snapshot_schedule.py`; next: wire `snapshot_request_enqueued` into polling supervisor → `snapshot_due_at` / EA responses.
2. **Wire executor** to Redis `MTCommandQueueService` / ingress `pending_commands` (same semantics as Background responses). — **Enqueue path done** from BrokerFactory when `redis_client` + `connector_id`; **await `command_result`** still Phase 1.5.
3. **Persistence:** extend projector or add MT-specific projection consumer so snapshot/events materialize **broker_data** tables per `p1-5-projector-persistence-integration`.
4. **Portal parity + uniqueness** (`p1-5-portal-status-parity`, `p1-5-uniqueness-constraints`).
5. **Phase 1.6** EA + docs baselines + Gate B2.

---

## Changelog

- **2026-05-15** — MT5/MT4 executors: Redis command enqueue (`MTConnectorCommandPublisher`); Background `MTCommandQueueService` JSON payloads; BrokerFactoryPKG MT unit tests extended.
- **2026-05-15** — Background: `POST /v1/mt/connectors/{id}/command-result` + `MTCommandResultStoreService` (Redis); MT inbound adapters handle `command_result` kind.
