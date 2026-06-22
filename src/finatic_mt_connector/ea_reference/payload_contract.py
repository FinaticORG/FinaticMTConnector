"""Canonical MT connector payload field names for EAs and integration tests.

These shapes align with FinaticCore stream adapters and
``mt_stream_broker_data_persistence``. Deployed Background webhooks expect
``event_type`` and MT fields at the top level of ``payload`` (not nested under
``events[]``). Reference signed envelopes may batch records; flatten before
POSTing to ``/events`` or rely on Background expansion via
``expand_ingress_event_payloads``.
"""

from __future__ import annotations

from typing import Any


def default_snapshot_payload() -> dict[str, Any]:
    """Minimal snapshot bootstrap shape including accounts for persistence."""
    return {
        "accounts": [
            {
                "login": "1001",
                "currency": "USD",
                "balance": 10_000.0,
                "equity": 10_000.0,
                "free_margin": 10_000.0,
                "margin": 0.0,
            }
        ],
        "positions": [],
        "orders": [],
        "balances": [],
    }


def flatten_event_record_for_webhook(
    event_record: dict[str, Any],
) -> dict[str, Any]:
    """Merge nested event record into flat webhook ``payload`` for ``/events``."""
    event_type = event_record.get("event_type")
    nested = event_record.get("payload")
    flat: dict[str, Any] = {}
    if isinstance(nested, dict):
        flat.update(nested)
    if event_type is not None:
        flat["event_type"] = str(event_type)
    for key in ("event_id", "source_timestamp"):
        if key in event_record and key not in flat:
            flat[key] = event_record[key]
    return flat
