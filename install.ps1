<#
.SYNOPSIS
  Installs the add-ons in the builds folder into Minecraft Bedrock on this PC.

.DESCRIPTION
  Like double-clicking every .mcaddon, but tidier:
    - Each pack replaces the installed pack with the same UUID, in the same
      folder, instead of being added next to it.
    - Packs that already match the build are left alone. Line endings don't
      count as a difference.
    - Packs that aren't installed yet go into development_behavior_packs and
      development_resource_packs.
    - Every replaced or removed pack is backed up first, to <Workspace>\pack-backups.
      Only the newest 5 backups are kept (change it with -KeepBackups).
    - Packs listed in retired.json (add-ons that were replaced by another one)
      are removed.
    - If builds holds several versions of an add-on, only the newest is used.
  Packs that aren't in builds or retired.json are never touched.

  Close Minecraft first: it only reads packs when it starts.

    powershell -ExecutionPolicy Bypass -File install.ps1            # from bedrock-tools
    powershell -ExecutionPolicy Bypass -File install.ps1 -WhatIf    # show what would change

.PARAMETER Workspace
  The folder that holds the add-on repos. Defaults to the folder bedrock-tools is in.

.PARAMETER BuildsDir
  Where the .mcaddon files are. Defaults to <Workspace>\builds.

.PARAMETER MinecraftDir
  Minecraft's com.mojang folder. Found automatically: the current Windows
  version keeps it in %APPDATA%\Minecraft Bedrock\Users\Shared\games, older
  versions in the Microsoft Store app's LocalState folder.

.PARAMETER WhatIf
  Show what would change without changing anything.

.PARAMETER KeepBackups
  How many backup folders in pack-backups to keep. Older ones are deleted after an install.

.PARAMETER Force
  Install even while Minecraft is running. It won't see the changes until it restarts.
