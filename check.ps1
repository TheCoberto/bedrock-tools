<#
.SYNOPSIS
  Checks Bedrock add-ons for common mistakes before you build or release.

.DESCRIPTION
  Errors (the add-on is broken or won't load right):
    - manifest.json or any other .json file doesn't parse
    - a text file (.json, .lang, .mcfunction, .js...) isn't UTF-8, so color codes show up garbled
    - a pack or module UUID is invalid or used twice
    - a pack has .js files but no script module (the scripts never run), or the script entry is missing
    - a pack depends on another pack in the repo at the wrong version
  Warnings:
    - the version in the pack name doesn't match header.version
    - a Script API dependency with no script module
    - with -All: two add-ons share a module UUID (two add-ons sharing a PACK UUID is an error)

  Exits with code 1 if anything has an error, so GitHub Actions marks the run as failed.

    # The add-on you're in
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\check.ps1

    # Every add-on in the workspace, including clashes between add-ons
    powershell -ExecutionPolicy Bypass -File check.ps1 -All
#>
param(
  [string]$Repo = (Get-Location).Path,
  [switch]$All,
  [string]$Workspace = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$repos = if ($All) { Get-AddonRepos $Workspace } else { @((Resolve-Path -LiteralPath $Repo).Path) }

$errorCount = 0; $warningCount = 0
foreach ($r in $repos) {
  $issues = @(Get-AddonIssues $r)
  $e = @($issues | Where-Object Level -eq 'Error').Count
  $w = @($issues | Where-Object Level -eq 'Warning').Count
  $errorCount += $e; $warningCount += $w
  $status = if ($e) { "$e error(s)" } elseif ($w) { "OK, $w warning(s)" } else { 'OK' }
  $color = if ($e) { 'Red' } elseif ($w) { 'Yellow' } else { 'Green' }
  Write-Host ("{0,-32} {1}" -f (Split-Path $r -Leaf), $status) -ForegroundColor $color
  Write-Issues $issues '    '
}

if ($All) {
  $cross = @(Get-CrossRepoIssues $repos)
  if ($cross.Count) {
    Write-Host 'Between add-ons:'
    Write-Issues $cross '    '
    $errorCount += @($cross | Where-Object Level -eq 'Error').Count
    $warningCount += @($cross | Where-Object Level -eq 'Warning').Count
  }
}

Write-Host ''
if ($errorCount) {
  Write-Host "$errorCount error(s), $warningCount warning(s)." -ForegroundColor Red
  exit 1
}
Write-Host "No errors. $warningCount warning(s)." -ForegroundColor Green
exit 0
