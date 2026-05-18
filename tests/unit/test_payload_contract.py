"""Unit tests for MT EA payload contract helpers."""

from __future__ import annotations

from finatic_mt_connector.ea_reference.payload_contract import (
    default_snapshot_payload,
    flatten_event_record_for_webhook,
)


def test_default_snapshot_includes_accounts() -> None:
    snap = default_snapshot_payload()
    assert "accounts" in snap
    assert len(snap["accounts"]) >= 1
    assert snap["accounts"][0]["login"] == "1001"


def test_flatten_event_record_for_webhook() -> None:
    flat = flatten_event_record_for_webhook(
        {
            "event_type": "balance.upsert",
            "payload": {"login": "9", "balance": 1.0},
        }
    )
    assert flat["event_type"] == "balance.upsert"
    assert flat["login"] == "9"
    assert flat["balance"] == 1.0
