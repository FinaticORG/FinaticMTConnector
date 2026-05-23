# Contributing

## Who this repository is for

**Finatic MT Connector** is a **public reference** for the customer-hosted MetaTrader push protocol, signing rules, and EA source layout. It exists so integrators and auditors can inspect contracts and verify release checksums.

This is **not** an open-contribution application repository. **We do not accept unsolicited pull requests** from the community. Changes land through Finatic engineering workflows.

## If you are a Finatic engineer

Use the same issue hygiene as other Finatic backend repositories:

| Template | Use when |
|----------|----------|
| **Bug** | Regressions, broken protocol behavior, bad release artifacts |
| **Task** | Refactors, CI, docs, runbook updates |
| **Feature** | New protocol fields, EA capabilities (with product sign-off) |

Every issue should include **Problem / Why**, **Scope and Out of Scope**, **Acceptance Criteria**, and a **Verification Plan**.

Run quality checks before opening a PR:

```bash
uv sync
uv run poe ci-fast
```

EA binaries (`.ex4` / `.ex5`) are built on **Finatic-controlled** Windows runners or the documented local release script — not from arbitrary forks.

## If you are a customer or partner

- **Do not deploy** Finatic cloud infrastructure from this repo. You run the **EA on your MetaTrader terminal** and point it at Finatic ingest URLs from Finatic Connect.
- Install EA builds from **[GitHub Releases](https://github.com/FinaticORG/FinaticMTConnector/releases)** and verify `checksums.sha256`.
- Product documentation: Finatic Connect and the MetaTrader integration guide in Finatic Docs.
- Security concerns: see [SECURITY.md](../SECURITY.md).

## Questions and support

Use your Finatic support or partner channel for integration help. GitHub Issues on this repo are for **Finatic-tracked engineering work**, not general trading or terminal support.
