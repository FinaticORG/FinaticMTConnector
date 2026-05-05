"""MT4 reference connector."""

from finatic_mt_connector.ea_reference.reference_connector_base import (
    BaseReferenceConnector,
    ReferenceConnectorConfiguration,
)

MT4ConnectorConfiguration = ReferenceConnectorConfiguration


class MT4ReferenceConnector(BaseReferenceConnector):
    """MT4 wrapper over shared reference connector behavior."""
