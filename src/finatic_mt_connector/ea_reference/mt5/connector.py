"""MT5 reference connector."""

from __future__ import annotations

from finatic_mt_connector.ea_reference.reference_connector_base import (
    BaseReferenceConnector,
    ReferenceConnectorConfiguration,
)

MT5ConnectorConfiguration = ReferenceConnectorConfiguration


class MT5ReferenceConnector(BaseReferenceConnector):
    """MT5 wrapper over shared reference connector behavior."""
