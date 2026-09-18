"""Static contract checks for immutable MT4/MT5 customer releases."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tomllib
from pathlib import Path

import pytest

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
NATIVE_GUARDS = REPO_ROOT / "scripts/release/native_command_guards.ps1"


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
        "overwrite_files: false",
    ):
        assert contract_marker in workflow

    for contract_marker in (
        "clean immutable-tag worktree",
        "must exist and resolve to HEAD",
        "0 errors and 0 warnings",
        "checksums.sha256",
        "Invoke-CheckedNativeCommand",
        "Assert-GitHubReleaseAbsent",
    ):
        assert contract_marker in local_release


def test_tag_creation_is_bound_to_current_develop_tip() -> None:
    tag_workflow = (
        REPO_ROOT / ".github/workflows/auto-version-release.yml"
    ).read_text(encoding="utf-8")

    assert "github.ref == 'refs/heads/develop'" in tag_workflow
    assert "git fetch --no-tags origin develop" in tag_workflow
    assert "git rev-parse refs/remotes/origin/develop" in tag_workflow
    assert tag_workflow.index("Verify reviewed develop checkout") < (
        tag_workflow.index("Create and push release tag")
    )


def test_dispatch_inputs_are_validated_via_environment_variables() -> None:
    tag_workflow = (
        REPO_ROOT / ".github/workflows/auto-version-release.yml"
    ).read_text(encoding="utf-8")
    build_workflow = (REPO_ROOT / ".github/workflows/ea-build.yml").read_text(
        encoding="utf-8"
    )

    assert "BUMP_TYPE: ${{ github.event.inputs.bump }}" in tag_workflow
    assert 'bump_type="$BUMP_TYPE"' in tag_workflow
    assert 'bump_type="${{ github.event.inputs.bump }}"' not in tag_workflow

    assert (
        "RELEASE_TAG_INPUT: ${{ github.event.inputs.release_tag }}"
        in build_workflow
    )
    assert 'release_tag="$RELEASE_TAG_INPUT"' in build_workflow
    assert (
        'release_tag="${{ github.event.inputs.release_tag }}"'
        not in build_workflow
    )


def _assert_stale_outputs_cannot_satisfy_compile(
    release_path: str,
    *,
    binary_variable: str,
    log_variable: str,
    compile_command: str,
    missing_output_check: str,
) -> None:
    """Verify seeded output and log paths are removed before compilation."""
    remove_binary = (
        f"Remove-Item -LiteralPath ${binary_variable} -Force "
        "-ErrorAction SilentlyContinue"
    )
    remove_log = (
        f"Remove-Item -LiteralPath ${log_variable} -Force "
        "-ErrorAction SilentlyContinue"
    )

    remove_binary_position = release_path.index(remove_binary)
    remove_log_position = release_path.index(remove_log)
    compile_position = release_path.index(
        compile_command, max(remove_binary_position, remove_log_position)
    )
    rejection_position = release_path.index(
        missing_output_check, compile_position
    )

    assert remove_binary_position < compile_position < rejection_position
    assert remove_log_position < compile_position < rejection_position


def test_preexisting_workflow_outputs_are_removed_and_cannot_be_reused() -> (
    None
):
    workflow = (REPO_ROOT / ".github/workflows/ea-build.yml").read_text(
        encoding="utf-8"
    )

    for platform in ("mt4", "mt5"):
        _assert_stale_outputs_cannot_satisfy_compile(
            workflow,
            binary_variable=f"{platform}CompiledPath",
            log_variable=f"{platform}BuildLogPath",
            compile_command=f'/compile:"${platform}SourcePath"',
            missing_output_check=f"-not (Test-Path ${platform}CompiledPath)",
        )
        assert (
            f"(Get-Item ${platform}CompiledPath).LastWriteTimeUtc "
            "-lt $compileStartedAtUtc"
        ) in workflow

    assert ".AddMinutes(-1)" not in workflow


def test_preexisting_local_outputs_are_removed_and_cannot_be_reused() -> None:
    local_release = (REPO_ROOT / "scripts/release/local_release.ps1").read_text(
        encoding="utf-8"
    )

    for platform in ("mt4", "mt5"):
        _assert_stale_outputs_cannot_satisfy_compile(
            local_release,
            binary_variable=f"{platform}BinaryPath",
            log_variable=f"{platform}BuildLogPath",
            compile_command=f'/compile:"${platform}CompilePath"',
            missing_output_check=(
                f"Assert-FreshCompiledBinary -ExpectedPath ${platform}BinaryPath"
            ),
        )

    assert "Resolve-CompiledBinaryPath" not in local_release
    assert "-Filter $BinaryFilename" not in local_release
    assert ".AddMinutes(-1)" not in local_release


def _run_guard_harness(
    tmp_path: Path,
    *,
    fake_native: str,
    command: str,
    executable_name: str = "gh",
) -> subprocess.CompletedProcess[str]:
    pwsh = shutil.which("pwsh")
    if pwsh is None:
        assert os.environ.get("CI") != "true", (
            "PowerShell Core is required in CI to exercise native exit behavior"
        )
        pytest.skip(
            "PowerShell Core is required for native-command guard tests"
        )

    bin_directory = tmp_path / "bin"
    bin_directory.mkdir()
    executable_path = bin_directory / executable_name
    executable_path.write_text(fake_native, encoding="utf-8")
    executable_path.chmod(0o755)

    guard_path = str(NATIVE_GUARDS).replace("'", "''")
    bin_path = str(bin_directory).replace("'", "''")
    harness = (
        f"$env:PATH = '{bin_path}:' + $env:PATH; . '{guard_path}'; {command}"
    )
    return subprocess.run(
        [pwsh, "-NoLogo", "-NoProfile", "-Command", harness],
        check=False,
        capture_output=True,
        text=True,
    )


@pytest.mark.parametrize(
    ("fake_gh", "expected_return_code"),
    [
        ("#!/bin/sh\necho 'gh: Not Found (HTTP 404)' >&2\nexit 1\n", 0),
        ("#!/bin/sh\necho 'HTTP/2.0 200 OK'\nexit 0\n", 1),
        (
            "#!/bin/sh\necho 'gh: API rate limit exceeded (HTTP 403)' >&2\nexit 1\n",
            1,
        ),
    ],
)
def test_release_absence_probe_classifies_native_exit_behavior(
    tmp_path: Path,
    fake_gh: str,
    expected_return_code: int,
) -> None:
    result = _run_guard_harness(
        tmp_path,
        fake_native=fake_gh,
        command=(
            "Assert-GitHubReleaseAbsent "
            "-Repository 'FinaticORG/FinaticMTConnector' "
            "-ReleaseTag 'v1.0.1'"
        ),
    )

    assert result.returncode == expected_return_code, result.stderr


def test_checked_native_command_rejects_failed_release_write(
    tmp_path: Path,
) -> None:
    result = _run_guard_harness(
        tmp_path,
        fake_native="#!/bin/sh\necho 'publish failed' >&2\nexit 9\n",
        command=(
            "Invoke-CheckedNativeCommand -Command 'gh' "
            "-Arguments @('release', 'create', 'v1.0.1') "
            "-FailureMessage 'Unable to publish release.'"
        ),
    )

    assert result.returncode != 0
    assert "Unable to publish release. Exit code: 9" in result.stderr


def test_checked_native_command_rejects_failed_ci_validation(
    tmp_path: Path,
) -> None:
    result = _run_guard_harness(
        tmp_path,
        executable_name="uv",
        fake_native="#!/bin/sh\necho 'ci failed' >&2\nexit 17\n",
        command=(
            "Invoke-CheckedNativeCommand -Command 'uv' "
            "-Arguments @('run', 'poe', 'ci-fast') "
            "-FailureMessage 'Repository CI validation failed.'"
        ),
    )

    assert result.returncode != 0
    assert "Repository CI validation failed. Exit code: 17" in result.stderr


def test_local_release_checks_ci_and_publish_native_commands() -> None:
    local_release = (REPO_ROOT / "scripts/release/local_release.ps1").read_text(
        encoding="utf-8"
    )

    assert re.search(
        r'Invoke-CheckedNativeCommand\s+`\s*\n\s*-Command "uv"\s+`'
        r'\s*\n\s*-Arguments @\("run", "poe", "ci-fast"\)',
        local_release,
    )
    assert re.search(
        r'Invoke-CheckedNativeCommand\s+`\s*\n\s*-Command "gh"\s+`'
        r"\s*\n\s*-Arguments \$releaseArguments",
        local_release,
    )
