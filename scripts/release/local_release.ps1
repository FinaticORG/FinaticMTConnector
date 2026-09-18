param(
  [string]$MT4MetaEditorPath = "",
  [string]$MT5MetaEditorPath = "",
  [switch]$Publish
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "native_command_guards.ps1")

function Get-ProjectVersion {
  param([string]$PyprojectPath)

  $versionLine = Get-Content $PyprojectPath |
    Where-Object { $_ -match '^version = "([0-9]+\.[0-9]+\.[0-9]+)"$' } |
    Select-Object -First 1
  if (-not $versionLine) {
    throw "Unable to resolve the semantic version from pyproject.toml."
  }
  return [regex]::Match($versionLine, '"([0-9]+\.[0-9]+\.[0-9]+)"').Groups[1].Value
}

function Assert-EaVersionMarkers {
  param([string]$SourcePath, [string]$VersionValue, [string]$Platform)

  $sourceText = Get-Content $SourcePath -Raw
  $versionParts = $VersionValue.Split('.')
  $propertyVersion = "$($versionParts[0]).$($versionParts[1])$($versionParts[2])"
  if ($sourceText -notmatch [regex]::Escape("#property version   `"$propertyVersion`"")) {
    throw "$Platform #property version does not match $VersionValue."
  }
  $displayMarker = "$Platform Connector v$VersionValue"
  if (($sourceText.Split($displayMarker).Count - 1) -lt 2) {
    throw "$Platform description/startup version does not match $VersionValue."
  }
}

function Assert-MetaEditorCompileLog {
  param([string]$LogPath, [string]$Platform)

  if (-not (Test-Path $LogPath)) {
    throw "$Platform compilation did not produce a build log."
  }
  $logText = Get-Content $LogPath -Raw
  if ($logText -notmatch '(?i)0\s+error(?:s|\(s\))?,\s*0\s+warning(?:s|\(s\))?') {
    Get-Content $LogPath
    throw "$Platform compile log does not report 0 errors and 0 warnings."
  }
}

function Assert-ReleaseBundle {
  param([string]$DistDirectory, [string]$ReleaseTag, [string]$ReleaseCommit)

  $assetNames = @(
    "FinaticMT4ConnectorEA.ex4"
    "FinaticMT5ConnectorEA.ex5"
    "FinaticMT4ConnectorEA.mq4"
    "FinaticMT5ConnectorEA.mq5"
    "FinaticMT4ConnectorEA.build.log"
    "FinaticMT5ConnectorEA.build.log"
    "build-provenance.txt"
    "release-notes.md"
  )
  $checksumPath = Join-Path $DistDirectory "checksums.sha256"
  if (-not (Test-Path $checksumPath)) {
    throw "Validated release bundle is missing checksums.sha256."
  }

  $expectedHashes = @{}
  foreach ($checksumLine in Get-Content $checksumPath) {
    if ($checksumLine -notmatch '^([0-9a-f]{64})  (.+)$') {
      throw "Invalid checksum manifest line: $checksumLine"
    }
    $expectedHashes[$Matches[2]] = $Matches[1]
  }
  foreach ($assetName in $assetNames) {
    $assetPath = Join-Path $DistDirectory $assetName
    if (-not (Test-Path $assetPath) -or (Get-Item $assetPath).Length -le 0) {
      throw "Validated release bundle is missing a non-empty $assetName."
    }
    $actualHash = (Get-FileHash $assetPath -Algorithm SHA256).Hash.ToLower()
    if ($expectedHashes[$assetName] -ne $actualHash) {
      throw "Checksum mismatch for validated release asset $assetName."
    }
  }

  $provenanceText = Get-Content (Join-Path $DistDirectory "build-provenance.txt") -Raw
  if ($provenanceText -notmatch "(?m)^release_tag=$([regex]::Escape($ReleaseTag))\r?$") {
    throw "Release provenance tag does not match $ReleaseTag."
  }
  if ($provenanceText -notmatch "(?m)^commit_sha=$([regex]::Escape($ReleaseCommit))\r?$") {
    throw "Release provenance commit does not match $ReleaseCommit."
  }
}

function Publish-ReleaseBundle {
  param([string]$DistDirectory, [string]$ReleaseTag)

  Assert-GitHubReleaseAbsent `
    -Repository "FinaticORG/FinaticMTConnector" `
    -ReleaseTag $ReleaseTag
  $releaseArguments = @(
    "release"
    "create"
    $ReleaseTag
    "$DistDirectory\FinaticMT4ConnectorEA.ex4"
    "$DistDirectory\FinaticMT5ConnectorEA.ex5"
    "$DistDirectory\FinaticMT4ConnectorEA.mq4"
    "$DistDirectory\FinaticMT5ConnectorEA.mq5"
    "$DistDirectory\FinaticMT4ConnectorEA.build.log"
    "$DistDirectory\FinaticMT5ConnectorEA.build.log"
    "$DistDirectory\build-provenance.txt"
    "$DistDirectory\checksums.sha256"
    "$DistDirectory\release-notes.md"
    "--repo"
    "FinaticORG/FinaticMTConnector"
    "--title"
    "Finatic MT Connector $ReleaseTag"
    "--notes-file"
    "$DistDirectory\release-notes.md"
  )
  Invoke-CheckedNativeCommand `
    -Command "gh" `
    -Arguments $releaseArguments `
    -FailureMessage "Unable to publish GitHub Release $ReleaseTag."
}

function Resolve-MetaEditorPath {
  param([string[]]$Candidates, [string]$Label, [string]$OverridePath)

  if ($OverridePath -and (Test-Path $OverridePath)) {
    return $OverridePath
  }

  foreach ($candidatePath in $Candidates) {
    if (Test-Path $candidatePath) {
      return $candidatePath
    }
  }

  $searchRoots = @(
    "C:\Program Files",
    "C:\Program Files (x86)",
    "$env:APPDATA\MetaQuotes",
    "$env:LOCALAPPDATA\Programs"
  ) | Where-Object { Test-Path $_ }

  $searchPattern = if ($Label -eq "MT4") { "metaeditor.exe" } else { "metaeditor64.exe" }

  foreach ($searchRoot in $searchRoots) {
    $discoveredPath = Get-ChildItem -Path $searchRoot -Recurse -Filter $searchPattern -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty FullName
    if ($discoveredPath) {
      return $discoveredPath
    }
  }

  throw "Unable to locate MetaEditor for $Label. Check local MT installation."
}

function Assert-FreshCompiledBinary {
  param(
    [string]$ExpectedPath,
    [string]$Platform,
    [datetime]$CompileStartedAtUtc
  )

  if (-not (Test-Path $ExpectedPath)) {
    throw "$Platform compilation did not recreate its bound output: $ExpectedPath"
  }

  $compiledFile = Get-Item $ExpectedPath
  if ($compiledFile.Length -le 0 -or $compiledFile.LastWriteTimeUtc -lt $CompileStartedAtUtc) {
    throw "$Platform compilation did not produce a fresh non-empty bound output: $ExpectedPath"
  }
}

function Get-TerminalRootFromMetaEditor {
  param([string]$MetaEditorPath)
  return Split-Path -Parent $MetaEditorPath
}

function Resolve-ExpertsDirectoryPath {
  param(
    [string]$PlatformFolderName,
    [string]$TerminalRootPath
  )

  $candidatePaths = @(
    (Join-Path $TerminalRootPath "$PlatformFolderName\Experts"),
    "$env:APPDATA\MetaQuotes\Terminal",
    "$env:LOCALAPPDATA\MetaQuotes\Terminal"
  )

  $directExpertsPath = $candidatePaths[0]
  if (Test-Path $directExpertsPath) {
    return $directExpertsPath
  }

  $terminalDataRoots = $candidatePaths | Select-Object -Skip 1 | Where-Object { Test-Path $_ }
  foreach ($terminalDataRoot in $terminalDataRoots) {
    $resolvedExpertsPath = Get-ChildItem -Path $terminalDataRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName "$PlatformFolderName\Experts" } |
      Where-Object { Test-Path $_ } |
      Select-Object -First 1
    if ($resolvedExpertsPath) {
      return $resolvedExpertsPath
    }
  }

  throw "$PlatformFolderName Experts folder not found. Checked terminal root and MetaQuotes data folders."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $repoRoot

$workingTreeChanges = Invoke-CheckedNativeOutput `
  -Command "git" `
  -Arguments @("status", "--porcelain") `
  -FailureMessage "Unable to inspect the release worktree."
if ($workingTreeChanges) {
  throw "Release builds require a clean immutable-tag worktree."
}

$projectVersion = Get-ProjectVersion -PyprojectPath (Join-Path $repoRoot "pyproject.toml")
$releaseTag = "v$projectVersion"
$releaseCommit = Invoke-CheckedNativeOutput `
  -Command "git" `
  -Arguments @("rev-parse", "HEAD") `
  -FailureMessage "Unable to resolve the release commit."
try {
  $tagCommit = Invoke-CheckedNativeOutput `
    -Command "git" `
    -Arguments @("rev-parse", "$releaseTag^{commit}") `
    -FailureMessage "Unable to resolve release tag $releaseTag."
} catch {
  throw "Release tag $releaseTag must exist and resolve to HEAD ($releaseCommit). $($_.Exception.Message)"
}
if ($tagCommit -ne $releaseCommit) {
  throw "Release tag $releaseTag must exist and resolve to HEAD ($releaseCommit)."
}
$distDirectory = Join-Path $repoRoot "dist\ea"

if ($Publish) {
  Assert-ReleaseBundle -DistDirectory $distDirectory -ReleaseTag $releaseTag -ReleaseCommit $releaseCommit
  Publish-ReleaseBundle -DistDirectory $distDirectory -ReleaseTag $releaseTag
  Write-Host "Validated release bundle published: $releaseTag"
  return
}

Write-Host "Building immutable release $releaseTag at $releaseCommit"
Invoke-CheckedNativeCommand `
  -Command "uv" `
  -Arguments @("run", "poe", "ci-fast") `
  -FailureMessage "Repository CI validation failed; release compilation is blocked."

$mt4EditorPath = Resolve-MetaEditorPath -Candidates @(
  "C:\Program Files\MetaTrader 4\metaeditor.exe",
  "C:\Program Files (x86)\MetaTrader 4\metaeditor.exe"
) -Label "MT4" -OverridePath $MT4MetaEditorPath

$mt5EditorPath = Resolve-MetaEditorPath -Candidates @(
  "C:\Program Files\MetaTrader 5\metaeditor64.exe",
  "C:\Program Files (x86)\MetaTrader 5\metaeditor64.exe"
) -Label "MT5" -OverridePath $MT5MetaEditorPath

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

$mt4SourcePath = Join-Path $repoRoot "src\finatic_mt_connector\ea_reference\mt4\FinaticMT4ConnectorEA.mq4"
$mt5SourcePath = Join-Path $repoRoot "src\finatic_mt_connector\ea_reference\mt5\FinaticMT5ConnectorEA.mq5"
Assert-EaVersionMarkers -SourcePath $mt4SourcePath -VersionValue $projectVersion -Platform "MT4"
Assert-EaVersionMarkers -SourcePath $mt5SourcePath -VersionValue $projectVersion -Platform "MT5"
$mt4BuildLogPath = Join-Path $env:TEMP "mt4-build.log"
$mt5BuildLogPath = Join-Path $env:TEMP "mt5-build.log"

$mt4TerminalRootPath = Get-TerminalRootFromMetaEditor -MetaEditorPath $mt4EditorPath
$mt5TerminalRootPath = Get-TerminalRootFromMetaEditor -MetaEditorPath $mt5EditorPath

$mt4ExpertsPath = Resolve-ExpertsDirectoryPath -PlatformFolderName "MQL4" -TerminalRootPath $mt4TerminalRootPath
$mt5ExpertsPath = Resolve-ExpertsDirectoryPath -PlatformFolderName "MQL5" -TerminalRootPath $mt5TerminalRootPath

$mt4CompilePath = Join-Path $mt4ExpertsPath "FinaticMT4ConnectorEA.mq4"
$mt5CompilePath = Join-Path $mt5ExpertsPath "FinaticMT5ConnectorEA.mq5"
$mt4BinaryPath = [System.IO.Path]::ChangeExtension($mt4CompilePath, ".ex4")
$mt5BinaryPath = [System.IO.Path]::ChangeExtension($mt5CompilePath, ".ex5")

Copy-Item $mt4SourcePath $mt4CompilePath -Force
Copy-Item $mt5SourcePath $mt5CompilePath -Force

Remove-Item -LiteralPath $mt4BinaryPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $mt4BuildLogPath -Force -ErrorAction SilentlyContinue
$mt4CompileStartedAtUtc = [datetime]::UtcNow
& $mt4EditorPath /compile:"$mt4CompilePath" /log:"$mt4BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt4BuildLogPath) { Get-Content $mt4BuildLogPath }
  throw "MT4 compilation failed."
}
Assert-MetaEditorCompileLog -LogPath $mt4BuildLogPath -Platform "MT4"
Assert-FreshCompiledBinary -ExpectedPath $mt4BinaryPath -Platform "MT4" -CompileStartedAtUtc $mt4CompileStartedAtUtc

Remove-Item -LiteralPath $mt5BinaryPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $mt5BuildLogPath -Force -ErrorAction SilentlyContinue
$mt5CompileStartedAtUtc = [datetime]::UtcNow
& $mt5EditorPath /compile:"$mt5CompilePath" /log:"$mt5BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt5BuildLogPath) { Get-Content $mt5BuildLogPath }
  throw "MT5 compilation failed."
}
Assert-MetaEditorCompileLog -LogPath $mt5BuildLogPath -Platform "MT5"
Assert-FreshCompiledBinary -ExpectedPath $mt5BinaryPath -Platform "MT5" -CompileStartedAtUtc $mt5CompileStartedAtUtc

Copy-Item $mt4BinaryPath (Join-Path $distDirectory "FinaticMT4ConnectorEA.ex4") -Force
Copy-Item $mt5BinaryPath (Join-Path $distDirectory "FinaticMT5ConnectorEA.ex5") -Force
Copy-Item $mt4SourcePath (Join-Path $distDirectory "FinaticMT4ConnectorEA.mq4") -Force
Copy-Item $mt5SourcePath (Join-Path $distDirectory "FinaticMT5ConnectorEA.mq5") -Force
Copy-Item $mt4BuildLogPath (Join-Path $distDirectory "FinaticMT4ConnectorEA.build.log") -Force
Copy-Item $mt5BuildLogPath (Join-Path $distDirectory "FinaticMT5ConnectorEA.build.log") -Force

$publishedBinaries = @("FinaticMT4ConnectorEA.ex4", "FinaticMT5ConnectorEA.ex5")
foreach ($binaryName in $publishedBinaries) {
  $binaryPath = Join-Path $distDirectory $binaryName
  if ((Get-Item $binaryPath).Length -le 0) {
    throw "Release binary is empty: $binaryName"
  }
}

$mt4EditorVersion = (Get-Item $mt4EditorPath).VersionInfo.FileVersion
$mt5EditorVersion = (Get-Item $mt5EditorPath).VersionInfo.FileVersion
$provenancePath = Join-Path $distDirectory "build-provenance.txt"
$provenanceLines = @(
  "release_tag=$releaseTag"
  "commit_sha=$releaseCommit"
  "build_time_utc=$([datetime]::UtcNow.ToString('o'))"
  "mt4_compiler_path=$mt4EditorPath"
  "mt4_compiler_version=$mt4EditorVersion"
  "mt5_compiler_path=$mt5EditorPath"
  "mt5_compiler_version=$mt5EditorVersion"
  "mt4_source_sha256=$((Get-FileHash $mt4SourcePath -Algorithm SHA256).Hash.ToLower())"
  "mt5_source_sha256=$((Get-FileHash $mt5SourcePath -Algorithm SHA256).Hash.ToLower())"
  "mt4_binary_sha256=$((Get-FileHash (Join-Path $distDirectory 'FinaticMT4ConnectorEA.ex4') -Algorithm SHA256).Hash.ToLower())"
  "mt5_binary_sha256=$((Get-FileHash (Join-Path $distDirectory 'FinaticMT5ConnectorEA.ex5') -Algorithm SHA256).Hash.ToLower())"
)
[System.IO.File]::WriteAllLines($provenancePath, $provenanceLines, [System.Text.UTF8Encoding]::new($false))

$releaseNotesPath = Join-Path $distDirectory "release-notes.md"
$recentChanges = Invoke-CheckedNativeOutput `
  -Command "git" `
  -Arguments @("log", "--oneline", "-n", "15") `
  -FailureMessage "Unable to read release changelog history."
$releaseNotesLines = @(
  "## Finatic MT Connector $releaseTag"
  ""
  "### Included artifacts"
  "- FinaticMT4ConnectorEA.ex4"
  "- FinaticMT5ConnectorEA.ex5"
  "- FinaticMT4ConnectorEA.mq4"
  "- FinaticMT5ConnectorEA.mq5"
  "- FinaticMT4ConnectorEA.build.log"
  "- FinaticMT5ConnectorEA.build.log"
  "- build-provenance.txt"
  "- checksums.sha256"
  ""
  "### Verification"
  '```bash'
  'sha256sum -c checksums.sha256'
  '```'
  ""
  "### Migration from v0.1.4"
  "Replace both the executable and source with this release, verify checksums, and allowlist the exact Finatic Connect ingest scheme and host. Keep v0.1.4 available for rollback. Do not disable signature enforcement."
  ""
  "### Recent changes"
  $recentChanges
)
[System.IO.File]::WriteAllLines($releaseNotesPath, $releaseNotesLines, [System.Text.UTF8Encoding]::new($false))

$checksumAssetNames = @(
  "FinaticMT4ConnectorEA.ex4"
  "FinaticMT5ConnectorEA.ex5"
  "FinaticMT4ConnectorEA.mq4"
  "FinaticMT5ConnectorEA.mq5"
  "FinaticMT4ConnectorEA.build.log"
  "FinaticMT5ConnectorEA.build.log"
  "build-provenance.txt"
  "release-notes.md"
)
$checksumLines = $checksumAssetNames | ForEach-Object {
  $publishedPath = Join-Path $distDirectory $_
  $fileHash = Get-FileHash $publishedPath -Algorithm SHA256
  "$($fileHash.Hash.ToLower())  $_"
}
$checksumPath = Join-Path $distDirectory "checksums.sha256"
[System.IO.File]::WriteAllLines($checksumPath, $checksumLines, [System.Text.UTF8Encoding]::new($false))

Write-Host "Local release artifacts prepared from immutable $releaseTag."
Write-Host "After dual-platform staging acceptance, rerun with -Publish to publish this exact checksummed bundle without recompiling."
