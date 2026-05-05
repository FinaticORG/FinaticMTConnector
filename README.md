# Finatic MT Connector

Customer-hosted MetaTrader connector protocol and reference components for MT4 and MT5.

## Scope

- Defines envelope contracts, signing rules, and connector state semantics.
- Provides MT4/MT5 adapter lanes and EA reference sources.
- Supports integration with `finaticAPI`, `FinaticBackground`, and `FinaticBrokerFactoryPKG`.

## Development

```bash
uv sync
uv run poe ci-fast
```
