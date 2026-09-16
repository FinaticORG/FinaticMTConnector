import json
from io import BytesIO
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError
from uuid import UUID, uuid4

import pytest

from finatic_mt_connector.ea_reference.mt4 import (
    MT4ConnectorConfiguration,
    MT4ReferenceConnector,
)
from finatic_mt_connector.ea_reference.reference_connector_base import (
    MAX_PERSISTED_SEQUENCE,
    MAX_RECOVERABLE_SEQUENCE,
    BaseReferenceConnector,
    ReferenceTransportResponse,
)


def _build_connector(
    *,
    connector_id: UUID | None = None,
    sequence_state_path: Path | None = None,
) -> MT4ReferenceConnector:
    connector_configuration = MT4ConnectorConfiguration(
        platform="mt4",
        connector_id=connector_id or uuid4(),
        connection_id=uuid4(),
        connector_secret="secret-value",
        ingest_base_url="https://ingest.finatic.dev",
        sequence_state_path=sequence_state_path,
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


def test_sequence_409_retries_once_and_restores_persisted_next_sequence(
    tmp_path: Path,
) -> None:
    from finatic_mt_connector.security.signing import verify_payload_signature

    connector_id = uuid4()
    state_path = tmp_path / "mt4-next-sequence"
    connector = _build_connector(
        connector_id=connector_id,
        sequence_state_path=state_path,
    )
    error_body = json.dumps(
        {
            "error": {
                "code": "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",
                "details": {
                    "expected_sequence": 7,
                    "last_acknowledged_sequence": 6,
                },
            }
        }
    ).encode()
    sequence_error = HTTPError(
        "https://ingest.finatic.dev",
        409,
        "Conflict",
        hdrs=None,
        fp=BytesIO(error_body),
    )
    success = MagicMock()
    success.status = 200
    success.read.return_value = b'{"ok":true}'
    success_context = MagicMock()
    success_context.__enter__.return_value = success
    success_context.__exit__.return_value = None

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen",
        side_effect=[sequence_error, success_context],
    ) as mock_urlopen:
        response = connector.push_minimal_signed_snapshot({"accounts": []})

    assert response.status_code == 200
    assert mock_urlopen.call_count == 2
    first_body = json.loads(mock_urlopen.call_args_list[0].args[0].data)
    retry_body = json.loads(mock_urlopen.call_args_list[1].args[0].data)
    assert first_body["sequence"] == 0
    assert retry_body["sequence"] == 7
    retry_signature = (
        mock_urlopen.call_args_list[1].args[0].get_header("X-finatic-signature")
    )
    assert retry_signature
    assert verify_payload_signature(
        secret_value=connector.connector_configuration.connector_secret,
        raw_payload=retry_body,
        signature_value=retry_signature,
    )
    assert state_path.read_text(encoding="utf-8") == "8"

    restarted_connector = _build_connector(
        connector_id=connector_id,
        sequence_state_path=state_path,
    )
    assert restarted_connector._minimal_webhook_sequence == 8


def test_sequence_recovery_boundary_persists_and_reloads_successor(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "mt4-next-sequence"
    connector = _build_connector(sequence_state_path=state_path)
    error_body = json.dumps(
        {
            "error": {
                "code": "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",
                "details": {
                    "expected_sequence": MAX_RECOVERABLE_SEQUENCE,
                },
            }
        }
    ).encode()
    sequence_error = HTTPError(
        "https://ingest.finatic.dev",
        409,
        "Conflict",
        hdrs=None,
        fp=BytesIO(error_body),
    )
    success = MagicMock()
    success.status = 200
    success.read.return_value = b'{"ok":true}'
    success_context = MagicMock()
    success_context.__enter__.return_value = success
    success_context.__exit__.return_value = None

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen",
        side_effect=[sequence_error, success_context],
    ):
        response = connector.push_minimal_heartbeat()

    assert response.status_code == 200
    assert state_path.read_text(encoding="utf-8") == str(MAX_PERSISTED_SEQUENCE)
    restarted_connector = _build_connector(sequence_state_path=state_path)
    assert (
        restarted_connector._minimal_webhook_sequence == MAX_PERSISTED_SEQUENCE
    )

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen"
    ) as mock_urlopen:
        exhausted_response = restarted_connector.push_minimal_heartbeat()

    assert exhausted_response.status_code == 409
    assert "MT_CONNECTOR_SEQUENCE_EXHAUSTED" in exhausted_response.body_text
    mock_urlopen.assert_not_called()


def test_sequence_recovery_rejects_first_unadvanceable_value() -> None:
    response = ReferenceTransportResponse(
        status_code=409,
        body_text=json.dumps(
            {
                "error": {
                    "code": "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",
                    "details": {
                        "expected_sequence": MAX_PERSISTED_SEQUENCE,
                    },
                }
            }
        ),
    )

    assert BaseReferenceConnector._recovery_sequence(response) is None


@pytest.mark.parametrize(
    "body",
    [
        '{"error":{"code":{"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER":0},'
        '"details":{"expected_sequence":7}}}',
        '{"error":{"code":null,"later":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
        '"details":{"expected_sequence":7}}}',
        '{"error":{"code":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
        '"wrapper":{"details":{"expected_sequence":7}},"details":null}}',
        '{"error":{"code":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
        '"details":{"nested":{"expected_sequence":7}}}}',
    ],
)
def test_sequence_recovery_rejects_wrong_typed_or_nested_envelope(
    body: str,
) -> None:
    response = ReferenceTransportResponse(status_code=409, body_text=body)

    assert BaseReferenceConnector._recovery_sequence(response) is None


def test_unrelated_409_does_not_reseed_or_retry() -> None:
    connector = _build_connector()
    sequence_error = HTTPError(
        "https://ingest.finatic.dev",
        409,
        "Conflict",
        hdrs=None,
        fp=BytesIO(b'{"error":{"code":"OTHER_CONFLICT"}}'),
    )

    with patch(
        "finatic_mt_connector.ea_reference.reference_connector_base.request.urlopen",
        side_effect=sequence_error,
    ) as mock_urlopen:
        response = connector.push_minimal_heartbeat()

    assert response.status_code == 409
    mock_urlopen.assert_called_once()
    assert connector._minimal_webhook_sequence == 0
