param(
  [ValidateSet("patch", "minor", "major")]
  [string]$Bump = "patch",
  [string]$MT4MetaEditorPath = "",
  [string]$MT5MetaEditorPath = "",
  [switch]$Publish
)

$ErrorActionPreference = "Stop"

function Get-NextVersion {
  param([string]$BumpType)

  $latestTag = git tag -l "v*" --sort=-v:refname | Select-Object -First 1
  if (-not $latestTag) {
    $latestTag = "v0.1.0"
  }

  $versionParts = $latestTag.TrimStart("v").Split(".")
  $major = [int]$versionParts[0]
  $minor = [int]$versionParts[1]
  $patch = [int]$versionParts[2]

  if ($BumpType -eq "major") {
    return "$($major + 1).0.0"
  }
  if ($BumpType -eq "minor") {
    return "$major.$($minor + 1).0"
  }
  return "$major.$minor.$($patch + 1)"
}

function Update-PyprojectVersion {
  param([string]$VersionValue)

  $pyprojectPath = Join-Path $PSScriptRoot "..\..\pyproject.toml"
  $pyprojectContent = Get-Content $pyprojectPath
  $updatedContent = @()
  $updated = $false

  foreach ($line in $pyprojectContent) {
    if (-not $updated -and $line -like 'version = "*"') {
      $updatedContent += "version = `"$VersionValue`""
      $updated = $true
    } else {
      $updatedContent += $line
    }
  }

  if (-not $updated) {
    throw "Unable to update project version in pyproject.toml."
  }

  $utf8WithoutBomEncoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText(
    $pyprojectPath,
    ($updatedContent -join "`n") + "`n",
    $utf8WithoutBomEncoding
  )
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

function Resolve-CompiledBinaryPath {
  param(
    [string]$ExpectedPath,
    [string]$BinaryFilename,
    [string]$PlatformFolderName,
    [datetime]$CompileStartedAtUtc
  )

  if (Test-Path $ExpectedPath) {
    return $ExpectedPath
  }

  $searchRoots = @(
    (Split-Path -Parent $ExpectedPath),
    "$env:APPDATA\MetaQuotes\Terminal",
    "$env:LOCALAPPDATA\MetaQuotes\Terminal",
    "C:\Program Files\MetaTrader 4",
    "C:\Program Files (x86)\MetaTrader 4",
    "C:\Program Files\MetaTrader 5",
    "C:\Program Files (x86)\MetaTrader 5"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

  $candidateFiles = @()
  foreach ($searchRoot in $searchRoots) {
    $candidateFiles += Get-ChildItem -Path $searchRoot -Recurse -Filter $BinaryFilename -ErrorAction SilentlyContinue
  }

  $freshCandidateFiles = $candidateFiles | Where-Object {
    $_.LastWriteTimeUtc -ge $CompileStartedAtUtc.AddMinutes(-1)
  }

  if ($freshCandidateFiles) {
    $preferredFreshFile = $freshCandidateFiles |
      Where-Object { $_.FullName -match "$PlatformFolderName\\Experts" } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1
    if ($preferredFreshFile) {
      return $preferredFreshFile.FullName
    }
    return ($freshCandidateFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
  }

  if (-not $candidateFiles) {
    throw "Expected binary missing: $ExpectedPath and no fallback match for $BinaryFilename"
  }

  $preferredFile = $candidateFiles |
    Where-Object { $_.FullName -match "$PlatformFolderName\\Experts" } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

  if ($preferredFile) {
    return $preferredFile.FullName
  }

  return ($candidateFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
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

$nextVersion = Get-NextVersion -BumpType $Bump
$releaseTag = "v$nextVersion"
$distDirectory = Join-Path $repoRoot "dist\ea"

Write-Host "Preparing release $releaseTag"
uv run poe ci-fast

Update-PyprojectVersion -VersionValue $nextVersion

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
$mt4BuildLogPath = Join-Path $env:TEMP "mt4-build.log"
$mt5BuildLogPath = Join-Path $env:TEMP "mt5-build.log"

$mt4TerminalRootPath = Get-TerminalRootFromMetaEditor -MetaEditorPath $mt4EditorPath
$mt5TerminalRootPath = Get-TerminalRootFromMetaEditor -MetaEditorPath $mt5EditorPath

$mt4ExpertsPath = Resolve-ExpertsDirectoryPath -PlatformFolderName "MQL4" -TerminalRootPath $mt4TerminalRootPath
$mt5ExpertsPath = Resolve-ExpertsDirectoryPath -PlatformFolderName "MQL5" -TerminalRootPath $mt5TerminalRootPath

$mt4CompilePath = Join-Path $mt4ExpertsPath "FinaticMT4ConnectorEA.mq4"
$mt5CompilePath = Join-Path $mt5ExpertsPath "FinaticMT5ConnectorEA.mq5"

Copy-Item $mt4SourcePath $mt4CompilePath -Force
Copy-Item $mt5SourcePath $mt5CompilePath -Force

$mt4CompileStartedAtUtc = [datetime]::UtcNow
& $mt4EditorPath /compile:"$mt4CompilePath" /log:"$mt4BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt4BuildLogPath) { Get-Content $mt4BuildLogPath }
  throw "MT4 compilation failed."
}

$mt5CompileStartedAtUtc = [datetime]::UtcNow
& $mt5EditorPath /compile:"$mt5CompilePath" /log:"$mt5BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt5BuildLogPath) { Get-Content $mt5BuildLogPath }
  throw "MT5 compilation failed."
}

$mt4BinaryPath = [System.IO.Path]::ChangeExtension($mt4CompilePath, ".ex4")
$mt5BinaryPath = [System.IO.Path]::ChangeExtension($mt5CompilePath, ".ex5")
try {
  $mt4BinaryPath = Resolve-CompiledBinaryPath -ExpectedPath $mt4BinaryPath -BinaryFilename "FinaticMT4ConnectorEA.ex4" -PlatformFolderName "MQL4" -CompileStartedAtUtc $mt4CompileStartedAtUtc
} catch {
  if (Test-Path $mt4BuildLogPath) {
    Write-Host "---- MT4 build log ----"
    Get-Content $mt4BuildLogPath
    Write-Host "-----------------------"
  }
  throw
}
try {
  $mt5BinaryPath = Resolve-CompiledBinaryPath -ExpectedPath $mt5BinaryPath -BinaryFilename "FinaticMT5ConnectorEA.ex5" -PlatformFolderName "MQL5" -CompileStartedAtUtc $mt5CompileStartedAtUtc
} catch {
  if (Test-Path $mt5BuildLogPath) {
    Write-Host "---- MT5 build log ----"
    Get-Content $mt5BuildLogPath
    Write-Host "-----------------------"
  }
  throw
}

Copy-Item $mt4BinaryPath (Join-Path $distDirectory "FinaticMT4ConnectorEA.ex4") -Force
Copy-Item $mt5BinaryPath (Join-Path $distDirectory "FinaticMT5ConnectorEA.ex5") -Force
if (Test-Path $mt4BuildLogPath) { Copy-Item $mt4BuildLogPath (Join-Path $distDirectory "FinaticMT4ConnectorEA.build.log") -Force }
if (Test-Path $mt5BuildLogPath) { Copy-Item $mt5BuildLogPath (Join-Path $distDirectory "FinaticMT5ConnectorEA.build.log") -Force }

$checksumLines = Get-ChildItem $distDirectory -File |
  Where-Object { $_.Name -ne "checksums.sha256" } |
  ForEach-Object {
    $fileHash = Get-FileHash $_.FullName -Algorithm SHA256
    "$($fileHash.Hash.ToLower())  $($_.Name)"
  }
$checksumPath = Join-Path $distDirectory "checksums.sha256"
Set-Content -Path $checksumPath -Value $checksumLines -Encoding UTF8

$releaseNotesPath = Join-Path $distDirectory "release-notes.md"
$recentChanges = git log --oneline -n 15
@"
## Finatic MT Connector $releaseTag

### Included artifacts
- FinaticMT4ConnectorEA.ex4
- FinaticMT5ConnectorEA.ex5
- checksums.sha256

### Verification
\`\`\`bash
sha256sum -c checksums.sha256
\`\`\`

### Recent changes
$recentChanges
"@ | Set-Content -Path $releaseNotesPath -Encoding UTF8

git add pyproject.toml
git commit -m "chore(release): $releaseTag [skip ci] [skip release]"
git tag $releaseTag

if ($Publish) {
  git push origin develop
  git push origin $releaseTag
  gh release create $releaseTag `
    "$distDirectory\FinaticMT4ConnectorEA.ex4" `
    "$distDirectory\FinaticMT5ConnectorEA.ex5" `
    "$distDirectory\checksums.sha256" `
    "$distDirectory\release-notes.md" `
    --repo FinaticORG/FinaticMTConnector `
    --title "Finatic MT Connector $releaseTag" `
    --notes-file "$distDirectory\release-notes.md"
  Write-Host "Release published: $releaseTag"
} else {
  Write-Host "Local release prepared: $releaseTag"
  Write-Host "Run these when ready:"
  Write-Host "  git push origin develop"
  Write-Host "  git push origin $releaseTag"
  Write-Host "  gh release create $releaseTag dist/ea/FinaticMT4ConnectorEA.ex4 dist/ea/FinaticMT5ConnectorEA.ex5 dist/ea/checksums.sha256 dist/ea/release-notes.md --repo FinaticORG/FinaticMTConnector --title `"Finatic MT Connector $releaseTag`" --notes-file dist/ea/release-notes.md"
}
