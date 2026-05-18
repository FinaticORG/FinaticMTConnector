from unittest.mock import MagicMock, patch
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


def test_build_events_envelope_sets_kind_platform_and_events_payload() -> None:
    connector = _build_connector()
    events_envelope = connector.build_events_envelope(
        [{"event_type": "position.upsert", "payload": {"symbol": "EURUSD"}}]
    )

    assert events_envelope["kind"] == "events"
    assert events_envelope["platform"] == "mt5"
    assert "events" in events_envelope["payload"]
    assert len(events_envelope["payload"]["events"]) == 1


def test_build_snapshot_and_heartbeat_increment_sequence() -> None:
    connector = _build_connector()
    from finatic_mt_connector.ea_reference.payload_contract import (
        default_snapshot_payload,
    )

    snapshot_envelope = connector.build_snapshot_envelope(
        default_snapshot_payload()
    )
    heartbeat_envelope = connector.build_heartbeat_envelope()

    assert snapshot_envelope["kind"] == "snapshot"
    assert heartbeat_envelope["kind"] == "heartbeat"
    assert snapshot_envelope["sequence"] == 1
    assert heartbeat_envelope["sequence"] == 2


def test_push_minimal_snapshot_and_event_use_deployed_webhook_shape() -> None:
    from finatic_mt_connector.ea_reference.payload_contract import (
        default_snapshot_payload,
        flatten_event_record_for_webhook,
    )

    connector = _build_connector()
    mock_http_response = MagicMock()
    mock_http_response.status = 200
    mock_http_response.read.return_value = b"{}"
    mock_context = MagicMock()
    mock_context.__enter__.return_value = mock_http_response
    mock_context.__exit__.return_value = None

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen",
        return_value=mock_context,
    ) as mock_urlopen:
        snapshot_response = connector.push_minimal_snapshot(
            default_snapshot_payload()
        )
        flat_event = flatten_event_record_for_webhook(
            {
                "event_type": "balance.update",
                "payload": {"login": "1", "balance": 10.0},
            }
        )
        event_response = connector.push_minimal_flat_event(flat_event)

    assert snapshot_response.status_code == 200
    assert event_response.status_code == 200
    assert mock_urlopen.call_count == 2
    snapshot_url = mock_urlopen.call_args_list[0].args[0].full_url
    assert snapshot_url.endswith("/snapshot")
    event_url = mock_urlopen.call_args_list[1].args[0].full_url
    assert event_url.endswith("/events")


def test_push_minimal_heartbeat_posts_deployed_webhook_shape() -> None:
    connector = _build_connector()
    mock_http_response = MagicMock()
    mock_http_response.status = 200
    mock_http_response.read.return_value = b"{}"
    mock_context = MagicMock()
    mock_context.__enter__.return_value = mock_http_response
    mock_context.__exit__.return_value = None

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen",
        return_value=mock_context,
    ) as mock_urlopen:
        transport_response = connector.push_minimal_heartbeat()

    assert transport_response.status_code == 200
    mock_urlopen.assert_called_once()
    posted_request = mock_urlopen.call_args[0][0]
    posted_full_url = posted_request.full_url
    assert posted_full_url.endswith(
        f"/v1/mt/connectors/{connector.connector_configuration.connector_id}/heartbeat"
    )
    assert connector._minimal_webhook_sequence == 1
