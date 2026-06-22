# Finatic MT Connector

Customer-hosted MetaTrader 4 and 5 connector — protocol contracts, signing rules, Python reference helpers, and EA source used with Finatic push ingest.

[![CI](https://github.com/FinaticORG/FinaticMTConnector/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/FinaticORG/FinaticMTConnector/actions/workflows/ci.yml)

## What this repository is

| In scope | Out of scope |
|----------|----------------|
| Envelope shape, HMAC signing, connector state semantics | Hosting Finatic API or Background |
| MT4/MT5 EA **reference** source (`.mq4` / `.mq5`) | Customer connector secrets in git |
| Python helpers and tests for protocol compliance | Unsolicited community feature development |

Integrators run the **compiled EA** on their own terminal. Finatic operates ingest (`FinaticBackground`) and broker data projection (`FinaticCore`) in separate private repositories.

## Who should use what

- **Customers** — Download `.ex4` / `.ex5` from [Releases](https://github.com/FinaticORG/FinaticMTConnector/releases), verify `checksums.sha256`, configure inputs from Finatic Connect. See Finatic Docs (MetaTrader) for WebRequest allowlisting and MT4 port 80 notes.
- **Finatic engineers** — Change protocol or EA source here; run CI; publish via the EA build workflow or local Windows release scripts.
- **Auditors / partners** — Read source and docs; report security issues via [SECURITY.md](SECURITY.md).

We do **not** accept unsolicited pull requests. See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Quick start (development)

```bash
uv sync
uv run poe ci-fast
```

| Task | Command |
|------|---------|
| Lint | `uv run poe lint` |
| Typecheck | `uv run poe typecheck` |
| Tests (fast) | `uv run poe test-fast` |
| Full CI locally | `uv run poe ci-fast` |

## Documentation

- Index: [docs/index.md](docs/index.md)
- EA charter: [docs/ea-charter.md](docs/ea-charter.md)

## EA releases (Finatic-built binaries only)

Published artifacts are produced on Finatic-controlled build paths (GitHub Actions on a Windows runner, or the local release script). Customers should **not** treat random `.ex4` / `.ex5` builds as supported unless they match a tagged release and checksum file.

**Local Windows release** (Finatic maintainers):

```powershell
uv run poe release-local
```

Publish after review:

```powershell
uv run poe release-local-publish
```

Requires MetaEditor for MT4 and MT5, plus `gh auth login` when publishing. Non-default MetaEditor paths are supported via `scripts/release/local_release.ps1` parameters (documented in that script).

## Related Finatic repositories

- [finaticAPI](https://github.com/FinaticORG/finaticAPI) — connect flow and connector registration
- [FinaticBackground](https://github.com/FinaticORG/FinaticBackground) — push ingest webhooks and scheduling
- [FinaticCore](https://github.com/FinaticORG/FinaticCore) — broker data persistence for MT stream events

## License

MIT — see [LICENSE](LICENSE).
