# Open Source Bill of Materials

## Candidate Components

| Component | Upstream | Commit | License | Notes |
|---|---|---|---|---|
| MT5 bridge base | `mobjoy0/mt5-bridge` | `TBD` | `TBD` | Evaluate EA + HTTP/WS patterns for adaptation only. |
| MT4 bridge base | `bonnevoyager/MetaTrader4-Bridge` | `TBD` | `TBD` | Evaluate transport and command surface. |
| Cross-platform reference | `dizengoff/PyTraderMT4-MT5` | `TBD` | `TBD` | Reference protocol and adapter shape. |

## Wrapping Policy

1. Prefer configuration and adapter wrapping before code forking.
2. If a fork is required, pin upstream commit and keep patch set minimal.
3. Add regression tests for every local behavioral patch.

## Sequence-state implementation

MT4 and MT5 sequence persistence and bounded 409 recovery use only native MQL
terminal global variables, JSON/string helpers, `WebRequest`, and cryptographic
functions already present in the EA sources. No additional third-party
component or license is introduced. The fail-closed direct-member parser and
sequence-ceiling guards are implemented in those native helpers as well.

## Live fill execution-time evidence

Live MT `order.fill` payloads carry the broker-native `time` field. MT5 reads
it from the broker deal history selected by the transaction deal ticket
(`HistorySelect`, `HistoryDealSelect`, `HistoryDealGetInteger` with
`DEAL_TIME` / `DEAL_TIME_MSC`); MT4 reads the broker order open time
(`OrderOpenTime()`). No synthetic or terminal-clock timestamp is ever sent.
When the broker execution time is unavailable the EA sends no fill and the
history-replay path recovers it with the broker timestamp. A rejected
persistence attempt is answered by Background with the stable
connector-actionable code `MT_INGESTION_PERSIST_REJECTED`, which the
connector treats as retryable after correcting its payload and never as
success. This change adds no component, package, network service, bundled
source, or license obligation: it uses only native MQL history and order
functions already present in the EA sources.

## Signed release provenance

The `connector_version` ingress field is a constant release marker serialized
inside the existing canonical JSON body and protected by the existing HMAC.
It uses only native MQL string handling and Python standard-library code. This
change adds no component, package, network service, bundled source, or license
obligation. The marker is diagnostic provenance only and contains no secret or
customer identifier.
