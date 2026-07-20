from unittest.mock import MagicMock, patch
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


def test_build_events_envelope_sets_kind_and_platform() -> None:
    connector = _build_connector()
    events_envelope = connector.build_events_envelope(
        [{"event_type": "position.upsert", "payload": {"symbol": "EURUSD"}}]
    )

    assert events_envelope["kind"] == "events"
    assert events_envelope["platform"] == "mt4"
    assert "events" in events_envelope["payload"]


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


def test_push_minimal_signed_snapshot_sends_hmac_headers() -> None:
    import json

    from finatic_mt_connector.ea_reference.payload_contract import (
        multi_account_snapshot_payload,
    )
    from finatic_mt_connector.security.signing import verify_payload_signature

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
        transport_response = connector.push_minimal_signed_snapshot(
            multi_account_snapshot_payload()
        )

    assert transport_response.status_code == 200
    posted_request = mock_urlopen.call_args[0][0]
    signature_header = posted_request.get_header("X-finatic-signature")
    assert signature_header
    signable_body = json.loads(posted_request.data.decode("utf-8"))
    assert signable_body["platform"] == "mt4"
    assert len(signable_body["payload"]["accounts"]) == 2
    assert verify_payload_signature(
        secret_value=connector.connector_configuration.connector_secret,
        raw_payload=signable_body,
        signature_value=signature_header,
    )
