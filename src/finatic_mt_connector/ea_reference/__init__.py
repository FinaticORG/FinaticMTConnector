"""EA reference sources and templates."""

from finatic_mt_connector.ea_reference.mt4 import (
    MT4ConnectorConfiguration,
    MT4ReferenceConnector,
)
from finatic_mt_connector.ea_reference.mt5 import (
    MT5ConnectorConfiguration,
    MT5ReferenceConnector,
)

__all__ = [
    "MT4ConnectorConfiguration",
    "MT4ReferenceConnector",
    "MT5ConnectorConfiguration",
    "MT5ReferenceConnector",
]
