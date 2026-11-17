<#
.SYNOPSIS
  Checks and builds every add-on in the workspace in one go.

.DESCRIPTION
  Finds every folder next to bedrock-tools that contains a pack, checks them all
  (including clashes between add-ons), and builds each one into the builds
  folder. An add-on with errors is skipped and listed at the end; the others
  still build.

    powershell -ExecutionPolicy Bypass -File build-all.ps1

.PARAMETER Workspace
  The folder that holds the add-on repos. Defaults to the folder bedrock-tools is in.

.PARAMETER OutDir
  Where to write the files. Defaults to <Workspace>\builds.

.PARAMETER Force
  Build add-ons even if the check finds errors in them.
#>
param(
  [string]$Workspace = (Split-Path $PSScriptRoot -Parent),
  [string]$OutDir,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
if (-not $OutDir) { $OutDir = Join-Path $Workspace 'builds' }

$repos = Get-AddonRepos $Workspace
Write-Host "Checking $($repos.Count) add-ons..."

$skipped = @()
$toBuild = @()
foreach ($repo in $repos) {
  $errors = @(Get-AddonIssues $repo | Where-Object Level -eq 'Error')
  if ($errors.Count -and -not $Force) {
    $skipped += Split-Path $repo -Leaf
    Write-Host "  $(Split-Path $repo -Leaf): $($errors.Count) error(s), skipping" -ForegroundColor Red
    Write-Issues $errors '    '
  } else {
    $toBuild += $repo
  }
}
$cross = @(Get-CrossRepoIssues $repos | Where-Object Level -eq 'Error')
if ($cross.Count) {
  Write-Host 'Clashes between add-ons (fix these before releasing):' -ForegroundColor Red
  Write-Issues $cross '    '
}

Write-Host ''
Write-Host "Building $($toBuild.Count) add-ons into $OutDir"
$failed = @()
foreach ($repo in $toBuild) {
  try {
    & (Join-Path $PSScriptRoot 'package.ps1') -Repo $repo -OutDir $OutDir -SkipCheck | Out-Null
    if ($LASTEXITCODE) { throw "exit code $LASTEXITCODE" }
    Write-Host "  built $(Split-Path $repo -Leaf)" -ForegroundColor Green
  } catch {
    $failed += Split-Path $repo -Leaf
    Write-Host "  FAILED $(Split-Path $repo -Leaf): $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host ''
$built = $toBuild.Count - $failed.Count
Write-Host "Built $built of $($repos.Count) add-ons." -ForegroundColor $(if ($skipped.Count -or $failed.Count) { 'Yellow' } else { 'Green' })
if ($skipped.Count) { Write-Host "Skipped (check errors): $($skipped -join ', ')" -ForegroundColor Yellow }
if ($failed.Count)  { Write-Host "Failed to build: $($failed -join ', ')" -ForegroundColor Red }
if ($skipped.Count -or $failed.Count) { exit 1 }
exit 0
