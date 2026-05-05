"""Canonical connector envelope types."""

from datetime import datetime
from enum import StrEnum
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class EnvelopeKind(StrEnum):
    EVENTS = "events"
    SNAPSHOT = "snapshot"
    HEARTBEAT = "heartbeat"
    COMMAND_RESULT = "command_result"
    REPLAY_REQUEST = "replay_request"
    SNAPSHOT_REQUEST = "snapshot_request"
    COMMAND = "command"
    WS_HANDSHAKE = "ws_handshake"
    WS_HANDSHAKE_ACK = "ws_handshake_ack"


class BaseEventRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    event_id: UUID
    source_timestamp: datetime


class PositionUpsertEventRecord(BaseEventRecord):
    event_type: Literal["position.upsert"]
    payload: dict[str, Any]


class OrderUpsertEventRecord(BaseEventRecord):
    event_type: Literal["order.upsert"]
    payload: dict[str, Any]


class OrderFillEventRecord(BaseEventRecord):
    event_type: Literal["order.fill"]
    payload: dict[str, Any]


class TransactionAppendEventRecord(BaseEventRecord):
    event_type: Literal["transaction.append"]
    payload: dict[str, Any]


class ConnectionStateChangedEventRecord(BaseEventRecord):
    event_type: Literal["connection.state_changed"]
    payload: dict[str, Any]


class ConnectorHeartbeatEventRecord(BaseEventRecord):
    event_type: Literal["connector.heartbeat"]
    payload: dict[str, Any]


EventRecord = (
    PositionUpsertEventRecord
    | OrderUpsertEventRecord
    | OrderFillEventRecord
    | TransactionAppendEventRecord
    | ConnectionStateChangedEventRecord
    | ConnectorHeartbeatEventRecord
)


class ConnectorEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    schema_version: Literal[1] = 1
    connector_id: UUID
    connection_id: UUID
    secret_version: int = Field(ge=1)
    sequence: int = Field(ge=0)
    source_timestamp: datetime
    envelope_id: UUID
    kind: EnvelopeKind
    payload: dict[str, Any]
