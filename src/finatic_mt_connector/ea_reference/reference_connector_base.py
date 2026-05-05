"""Shared transport and envelope utilities for EA references."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib import request
from uuid import UUID, uuid4

from finatic_mt_connector.contracts.envelope import EnvelopeKind
from finatic_mt_connector.security.signing import build_signing_headers


@dataclass(frozen=True, slots=True)
class ReferenceConnectorConfiguration:
    """Runtime connector configuration copied into the EA settings form."""

    platform: str
    connector_id: UUID
    connection_id: UUID
    connector_secret: str
    ingest_base_url: str
    secret_version: int = 1
    signing_scheme_version: int = 1
    timestamp_skew_seconds: int = 300


@dataclass(frozen=True, slots=True)
class ReferenceTransportResponse:
    """Basic HTTP response shape returned by transport calls."""

    status_code: int
    body_text: str


class BaseReferenceConnector:
    """Reference connector focused on envelope + transport behavior."""

    def __init__(
        self, connector_configuration: ReferenceConnectorConfiguration
    ):
        self.connector_configuration = connector_configuration
        self._next_sequence = 1

    def _next_sequence_value(self) -> int:
        current_sequence = self._next_sequence
        self._next_sequence += 1
        return current_sequence

    def _build_envelope(
        self,
        *,
        kind: EnvelopeKind,
        payload: dict[str, Any],
        sequence: int | None = None,
    ) -> dict[str, Any]:
        envelope_sequence = (
            self._next_sequence_value() if sequence is None else sequence
        )
        source_timestamp = (
            datetime.now(tz=UTC).isoformat().replace("+00:00", "Z")
        )
        return {
            "schema_version": 1,
            "connector_id": str(self.connector_configuration.connector_id),
            "connection_id": str(self.connector_configuration.connection_id),
            "secret_version": self.connector_configuration.secret_version,
            "sequence": envelope_sequence,
            "source_timestamp": source_timestamp,
            "envelope_id": str(uuid4()),
            "kind": kind.value,
            "payload": payload,
        }

    def build_snapshot_envelope(
        self, snapshot_payload: dict[str, Any]
    ) -> dict[str, Any]:
        """Build snapshot envelope for baseline state synchronization."""
        return self._build_envelope(
            kind=EnvelopeKind.SNAPSHOT, payload=snapshot_payload
        )

    def build_events_envelope(
        self, event_records: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Build events envelope for incremental state updates."""
        return self._build_envelope(
            kind=EnvelopeKind.EVENTS, payload={"events": event_records}
        )

    def build_heartbeat_envelope(
        self, heartbeat_payload: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        """Build heartbeat envelope for liveness checks."""
        return self._build_envelope(
            kind=EnvelopeKind.HEARTBEAT,
            payload=heartbeat_payload or {"status": "alive"},
        )

    def _post_signed_envelope(
        self, *, endpoint_path: str, envelope: dict[str, Any]
    ) -> ReferenceTransportResponse:
        signing_headers = build_signing_headers(
            secret_value=self.connector_configuration.connector_secret,
            raw_payload=envelope,
        )
        request_url = (
            f"{self.connector_configuration.ingest_base_url.rstrip('/')}"
            f"/v1/mt/connectors/{self.connector_configuration.connector_id}"
            f"/{endpoint_path.lstrip('/')}"
        )
        request_headers = {
            "Content-Type": "application/json",
            "X-Finatic-Sigver": signing_headers.x_finatic_sigver,
            "X-Finatic-Signature": signing_headers.x_finatic_signature,
            "X-Finatic-Sequence": signing_headers.x_finatic_sequence,
            "X-Finatic-Timestamp": signing_headers.x_finatic_timestamp,
        }
        request_body = json.dumps(envelope, separators=(",", ":")).encode(
            "utf-8"
        )
        http_request = request.Request(
            request_url,
            data=request_body,
            headers=request_headers,
            method="POST",
        )
        with request.urlopen(http_request, timeout=10) as response:
            response_text = response.read().decode("utf-8")
            return ReferenceTransportResponse(
                status_code=response.status, body_text=response_text
            )

    def push_snapshot(
        self, snapshot_payload: dict[str, Any]
    ) -> ReferenceTransportResponse:
        """Push full snapshot to Finatic ingestion."""
        snapshot_envelope = self.build_snapshot_envelope(snapshot_payload)
        return self._post_signed_envelope(
            endpoint_path="snapshot", envelope=snapshot_envelope
        )

    def push_events(
        self, event_records: list[dict[str, Any]]
    ) -> ReferenceTransportResponse:
        """Push incremental events to Finatic ingestion."""
        events_envelope = self.build_events_envelope(event_records)
        return self._post_signed_envelope(
            endpoint_path="events", envelope=events_envelope
        )

    def push_heartbeat(
        self, heartbeat_payload: dict[str, Any] | None = None
    ) -> ReferenceTransportResponse:
        """Push heartbeat to keep connector in live state."""
        heartbeat_envelope = self.build_heartbeat_envelope(heartbeat_payload)
        return self._post_signed_envelope(
            endpoint_path="heartbeat", envelope=heartbeat_envelope
        )
