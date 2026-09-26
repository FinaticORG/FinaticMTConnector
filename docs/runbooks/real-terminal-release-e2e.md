# MT4 and MT5 signed release acceptance

Use this checklist for each immutable connector release. Record the tag, commit,
artifact hashes, connector IDs (redacted), accepted sequence values, timestamps,
and pass/fail evidence in the release ticket.

## Preconditions

- The reviewed tag resolves to one commit and the GitHub Release contains
  `.mq4`, `.mq5`, `.ex4`, `.ex5`, build logs, provenance, release notes, and
  `checksums.sha256`.
- `sha256sum -c checksums.sha256` succeeds before either binary is installed.
- Staging requires signed ingress and uses the production-equivalent raw-body
  verification contract.
- Use controlled demo terminals and connector credentials. Never put connector
  secrets in screenshots, logs, release notes, or ticket comments.

## Run once for MT4 and once for MT5

1. Copy the released executable into the platform's `Experts` directory. Keep
   the matching released source for audit; do not recompile between checksum
   verification and acceptance.
2. Configure the staging ingest URL, connector ID, connector secret, and secret
   version from Finatic Connect. Leave `FinaticSignEnvelopes=true`.
3. Add the exact ingest scheme and host to **Tools → Options → Expert Advisors
   → Allow WebRequest for listed URL**. MT4 supports standard HTTP/HTTPS ports;
   use the staging HTTPS endpoint rather than a custom port.
4. Attach the EA to one chart, enable automated trading, and confirm its startup
   log reports the release version without exposing credentials.
5. Send a representative non-empty snapshot. Record the accepted sequence and
   confirm staging has no signature-invalid, timestamp-skew, or replay error.
6. Confirm the same signed transport is used for heartbeat, events, snapshot,
   and command-result routes. A successful heartbeat alone is insufficient.

## Acceptance and rollback

Pass only when both platforms complete the checklist against the draft or local
bundle hashes. Publish that exact bundle without recompiling. If either fails,
detach the candidate, restore the prior immutable release, preserve redacted
evidence, and route the release card back through the development loop. Do not
disable signature enforcement as a workaround.
