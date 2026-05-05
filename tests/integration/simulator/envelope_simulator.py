"""Generate signed MT connector envelopes for integration tests."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

from finatic_mt_connector.contracts.envelope import EnvelopeKind
from finatic_mt_connector.security.signing import (
    build_signing_headers,
    sign_payload,
)


@dataclass(frozen=True, slots=True)
class MTEnvelopeSimulationCase:
    """Single simulated ingress case with payload + transport headers."""

    case_name: str
    envelope_payload: dict[str, Any]
    request_headers: dict[str, str]


class MTEnvelopeSimulator:
    """Create positive and negative signed connector envelopes."""

    def __init__(
        self,
        *,
        connector_id: UUID,
        connection_id: UUID,
        connector_secret: str,
        secret_version: int = 1,
    ):
        self.connector_id = connector_id
        self.connection_id = connection_id
        self.connector_secret = connector_secret
        self.secret_version = secret_version
        self._sequence_value = 1

    def _next_sequence(self) -> int:
        sequence_value = self._sequence_value
        self._sequence_value += 1
        return sequence_value

    def _timestamp_now(self) -> str:
        return datetime.now(tz=UTC).isoformat().replace("+00:00", "Z")

    def _base_envelope(
        self,
        *,
        kind: EnvelopeKind,
        payload: dict[str, Any],
        sequence: int | None = None,
    ) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "connector_id": str(self.connector_id),
            "connection_id": str(self.connection_id),
            "secret_version": self.secret_version,
            "sequence": sequence
            if sequence is not None
            else self._next_sequence(),
            "source_timestamp": self._timestamp_now(),
            "envelope_id": str(uuid4()),
            "kind": kind.value,
            "payload": payload,
        }

    def _headers_for_envelope(
        self,
        envelope_payload: dict[str, Any],
        *,
        signature_override: str | None = None,
    ) -> dict[str, str]:
        signing_headers = build_signing_headers(
            secret_value=self.connector_secret, raw_payload=envelope_payload
        )
        signature_value = (
            signature_override or signing_headers.x_finatic_signature
        )
        return {
            "X-Finatic-Sigver": signing_headers.x_finatic_sigver,
            "X-Finatic-Signature": signature_value,
            "X-Finatic-Sequence": signing_headers.x_finatic_sequence,
            "X-Finatic-Timestamp": signing_headers.x_finatic_timestamp,
        }

    def build_events_case(
        self, *, event_records: list[dict[str, Any]] | None = None
    ) -> MTEnvelopeSimulationCase:
        normalized_event_records = event_records or [
            {
                "event_id": str(uuid4()),
                "event_type": "position.upsert",
                "source_timestamp": self._timestamp_now(),
                "payload": {"symbol": "EURUSD", "quantity": 1.0},
            }
        ]
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.EVENTS,
            payload={"events": normalized_event_records},
        )
        return MTEnvelopeSimulationCase(
            case_name="events.valid",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def build_snapshot_case(
        self, *, snapshot_payload: dict[str, Any] | None = None
    ) -> MTEnvelopeSimulationCase:
        normalized_snapshot_payload = snapshot_payload or {
            "positions": [],
            "orders": [],
            "balances": [],
        }
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.SNAPSHOT, payload=normalized_snapshot_payload
        )
        return MTEnvelopeSimulationCase(
            case_name="snapshot.valid",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def build_heartbeat_case(self) -> MTEnvelopeSimulationCase:
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.HEARTBEAT, payload={"status": "alive"}
        )
        return MTEnvelopeSimulationCase(
            case_name="heartbeat.valid",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def build_replay_request_case(
        self, *, expected_sequence: int | None = None
    ) -> MTEnvelopeSimulationCase:
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.REPLAY_REQUEST,
            payload={
                "expected_sequence": expected_sequence or self._sequence_value
            },
        )
        return MTEnvelopeSimulationCase(
            case_name="replay_request.valid",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def invalid_signature_case(self) -> MTEnvelopeSimulationCase:
        valid_case = self.build_events_case()
        invalid_signature_value = "00" * 32
        return MTEnvelopeSimulationCase(
            case_name="events.invalid_signature",
            envelope_payload=valid_case.envelope_payload,
            request_headers=self._headers_for_envelope(
                valid_case.envelope_payload,
                signature_override=invalid_signature_value,
            ),
        )

    def sequence_gap_case(self) -> MTEnvelopeSimulationCase:
        sequence_with_gap = self._next_sequence() + 1
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.EVENTS,
            payload={"events": []},
            sequence=sequence_with_gap,
        )
        return MTEnvelopeSimulationCase(
            case_name="events.sequence_gap",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def stale_timestamp_case(
        self, *, skew_minutes: int = 15
    ) -> MTEnvelopeSimulationCase:
        envelope_payload = self._base_envelope(
            kind=EnvelopeKind.HEARTBEAT, payload={"status": "alive"}
        )
        stale_timestamp = (
            (datetime.now(tz=UTC) - timedelta(minutes=skew_minutes))
            .isoformat()
            .replace("+00:00", "Z")
        )
        envelope_payload["source_timestamp"] = stale_timestamp
        # Re-sign after mutating timestamp so only freshness check should fail.
        return MTEnvelopeSimulationCase(
            case_name="heartbeat.timestamp_skew",
            envelope_payload=envelope_payload,
            request_headers=self._headers_for_envelope(envelope_payload),
        )

    def malformed_payload_case(self) -> MTEnvelopeSimulationCase:
        valid_case = self.build_events_case()
        malformed_payload = dict(valid_case.envelope_payload)
        malformed_payload.pop("payload", None)
        signature_value = sign_payload(self.connector_secret, malformed_payload)
        request_headers = dict(valid_case.request_headers)
        request_headers["X-Finatic-Signature"] = signature_value
        request_headers["X-Finatic-Sequence"] = str(
            malformed_payload["sequence"]
        )
        request_headers["X-Finatic-Timestamp"] = str(
            malformed_payload["source_timestamp"]
        )
        return MTEnvelopeSimulationCase(
            case_name="events.malformed_payload",
            envelope_payload=malformed_payload,
            request_headers=request_headers,
        )
