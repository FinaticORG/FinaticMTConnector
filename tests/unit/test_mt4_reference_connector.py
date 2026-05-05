from uuid import uuid4

from finatic_mt_connector.ea_reference.mt4 import (
    MT4ConnectorConfiguration,
    MT4ReferenceConnector,
)


def _build_connector() -> MT4ReferenceConnector:
    connector_configuration = MT4ConnectorConfiguration(
        platform="mt4",
        connector_id=uuid4(),
        connection_id=uuid4(),
        connector_secret="secret-value",
        ingest_base_url="https://ingest.finatic.dev",
    )
    return MT4ReferenceConnector(connector_configuration)


def test_mt4_reference_connector_builds_events_envelope() -> None:
    connector = _build_connector()
    events_envelope = connector.build_events_envelope(
        [{"event_type": "order.upsert", "payload": {"symbol": "XAUUSD"}}]
    )
    assert events_envelope["kind"] == "events"
    assert (
        events_envelope["payload"]["events"][0]["event_type"] == "order.upsert"
    )
