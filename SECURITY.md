# Security Policy

## Supported versions

Security fixes are published for the **current Finatic MT Connector release** and the previous minor version. Download EA binaries and checksums from [GitHub Releases](https://github.com/FinaticORG/FinaticMTConnector/releases) only.

## Reporting a vulnerability

If you believe you have found a security issue in this repository or in published EA artifacts:

1. **Do not** open a public GitHub issue with exploit details.
2. Use [GitHub private vulnerability reporting](https://github.com/FinaticORG/FinaticMTConnector/security/advisories/new) for this repository, **or** contact your Finatic account / support channel if you are a customer or integration partner.

We will acknowledge valid reports and coordinate disclosure with affected parties.

## What belongs in a report

- Affected component (Python package, EA source, signing envelope, release artifact).
- Steps to reproduce with minimal sensitive data (redact connector secrets and account identifiers).
- Impact assessment (confidentiality, integrity, availability).

## Out of scope

- Missing WebRequest allowlist configuration on a customer terminal.
- Connector secrets pasted into EA inputs (customer responsibility).
- Issues in Finatic cloud services (`finaticAPI`, `FinaticBackground`) — report through the appropriate Finatic product channel.

## Secret handling

Connector signing secrets are **never** committed to this repository. Customers receive secrets once from Finatic Connect and configure them locally in the EA. See [Secret rotation runbook](docs/runbooks/secret-rotation.md).
