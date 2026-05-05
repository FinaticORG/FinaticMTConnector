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

## Local Windows Release (Binary-Only)

Use your Windows machine to produce `.ex4` and `.ex5` before publishing:

```powershell
uv run poe release-local
```

This command:
- runs local quality checks
- bumps project version (patch by default)
- compiles MT4/MT5 EAs via local MetaEditor
- writes `dist/ea` artifacts and `checksums.sha256`
- creates local commit + tag

To publish immediately from your machine:

```powershell
uv run poe release-local-publish
```

Prerequisites on the Windows machine:
- MetaTrader 4 with `metaeditor.exe`
- MetaTrader 5 with `metaeditor64.exe`
- authenticated GitHub CLI (`gh auth login`)
