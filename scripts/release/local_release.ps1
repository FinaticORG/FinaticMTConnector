param(
  [ValidateSet("patch", "minor", "major")]
  [string]$Bump = "patch",
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

  Set-Content -Path $pyprojectPath -Value $updatedContent -Encoding UTF8
}

function Resolve-MetaEditorPath {
  param([string[]]$Candidates, [string]$Label)

  foreach ($candidatePath in $Candidates) {
    if (Test-Path $candidatePath) {
      return $candidatePath
    }
  }

  throw "Unable to locate MetaEditor for $Label. Check local MT installation."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $repoRoot

$nextVersion = Get-NextVersion -BumpType $Bump
$releaseTag = "v$nextVersion"
$distDirectory = Join-Path $repoRoot "dist\ea"

Write-Host "Preparing release $releaseTag"

python -m pip --version | Out-Null
uv run poe ci-fast

Update-PyprojectVersion -VersionValue $nextVersion

$mt4EditorPath = Resolve-MetaEditorPath -Candidates @(
  "C:\Program Files\MetaTrader 4\metaeditor.exe",
  "C:\Program Files (x86)\MetaTrader 4\metaeditor.exe"
) -Label "MT4"

$mt5EditorPath = Resolve-MetaEditorPath -Candidates @(
  "C:\Program Files\MetaTrader 5\metaeditor64.exe",
  "C:\Program Files (x86)\MetaTrader 5\metaeditor64.exe"
) -Label "MT5"

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

$mt4SourcePath = Join-Path $repoRoot "src\finatic_mt_connector\ea_reference\mt4\FinaticMT4ConnectorEA.mq4"
$mt5SourcePath = Join-Path $repoRoot "src\finatic_mt_connector\ea_reference\mt5\FinaticMT5ConnectorEA.mq5"
$mt4BuildLogPath = Join-Path $env:TEMP "mt4-build.log"
$mt5BuildLogPath = Join-Path $env:TEMP "mt5-build.log"

& $mt4EditorPath /compile:"$mt4SourcePath" /log:"$mt4BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt4BuildLogPath) { Get-Content $mt4BuildLogPath }
  throw "MT4 compilation failed."
}

& $mt5EditorPath /compile:"$mt5SourcePath" /log:"$mt5BuildLogPath"
if ($LASTEXITCODE -ne 0) {
  if (Test-Path $mt5BuildLogPath) { Get-Content $mt5BuildLogPath }
  throw "MT5 compilation failed."
}

$mt4BinaryPath = [System.IO.Path]::ChangeExtension($mt4SourcePath, ".ex4")
$mt5BinaryPath = [System.IO.Path]::ChangeExtension($mt5SourcePath, ".ex5")
if (-not (Test-Path $mt4BinaryPath)) { throw "Expected MT4 binary missing: $mt4BinaryPath" }
if (-not (Test-Path $mt5BinaryPath)) { throw "Expected MT5 binary missing: $mt5BinaryPath" }

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
