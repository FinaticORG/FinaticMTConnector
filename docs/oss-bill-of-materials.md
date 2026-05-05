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
