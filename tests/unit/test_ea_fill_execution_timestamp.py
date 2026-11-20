"""Static regression: live MT order.fill payloads must carry an execution timestamp.

The fail-closed FinaticCore fill builder reads 'executed_at' from the
broker-native 'time' field via 'mt5_deal_to_fill'. Without it, production MT
ingress silently drops fills as 'MissingOrderExecutionTimestampError'
(FinaticBackground#827). The MT4 and MT5 reference EAs must emit that field on
the live 'order.fill' path so the ingress can persist fills instead of
dropping them.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]
MT4_SOURCE = (
    REPO_ROOT
    / "src/finatic_mt_connector/ea_reference/mt4/FinaticMT4ConnectorEA.mq4"
)
MT5_SOURCE = (
    REPO_ROOT
    / "src/finatic_mt_connector/ea_reference/mt5/FinaticMT5ConnectorEA.mq5"
)

TIME_FIELD_MARKER = r"\"time\":\""


def _live_fill_block(source: str) -> str:
    fill_index = source.index(r"event_type\":\"order.fill")
    closing_index = source.index(");", fill_index)
    return source[fill_index:closing_index]


def test_mt4_live_fill_payload_emits_execution_timestamp() -> None:
    source = MT4_SOURCE.read_text(encoding="utf-8")
    block = _live_fill_block(source)

    assert TIME_FIELD_MARKER in block
    assert "TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS)" in block


def test_mt5_live_fill_payload_emits_execution_timestamp() -> None:
    source = MT5_SOURCE.read_text(encoding="utf-8")
    block = _live_fill_block(source)

    assert TIME_FIELD_MARKER in block
    assert "TimeToString((datetime)trans.time, TIME_DATE|TIME_SECONDS)" in block