#>
param(
  [string]$Workspace = (Split-Path $PSScriptRoot -Parent),
  [string]$BuildsDir,
  [string]$MinecraftDir,
  [switch]$WhatIf,
  [switch]$Force,
  [int]$KeepBackups = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
if (-not $BuildsDir) { $BuildsDir = Join-Path $Workspace 'builds' }
if (-not (Test-Path -LiteralPath $BuildsDir)) { throw "No builds folder at $BuildsDir. Run build-all.ps1 first." }

if (-not $MinecraftDir) {
  $candidates = @(
    (Join-Path $env:APPDATA 'Minecraft Bedrock\Users\Shared\games\com.mojang'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.MinecraftUWP_8wekyb3d8bbwe\LocalState\games\com.mojang')
  )
  $MinecraftDir = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $MinecraftDir) { throw "Couldn't find Minecraft's com.mojang folder. Pass it with -MinecraftDir." }
}
Write-Host "Minecraft folder: $MinecraftDir"

$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Minecraft.Windows*' })
if ($running.Count -and -not $Force -and -not $WhatIf) {
  throw 'Minecraft is running. Close it first (it only reads packs when it starts), or pass -Force.'
}

$devFolders = @{
  BP = Join-Path $MinecraftDir 'development_behavior_packs'
  RP = Join-Path $MinecraftDir 'development_resource_packs'
}
$packFolders = @($devFolders.BP, $devFolders.RP,
  (Join-Path $MinecraftDir 'behavior_packs'), (Join-Path $MinecraftDir 'resource_packs')) |
  Where-Object { Test-Path -LiteralPath $_ }

$backupDir = Join-Path (Join-Path $Workspace 'pack-backups') (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
$counts = @{ same = 0; replaced = 0; installed = 0; removed = 0 }

# A fingerprint of a pack's files. Text files are compared without line endings,
# since GitHub builds on Linux and local builds on Windows.
function Get-PackFingerprint([string]$Dir) {
  $sha = [Security.Cryptography.SHA1]::Create()
  $parts = foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object { Get-RelativePath $Dir $_.FullName }) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($script:TextExtensions -contains $f.Extension.ToLower()) {
      $text = [Text.Encoding]::UTF8.GetString($bytes) -replace "`r`n", "`n"
      $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    }
    (Get-RelativePath $Dir $f.FullName).Replace('\', '/') + '=' + [BitConverter]::ToString($sha.ComputeHash($bytes))
  }
  return ($parts -join ';')
}

function Backup-Pack([string]$Dir) {
  $dest = Join-Path $backupDir (Split-Path (Split-Path $Dir -Parent) -Leaf)
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  Move-Item -LiteralPath $Dir -Destination (Join-Path $dest (Split-Path $Dir -Leaf))
}

# Installed packs, by header UUID.
$installed = @{}
foreach ($folder in $packFolders) {
  foreach ($d in Get-ChildItem -LiteralPath $folder -Directory) {
    $manifestPath = Join-Path $d.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
    try { $m = Read-JsonFile $manifestPath } catch { continue }
    $key = ([string]$m.header.uuid).ToLower()
    if ($installed.ContainsKey($key)) {
      Write-Host "  warn  $($d.FullName) has the same UUID as $($installed[$key]). Only the first is updated." -ForegroundColor Yellow
      continue
    }
    $installed[$key] = $d.FullName
  }
}

# Unpack every build, then keep only the newest version of each pack.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('bedrock-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $newest = @{}
  foreach ($addon in Get-ChildItem -LiteralPath $BuildsDir -Filter '*.mcaddon' -File) {
    $dest = Join-Path $temp $addon.BaseName
    [IO.Compression.ZipFile]::ExtractToDirectory($addon.FullName, $dest)
    foreach ($pack in Get-Packs $dest) {
      if ($pack.Error) { Write-Host "  ERROR $($addon.Name): $($pack.Error)" -ForegroundColor Red; continue }
      $key = ([string]$pack.Manifest.header.uuid).ToLower()
      $version = [version](Get-VersionString $pack.Manifest.header.version)
      if ($newest.ContainsKey($key) -and $newest[$key].Version -ge $version) { continue }
      $newest[$key] = [pscustomobject]@{ Pack = $pack; Version = $version; Addon = $addon.Name }
    }
  }

  foreach ($key in $newest.Keys | Sort-Object { $newest[$_].Addon }) {
    $item = $newest[$key]
    $pack = $item.Pack
    $label = "$(Split-Path $pack.Dir -Leaf) $($item.Version)  [$($item.Addon)]"
    $old = $installed[$key]

    if ($old -and (Get-PackFingerprint $old) -eq (Get-PackFingerprint $pack.Dir)) {
      $counts.same++
      continue
    }

    if ($old) {
      # Keep the installed folder name: some add-ons ship their pack as a generic "addon" folder.
      $target = $old
      Write-Host "  update   $label -> $(Split-Path $old -Leaf)" -ForegroundColor Cyan
      $counts.replaced++
    } else {
      $kind = Get-PackKind $pack.Manifest
      $parent = if ($kind -eq 'RP') { $devFolders.RP } else { $devFolders.BP }
      $name = Split-Path $pack.Dir -Leaf
      $target = Join-Path $parent $name
      for ($n = 2; Test-Path -LiteralPath $target; $n++) { $target = Join-Path $parent "$name ($n)" }
      Write-Host "  install  $label -> $(Split-Path $target -Leaf)" -ForegroundColor Green
      $counts.installed++
    }
    if ($WhatIf) { continue }

    if ($old) { Backup-Pack $old }
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $pack.Dir -Destination $target -Recurse
  }
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# Retired packs: add-ons that another add-on replaced.
$retiredFile = Join-Path $PSScriptRoot 'retired.json'
if (Test-Path -LiteralPath $retiredFile) {
  foreach ($r in @((Read-JsonFile $retiredFile).packs)) {
    $old = $installed[([string]$r.uuid).ToLower()]
    if (-not $old -or -not (Test-Path -LiteralPath $old)) { continue }
    Write-Host "  remove   $(Split-Path $old -Leaf) ($($r.reason))" -ForegroundColor Magenta
    $counts.removed++
    if (-not $WhatIf) { Backup-Pack $old }
  }
}

Write-Host ''
$summary = "$($counts.replaced) updated, $($counts.installed) installed, $($counts.removed) removed, $($counts.same) already up to date."
if ($WhatIf) { Write-Host "Would change: $summary (nothing was changed)" -ForegroundColor Yellow; exit 0 }
Write-Host $summary -ForegroundColor Green
if (Test-Path -LiteralPath $backupDir) { Write-Host "Old copies are in $backupDir" }

# Keep only the newest backups.
$old = @(Get-ChildItem -LiteralPath (Join-Path $Workspace 'pack-backups') -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -Skip $KeepBackups)
if ($old.Count) {
  $old | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
  Write-Host "Deleted $($old.Count) older backup(s), keeping the newest $KeepBackups."
}
if ($running.Count) { Write-Host 'Restart Minecraft to load the changes.' -ForegroundColor Yellow }
exit 0
