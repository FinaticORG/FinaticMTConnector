function Invoke-CheckedNativeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailureMessage
  )

  & $Command @Arguments
  $nativeExitCode = $LASTEXITCODE
  if ($nativeExitCode -ne 0) {
    throw "$FailureMessage Exit code: $nativeExitCode"
  }
}

function Invoke-CheckedNativeOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$FailureMessage
  )

  $nativeOutput = & $Command @Arguments
  $nativeExitCode = $LASTEXITCODE
  if ($nativeExitCode -ne 0) {
    throw "$FailureMessage Exit code: $nativeExitCode"
  }
  return $nativeOutput
}

function Assert-GitHubReleaseAbsent {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$ReleaseTag
  )

  $releaseEndpoint = "/repos/$Repository/releases/tags/$ReleaseTag"
  $lookupOutput = & gh api $releaseEndpoint --include 2>&1
  $lookupExitCode = $LASTEXITCODE
  $lookupText = $lookupOutput -join [Environment]::NewLine

  if ($lookupExitCode -eq 0) {
    throw "GitHub Release $ReleaseTag already exists; immutable releases are not overwritten."
  }

  $verifiedNotFound = $lookupText -match '(?im)(HTTP/[^ ]+ 404\b|HTTP 404\b|Not Found \(HTTP 404\))'
  if (-not $verifiedNotFound) {
    throw "Unable to verify that GitHub Release $ReleaseTag is absent. gh api exit code: $lookupExitCode"
  }

  # The verified 404 is the one expected non-zero result. Clear it so a caller
  # cannot accidentally propagate the probe failure as the step/script result.
  $global:LASTEXITCODE = 0
}
