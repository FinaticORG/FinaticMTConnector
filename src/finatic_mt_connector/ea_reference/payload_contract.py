"""Canonical MT connector payload field names for EAs and integration tests.

These shapes align with FinaticCore stream adapters and
``mt_stream_integration_persistence``. Deployed Background webhooks expect
``event_type`` and MT fields at the top level of ``payload`` (not nested under
``events[]``). Reference signed envelopes may batch records; flatten before
POSTing to ``/events`` or rely on Background expansion via
``expand_ingress_event_payloads``.

**Connection vs account:** one broker login maps to one ``user_broker_connection``.
The snapshot ``accounts[]`` array may contain **multiple trading accounts** (each
``login`` becomes one ``integration.accounts`` row under that connection).
"""

from __future__ import annotations

from typing import Any


def _default_account_row(
    *,
    login: str,
    currency: str,
    balance: float,
) -> dict[str, Any]:
    return {
        "login": login,
        "currency": currency,
        "balance": balance,
        "equity": balance,
        "free_margin": balance,
        "margin": 0.0,
    }


def default_snapshot_payload() -> dict[str, Any]:
    """Minimal snapshot bootstrap shape including accounts for persistence."""
    return {
        "accounts": [
            _default_account_row(login="1001", currency="USD", balance=10_000.0)
        ],
        "positions": [],
        "orders": [],
        "balances": [],
    }


def multi_account_snapshot_payload() -> dict[str, Any]:
    """Snapshot with two trading accounts under one broker connection."""
    return {
        "accounts": [
            _default_account_row(
                login="1001", currency="USD", balance=10_000.0
            ),
            _default_account_row(login="2002", currency="EUR", balance=5_000.0),
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
