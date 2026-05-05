import pytest

from finatic_mt_connector.contracts.state import (
    ConnectorStateEnum,
    TransitionViolationError,
    ensure_allowed_transition,
)


def test_valid_transition_is_allowed() -> None:
    ensure_allowed_transition(
        ConnectorStateEnum.REGISTERING,
        ConnectorStateEnum.AWAITING_FIRST_HEARTBEAT,
    )


def test_invalid_transition_raises_error() -> None:
    with pytest.raises(TransitionViolationError):
        ensure_allowed_transition(
            ConnectorStateEnum.UNREGISTERED,
            ConnectorStateEnum.LIVE_HTTPS,
        )
