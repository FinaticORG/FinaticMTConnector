"""Static contract checks for immutable MT4/MT5 customer releases."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]
MT4_SOURCE = REPO_ROOT / (
    "src/finatic_mt_connector/ea_reference/mt4/FinaticMT4ConnectorEA.mq4"
)
MT5_SOURCE = REPO_ROOT / (
    "src/finatic_mt_connector/ea_reference/mt5/FinaticMT5ConnectorEA.mq5"
)
CUSTOMER_ASSETS = {
    "FinaticMT4ConnectorEA.ex4",
    "FinaticMT5ConnectorEA.ex5",
    "FinaticMT4ConnectorEA.mq4",
    "FinaticMT5ConnectorEA.mq5",
}
RELEASE_EVIDENCE = {
    "FinaticMT4ConnectorEA.build.log",
    "FinaticMT5ConnectorEA.build.log",
    "build-provenance.txt",
    "release-notes.md",
}


def _project_version() -> str:
    with (REPO_ROOT / "pyproject.toml").open("rb") as pyproject_file:
        project = tomllib.load(pyproject_file)
    return str(project["project"]["version"])


def _property_version(version: str) -> str:
    major, minor, patch = version.split(".")
    return f"{major}.{minor}{patch}"


def test_ea_version_markers_match_package_version() -> None:
    version = _project_version()
    property_marker = f'#property version   "{_property_version(version)}"'

    for platform, source_path in (("MT4", MT4_SOURCE), ("MT5", MT5_SOURCE)):
        source = source_path.read_text(encoding="utf-8")
        assert property_marker in source
        assert source.count(f"{platform} Connector v{version}") >= 2


def test_both_eas_default_to_the_shared_signed_transport() -> None:
    required_headers = {
        "X-Finatic-Connector-Id",
        "X-Finatic-Secret-Version",
        "X-Finatic-Scheme-Version",
        "X-Finatic-Timestamp",
        "X-Finatic-Signature",
    }
    required_routes = {"heartbeat", "snapshot", "events", "command-result"}

    for source_path in (MT4_SOURCE, MT5_SOURCE):
        source = source_path.read_text(encoding="utf-8")
        assert re.search(
            r"input bool\s+FinaticSignEnvelopes\s*=\s*true;", source
        )
        assert required_headers <= {
            header for header in required_headers if header in source
        }
        for route in required_routes:
            assert f'finaticPostMinimalRoute("{route}"' in source


def test_release_paths_publish_complete_checksummed_assets() -> None:
    workflow = (REPO_ROOT / ".github/workflows/ea-build.yml").read_text(
        encoding="utf-8"
    )
    local_release = (REPO_ROOT / "scripts/release/local_release.ps1").read_text(
        encoding="utf-8"
    )

    for asset in CUSTOMER_ASSETS | RELEASE_EVIDENCE:
        assert workflow.count(asset) >= 2
        assert local_release.count(asset) >= 2

    for contract_marker in (
        "Tag $tagVersion does not match pyproject version",
        "draft: true",
        "0 errors and 0 warnings",
        "checksums.sha256",
    ):
        assert contract_marker in workflow

    for contract_marker in (
        "clean immutable-tag worktree",
        "must exist and resolve to HEAD",
        "0 errors and 0 warnings",
        "checksums.sha256",
    ):
        assert contract_marker in local_release
