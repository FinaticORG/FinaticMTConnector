from uuid import uuid4

from finatic_mt_connector.security.signing import verify_payload_signature
from tests.integration.simulator import MTEnvelopeSimulator


def _build_simulator() -> MTEnvelopeSimulator:
    return MTEnvelopeSimulator(
        connector_id=uuid4(),
        connection_id=uuid4(),
        connector_secret="integration-test-secret",
    )


def test_simulator_builds_valid_signed_events_case() -> None:
    simulator = _build_simulator()
    events_case = simulator.build_events_case()

    assert events_case.envelope_payload["kind"] == "events"
    assert events_case.envelope_payload["payload"]["events"]
    assert verify_payload_signature(
        secret_value="integration-test-secret",
        raw_payload=events_case.envelope_payload,
        signature_value=events_case.request_headers["X-Finatic-Signature"],
    )


def test_simulator_invalid_signature_case_is_detectable() -> None:
    simulator = _build_simulator()
    invalid_case = simulator.invalid_signature_case()

    assert not verify_payload_signature(
        secret_value="integration-test-secret",
        raw_payload=invalid_case.envelope_payload,
        signature_value=invalid_case.request_headers["X-Finatic-Signature"],
    )


def test_simulator_sequence_gap_case_skips_forward() -> None:
    simulator = _build_simulator()
    simulator.build_events_case()
    sequence_gap_case = simulator.sequence_gap_case()

    assert sequence_gap_case.envelope_payload["sequence"] >= 3


def test_simulator_stale_timestamp_case_retains_valid_signature() -> None:
    simulator = _build_simulator()
    stale_case = simulator.stale_timestamp_case(skew_minutes=10)

    assert verify_payload_signature(
        secret_value="integration-test-secret",
        raw_payload=stale_case.envelope_payload,
        signature_value=stale_case.request_headers["X-Finatic-Signature"],
    )


def test_simulator_malformed_payload_case_omits_payload_field() -> None:
    simulator = _build_simulator()
    malformed_case = simulator.malformed_payload_case()

    assert "payload" not in malformed_case.envelope_payload
