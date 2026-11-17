<#
.SYNOPSIS
  Adds the shared GitHub Actions workflow to add-on repos.

.DESCRIPTION
  Copies templates/addon-ci.yml to .github/workflows/addon.yml in each add-on.
  Run it again after changing the template to update them all. It only writes
  the file; commit and push it yourself.

    # Every add-on in the workspace
    powershell -ExecutionPolicy Bypass -File install-ci.ps1 -All

    # Just the add-on you're in
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\install-ci.ps1
#>
param(
  [string]$Repo = (Get-Location).Path,
  [switch]$All,
  [string]$Workspace = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$template = [IO.File]::ReadAllText((Join-Path (Join-Path $PSScriptRoot 'templates') 'addon-ci.yml'))
$repos = if ($All) { Get-AddonRepos $Workspace } else { @((Resolve-Path -LiteralPath $Repo).Path) }

foreach ($r in $repos) {
  $dir = Join-Path (Join-Path $r '.github') 'workflows'
  $target = Join-Path $dir 'addon.yml'
  $current = if (Test-Path -LiteralPath $target) { [IO.File]::ReadAllText($target) } else { $null }
  if ($current -eq $template) { Write-Host "  $(Split-Path $r -Leaf): already up to date"; continue }
  New-Item -ItemType Directory -Force $dir | Out-Null
  [IO.File]::WriteAllText($target, $template, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "  $(Split-Path $r -Leaf): $(if ($current) { 'updated' } else { 'added' })" -ForegroundColor Green
}
