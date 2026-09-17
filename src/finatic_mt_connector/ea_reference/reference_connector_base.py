"""Shared transport utilities for MT connector references.

**Deployed Finatic Background** (`FinaticBackground` webhook router) accepts a
minimal JSON body per route: ``sequence``, ``secret_version``, ``platform``,
``payload`` — see ``MTIngressRequestBody`` in ``webhook_routes.py``. The MQL EA
and :meth:`BaseReferenceConnector.push_minimal_heartbeat` use this shape.

The signed-envelope helpers (:meth:`push_snapshot`, :meth:`push_events`,
:meth:`push_heartbeat`) POST a richer schema plus ``X-Finatic-*`` headers. That
path is **not** wired to the current FastAPI ingress handler and is retained for
experiments / future HMAC-backed ingestion — do not expect it to succeed against
today's Background deployment without matching route changes.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NoReturn
from urllib import request
from urllib.error import HTTPError
from uuid import UUID, uuid4

from finatic_mt_connector.contracts.envelope import EnvelopeKind
from finatic_mt_connector.security.signing import (
    build_signing_headers,
    extract_signable_body_dictionary,
)

logger = logging.getLogger(__name__)
MAX_PERSISTED_SEQUENCE = (1 << 53) - 1
MAX_RECOVERABLE_SEQUENCE = MAX_PERSISTED_SEQUENCE - 1
SEQUENCE_ERROR_CODE = "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER"


def _reject_non_json_constant(_: str) -> NoReturn:
    raise json.JSONDecodeError("non-standard JSON constant", "", 0)


@dataclass(frozen=True, slots=True)
class ReferenceConnectorConfiguration:
    """Runtime connector configuration aligned with Connect portal / EA inputs.

    ``ingest_base_url`` must be the Background **origin only** (scheme + host
    **[+ port]**), e.g. ``http://localhost:8001``. Paths such as
    ``/v1/mt/connectors/{id}`` are appended by transport helpers.
    """

    platform: str
    connector_id: UUID
    connection_id: UUID
    connector_secret: str
    ingest_base_url: str
    secret_version: int = 1
    signing_scheme_version: int = 1
    timestamp_skew_seconds: int = 300
    sequence_state_path: Path | None = None


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
        self._minimal_webhook_sequence = self._load_minimal_sequence()
        self._sequence_recovery_count = 0

    def _load_minimal_sequence(self) -> int:
        state_path = self.connector_configuration.sequence_state_path
        if state_path is None or not state_path.exists():
            return 0
        try:
            sequence_value = int(state_path.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            logger.warning("mt_sequence_state_invalid action=reset_to_zero")
            return 0
        if sequence_value < 0 or sequence_value > MAX_PERSISTED_SEQUENCE:
            logger.warning(
                "mt_sequence_state_out_of_range action=reset_to_zero"
            )
            return 0
        return sequence_value

    def _persist_minimal_sequence(self) -> None:
        state_path = self.connector_configuration.sequence_state_path
        if state_path is None:
            return
        temporary_path = state_path.with_name(f".{state_path.name}.tmp")
        try:
            state_path.parent.mkdir(parents=True, exist_ok=True)
            temporary_path.write_text(
                str(self._minimal_webhook_sequence), encoding="utf-8"
            )
            temporary_path.replace(state_path)
        except OSError:
            logger.exception("mt_sequence_state_persist_failed")

    @staticmethod
    def _recovery_sequence(response: ReferenceTransportResponse) -> int | None:
        if response.status_code != 409:
            return None
        try:
            response_body = json.loads(
                response.body_text,
                parse_constant=_reject_non_json_constant,
            )
        except (json.JSONDecodeError, TypeError):
            return None
        if not isinstance(response_body, dict):
            return None
        error = response_body.get("error")
        if (
            not isinstance(error, dict)
            or error.get("code") != SEQUENCE_ERROR_CODE
        ):
            return None
        details = error.get("details")
        if not isinstance(details, dict):
            return None
        expected_sequence = details.get("expected_sequence")
        if (
            isinstance(expected_sequence, bool)
            or not isinstance(expected_sequence, int)
            or expected_sequence < 0
            or expected_sequence > MAX_RECOVERABLE_SEQUENCE
        ):
            return None
        return expected_sequence

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
            "platform": self.connector_configuration.platform,
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

    def _minimal_webhook_url(self, route_suffix: str) -> str:
        connector_configuration = self.connector_configuration
        return (
            f"{connector_configuration.ingest_base_url.rstrip('/')}"
            f"/v1/mt/connectors/{connector_configuration.connector_id}"
            f"/{route_suffix.lstrip('/')}"
        )

    def _build_minimal_ingress_body(
        self,
        *,
        payload: dict[str, Any],
        sequence: int | None = None,
    ) -> dict[str, Any]:
        connector_configuration = self.connector_configuration
        sequence_index = (
            self._minimal_webhook_sequence if sequence is None else sequence
        )
        return extract_signable_body_dictionary(
            sequence=sequence_index,
            secret_version=connector_configuration.secret_version,
            platform=connector_configuration.platform,
            payload=payload,
        )

    def push_minimal_webhook(
        self,
        *,
        route_suffix: str,
        payload: dict[str, Any],
        sign_request: bool = False,
    ) -> ReferenceTransportResponse:
        """POST minimal ``MTIngressRequestBody`` JSON to a deployed Background route."""
        sequence_index = self._minimal_webhook_sequence
        if sequence_index > MAX_RECOVERABLE_SEQUENCE:
            logger.error("mt_sequence_exhausted action=stop_before_send")
            return ReferenceTransportResponse(
                status_code=409,
                body_text='{"error":{"code":"MT_CONNECTOR_SEQUENCE_EXHAUSTED"}}',
            )
        response = self._push_minimal_webhook_once(
            route_suffix=route_suffix,
            payload=payload,
            sequence_index=sequence_index,
            sign_request=sign_request,
        )
        if 200 <= response.status_code <= 299:
            self._minimal_webhook_sequence = sequence_index + 1
            self._persist_minimal_sequence()
            return response

        recovery_sequence = self._recovery_sequence(response)
        if recovery_sequence is None:
            return response

        self._sequence_recovery_count += 1
        logger.warning(
            "mt_sequence_recovery route=%s recovery_count=%d "
            "duplicate_installation_possible=%s",
            route_suffix,
            self._sequence_recovery_count,
            str(self._sequence_recovery_count > 1).lower(),
        )
        self._minimal_webhook_sequence = recovery_sequence
        retry_response = self._push_minimal_webhook_once(
            route_suffix=route_suffix,
            payload=payload,
            sequence_index=recovery_sequence,
            sign_request=sign_request,
        )
        if 200 <= retry_response.status_code <= 299:
            self._minimal_webhook_sequence = recovery_sequence + 1
            self._persist_minimal_sequence()
        return retry_response

    def _push_minimal_webhook_once(
        self,
        *,
        route_suffix: str,
        payload: dict[str, Any],
        sequence_index: int,
        sign_request: bool,
    ) -> ReferenceTransportResponse:
        connector_configuration = self.connector_configuration
        minimal_body = self._build_minimal_ingress_body(
            payload=payload,
            sequence=sequence_index,
        )
        request_body = json.dumps(minimal_body, separators=(",", ":")).encode(
            "utf-8"
        )
        request_headers = {"Content-Type": "application/json"}
        if sign_request:
            signing_headers = build_signing_headers(
                secret_value=connector_configuration.connector_secret,
                raw_payload=minimal_body,
            )
            request_headers.update(
                {
                    "X-Finatic-Sigver": signing_headers.x_finatic_sigver,
                    "X-Finatic-Signature": signing_headers.x_finatic_signature,
                    "X-Finatic-Sequence": signing_headers.x_finatic_sequence,
                    "X-Finatic-Timestamp": signing_headers.x_finatic_timestamp,
                }
            )
        http_request = request.Request(
            self._minimal_webhook_url(route_suffix),
            data=request_body,
            headers=request_headers,
            method="POST",
        )
        try:
            with request.urlopen(http_request, timeout=10) as http_response:
                response_status = int(getattr(http_response, "status", 200))
                response_text = http_response.read().decode("utf-8")
        except HTTPError as http_error:
            response_status = int(http_error.code)
            response_text = (
                http_error.read().decode("utf-8") if http_error.fp else ""
            )
            return ReferenceTransportResponse(
                status_code=response_status, body_text=response_text
            )
        return ReferenceTransportResponse(
            status_code=response_status, body_text=response_text
        )

    def push_minimal_signed_snapshot(
        self, snapshot_payload: dict[str, Any]
    ) -> ReferenceTransportResponse:
        """POST signed snapshot bootstrap compatible with deployed Background ingress."""
        return self.push_minimal_webhook(
            route_suffix="snapshot",
            payload=snapshot_payload,
            sign_request=True,
        )

    def push_minimal_heartbeat(self) -> ReferenceTransportResponse:
        """POST heartbeat JSON compatible with deployed Background webhooks."""
        return self.push_minimal_webhook(route_suffix="heartbeat", payload={})

    def push_minimal_snapshot(
        self, snapshot_payload: dict[str, Any]
    ) -> ReferenceTransportResponse:
        """POST snapshot bootstrap payload (flat ``payload`` object)."""
        return self.push_minimal_webhook(
            route_suffix="snapshot", payload=snapshot_payload
        )

    def push_minimal_flat_event(
        self, flat_event_payload: dict[str, Any]
    ) -> ReferenceTransportResponse:
        """POST one stream event with ``event_type`` at the top level of ``payload``."""
        return self.push_minimal_webhook(
            route_suffix="events", payload=flat_event_payload
        )

    def push_minimal_batched_events(
        self, event_records: list[dict[str, Any]]
    ) -> ReferenceTransportResponse:
        """POST multiple events under ``payload.events`` (Background expands)."""
        return self.push_minimal_webhook(
            route_suffix="events", payload={"events": event_records}
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
        """Push signed heartbeat envelope (legacy / future HMAC route).

        For the webhook body today's Background FastAPI app validates, use
        :meth:`push_minimal_heartbeat` instead.
        """
        heartbeat_envelope = self.build_heartbeat_envelope(heartbeat_payload)
        return self._post_signed_envelope(
            endpoint_path="heartbeat", envelope=heartbeat_envelope
        )
