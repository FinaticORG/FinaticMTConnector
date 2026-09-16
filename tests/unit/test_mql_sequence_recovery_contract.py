from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MQL_SOURCES = (
    REPOSITORY_ROOT
    / "src/finatic_mt_connector/ea_reference/mt4/FinaticMT4ConnectorEA.mq4",
    REPOSITORY_ROOT
    / "src/finatic_mt_connector/ea_reference/mt5/FinaticMT5ConnectorEA.mq5",
)


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

    assert "StringGetCharacter(jsonObjectText, objectStart) != '{'" in source
    assert "digitCount == 0" in source
    assert "hasLeadingZero && digitCount > 1" in source
    assert "parsedValue > (maximumValue - digitValue) / 10" in source
    assert "delimiter != ',' && delimiter != '}'" in source
