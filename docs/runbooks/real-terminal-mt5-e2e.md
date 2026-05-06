# Real MT5 terminal end-to-end (Phase 1 checklist)

Use this when validating `p1-e2e-real-terminal` with hardware you control. Record pass/fail and notes in your release ticket.

## Preconditions

- Finatic API, Background (ingestion on `:8001`), and database are reachable from the machine running MetaTrader 5.
- You have a Finatic account with permission to call `POST /v1/mt/connect` and the portal shows the connector setup flow for your broker slug.
- A GitHub Release of Finatic MT connector artifacts (`.ex5` / checksum file) matching the version documented on the docs download page.

## Steps

1. **Install EA** — Copy the signed `.ex5` from the release into the terminal’s `MQL5/Experts/` tree; compile locally only if your policy requires rebuilding from tagged source.

2. **Create connector** — In the portal, run **MetaTrader → Connect**, choose platform **MT5**, copy the ingest URL, `connector_id`, `connector_secret`, and `secret_version` into EA inputs (or the copy-all JSON block).

3. **Attach, algo trading, WebRequest allowlist** — Attach the EA to one chart; enable **Algo Trading**. In MT5 open **Tools → Options → Expert Advisors** and add the ingest **scheme + host + port** (e.g. `http://localhost:8001`) under **Allow WebRequest for listed URL**. Without this, `WebRequest` calls fail with error 4060 and no heartbeat reaches Background.

4. **First heartbeat** — Confirm within one minute that the connector row transitions from awaiting heartbeat to live (per API or admin query) and Background logs show `STATUS:MT_INGESTION_REQUEST` for `heartbeat` without `429` / `409` errors.

5. **Data plane parity** — After a deliberate account action (e.g. small demo order or balance tick), verify positions/orders or transactions appear in Finatic projections within the SLA you use for MT5 QA (same checks you use for other brokers).

6. **Portal UX** — Confirm the portal “connected” / status indicator matches the backend state after refresh.

## Failure triage

- Signature or timestamp errors → [signature-failures.md](signature-failures.md), verify clock skew and secret version.
- `MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER` → [replay-saturation.md](replay-saturation.md) and restart EA only after understanding gap source.
- No ingress at all → firewall / URL / TLS to Background; confirm EA is posting to `/v1/mt/connectors/{id}/…`.

## Sign-off

Mark the phase complete only when every step above is checked for at least one real account and results are attached to the release or internal QA record.
