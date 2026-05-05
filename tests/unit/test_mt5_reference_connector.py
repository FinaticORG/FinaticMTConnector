from uuid import uuid4

from finatic_mt_connector.ea_reference.mt5 import (
    MT5ConnectorConfiguration,
    MT5ReferenceConnector,
)


def _build_connector() -> MT5ReferenceConnector:
    connector_configuration = MT5ConnectorConfiguration(
        platform="mt5",
        connector_id=uuid4(),
        connection_id=uuid4(),
        connector_secret="secret-value",
        ingest_base_url="https://ingest.finatic.dev",
    )
    return MT5ReferenceConnector(connector_configuration)


def test_build_events_envelope_sets_kind_and_events_payload() -> None:
    connector = _build_connector()
    events_envelope = connector.build_events_envelope(
        [{"event_type": "position.upsert", "payload": {"symbol": "EURUSD"}}]
    )

    assert events_envelope["kind"] == "events"
    assert "events" in events_envelope["payload"]
    assert len(events_envelope["payload"]["events"]) == 1


def test_build_snapshot_and_heartbeat_increment_sequence() -> None:
    connector = _build_connector()
    snapshot_envelope = connector.build_snapshot_envelope(
        {"positions": [], "orders": []}
    )
    heartbeat_envelope = connector.build_heartbeat_envelope()

    assert snapshot_envelope["kind"] == "snapshot"
    assert heartbeat_envelope["kind"] == "heartbeat"
    assert snapshot_envelope["sequence"] == 1
    assert heartbeat_envelope["sequence"] == 2
