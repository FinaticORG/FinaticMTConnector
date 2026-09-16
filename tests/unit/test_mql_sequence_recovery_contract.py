import json
import re
from pathlib import Path
from typing import Any

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MQL_SOURCES = (
    REPOSITORY_ROOT
    / "src/finatic_mt_connector/ea_reference/mt4/FinaticMT4ConnectorEA.mq4",
    REPOSITORY_ROOT
    / "src/finatic_mt_connector/ea_reference/mt5/FinaticMT5ConnectorEA.mq5",
)

MQL_LIMITS = {
    "FinaticMT4ConnectorEA.mq4": (2147483647, 2147483646),
    "FinaticMT5ConnectorEA.mq5": (9007199254740991, 9007199254740990),
}


def _parse_recovery_contract(
    response_text: str, maximum_recoverable_sequence: int
) -> int | None:
    """Executable contract mirrored by both fail-closed MQL parsers."""
    try:
        response: Any = json.loads(response_text)
    except json.JSONDecodeError:
        return None
    if not isinstance(response, dict):
        return None
    error = response.get("error")
    if not isinstance(error, dict):
        return None
    if error.get("code") != "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER":
        return None
    details = error.get("details")
    if not isinstance(details, dict):
        return None
    expected_sequence = details.get("expected_sequence")
    if (
        isinstance(expected_sequence, bool)
        or not isinstance(expected_sequence, int)
        or not 0 <= expected_sequence <= maximum_recoverable_sequence
    ):
        return None
    return expected_sequence


@pytest.mark.parametrize("source_path", MQL_SOURCES)
def test_mql_sequence_recovery_uses_strict_json_tokens(
    source_path: Path,
) -> None:
    source = source_path.read_text(encoding="utf-8")
    recovery_start = source.index("bool finaticTryExtractSequenceRecovery")
    recovery_end = source.index(
        "string finaticPostMinimalRoute", recovery_start
    )
    recovery_source = source[recovery_start:recovery_end]

    assert "finaticExtractJsonNonnegativeIntegerField" in recovery_source
    assert "StringToInteger" not in recovery_source
    assert "finaticExtractJsonIntField" not in recovery_source


@pytest.mark.parametrize("source_path", MQL_SOURCES)
def test_mql_json_helpers_reject_later_objects_and_non_integer_suffixes(
    source_path: Path,
) -> None:
    source = source_path.read_text(encoding="utf-8")

    assert "finaticFindDirectJsonFieldValue" in source
    assert "finaticIsExactJsonObject(responseText)" in source
    assert "digitCount == 0" in source
    assert "hasLeadingZero && digitCount > 1" in source
    assert "parsedValue > (maximumValue - digitValue) / 10" in source
    assert "delimiter != ',' && delimiter != '}'" in source


@pytest.mark.parametrize("source_path", MQL_SOURCES)
def test_mql_sequence_limits_keep_persisted_successor_reloadable(
    source_path: Path,
) -> None:
    source = source_path.read_text(encoding="utf-8")
    persisted_limit, recoverable_limit = MQL_LIMITS[source_path.name]
    persisted_match = re.search(
        r"#define FINATIC_MAX_PERSISTED_SEQUENCE (\d+)", source
    )
    recoverable_match = re.search(
        r"#define FINATIC_MAX_RECOVERABLE_SEQUENCE (\d+)", source
    )

    assert persisted_match is not None
    assert recoverable_match is not None
    assert int(persisted_match.group(1)) == persisted_limit
    assert int(recoverable_match.group(1)) == recoverable_limit
    assert recoverable_limit + 1 == persisted_limit
    assert "storedValue > FINATIC_MAX_PERSISTED_SEQUENCE" in source
    assert "g_ingestSequence > FINATIC_MAX_RECOVERABLE_SEQUENCE" in source
    assert "FINATIC_MAX_RECOVERABLE_SEQUENCE," in source


@pytest.mark.parametrize(
    ("response_text", "expected"),
    [
        (
            '{"error":{"code":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
            '"details":{"expected_sequence":7}}}',
            7,
        ),
        (
            '{"error":{"code":{"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER":0},'
            '"details":{"expected_sequence":7}}}',
            None,
        ),
        (
            '{"error":{"code":null,"later":'
            '"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
            '"details":{"expected_sequence":7}}}',
            None,
        ),
        (
            '{"error":{"code":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
            '"wrapper":{"details":{"expected_sequence":7}},'
            '"details":null}}',
            None,
        ),
        (
            '{"error":{"code":"MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",'
            '"details":{"nested":{"expected_sequence":7}}}}',
            None,
        ),
    ],
)
@pytest.mark.parametrize("maximum", [2147483646, 9007199254740990])
def test_mql_recovery_parser_behavioral_contract(
    response_text: str, expected: int | None, maximum: int
) -> None:
    assert _parse_recovery_contract(response_text, maximum) == expected


@pytest.mark.parametrize("maximum", [2147483646, 9007199254740990])
def test_mql_recovery_parser_boundary_contract(maximum: int) -> None:
    accepted = json.dumps(
        {
            "error": {
                "code": "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",
                "details": {"expected_sequence": maximum},
            }
        }
    )
    rejected = json.dumps(
        {
            "error": {
                "code": "MT_CONNECTOR_SEQUENCE_OUT_OF_ORDER",
                "details": {"expected_sequence": maximum + 1},
            }
        }
    )

    assert _parse_recovery_contract(accepted, maximum) == maximum
    assert _parse_recovery_contract(rejected, maximum) is None
