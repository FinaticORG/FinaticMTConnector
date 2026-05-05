"""Connector lifecycle state machine."""

from enum import StrEnum


class TransitionViolationError(ValueError):
    """Raised when a transition is not allowed by policy."""


class ConnectorStateEnum(StrEnum):
    UNREGISTERED = "UNREGISTERED"
    REGISTERING = "REGISTERING"
    AWAITING_FIRST_HEARTBEAT = "AWAITING_FIRST_HEARTBEAT"
    LIVE_HTTPS = "LIVE_HTTPS"
    LIVE_WEBSOCKET = "LIVE_WEBSOCKET"
    DEGRADED = "DEGRADED"
    STALE = "STALE"
    OFFLINE = "OFFLINE"
    REVOKED = "REVOKED"
    COOLDOWN = "COOLDOWN"
    FAILED = "FAILED"


ALLOWED_TRANSITIONS: dict[ConnectorStateEnum, set[ConnectorStateEnum]] = {
    ConnectorStateEnum.UNREGISTERED: {ConnectorStateEnum.REGISTERING},
    ConnectorStateEnum.REGISTERING: {
        ConnectorStateEnum.AWAITING_FIRST_HEARTBEAT,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.AWAITING_FIRST_HEARTBEAT: {
        ConnectorStateEnum.LIVE_HTTPS,
        ConnectorStateEnum.LIVE_WEBSOCKET,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.LIVE_HTTPS: {
        ConnectorStateEnum.LIVE_WEBSOCKET,
        ConnectorStateEnum.DEGRADED,
        ConnectorStateEnum.STALE,
        ConnectorStateEnum.OFFLINE,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.LIVE_WEBSOCKET: {
        ConnectorStateEnum.LIVE_HTTPS,
        ConnectorStateEnum.DEGRADED,
        ConnectorStateEnum.STALE,
        ConnectorStateEnum.OFFLINE,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.DEGRADED: {
        ConnectorStateEnum.LIVE_HTTPS,
        ConnectorStateEnum.LIVE_WEBSOCKET,
        ConnectorStateEnum.STALE,
        ConnectorStateEnum.OFFLINE,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.STALE: {
        ConnectorStateEnum.LIVE_HTTPS,
        ConnectorStateEnum.LIVE_WEBSOCKET,
        ConnectorStateEnum.OFFLINE,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.OFFLINE: {
        ConnectorStateEnum.AWAITING_FIRST_HEARTBEAT,
        ConnectorStateEnum.COOLDOWN,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.COOLDOWN: {
        ConnectorStateEnum.AWAITING_FIRST_HEARTBEAT,
        ConnectorStateEnum.REVOKED,
        ConnectorStateEnum.FAILED,
    },
    ConnectorStateEnum.FAILED: {
        ConnectorStateEnum.REGISTERING,
        ConnectorStateEnum.REVOKED,
    },
    ConnectorStateEnum.REVOKED: set(),
}


def ensure_allowed_transition(
    current_state: ConnectorStateEnum,
    requested_state: ConnectorStateEnum,
) -> None:
    """Validate transition policy; idempotent transitions are allowed."""
    if current_state == requested_state:
        return
    if requested_state not in ALLOWED_TRANSITIONS[current_state]:
        raise TransitionViolationError(
            f"State transition is not allowed: {current_state} -> {requested_state}"
        )
