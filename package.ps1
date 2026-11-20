<#
.SYNOPSIS
  Checks an add-on and packages it into an importable .mcaddon file.

.DESCRIPTION
  Runs check.ps1 on the add-on first and stops if it finds errors. Then finds
  every pack in the repo (any folder with a manifest.json) and builds
  <Name>-<version>.mcaddon with all of them. The name and version come from the
  behavior pack's manifest, e.g. "Snowfall [1.1.0]" -> Snowfall-1.1.0.mcaddon.

    # From inside an add-on repo: builds into the shared builds folder
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\package.ps1

    # A specific repo
    powershell -ExecutionPolicy Bypass -File package.ps1 -Repo ..\skeleton-variants

  Double-clicking a built file imports it into Minecraft. Importing an
  .mcaddon only adds the packs to the library; each world still chooses which
  packs to turn on.

.PARAMETER Repo
  The add-on repo to package. Defaults to the current folder.

.PARAMETER OutDir
  Where to write the files. Defaults to the "builds" folder next to the repo
  (C:\Repos\Mods\Minecraft Bedrock\builds). A file with the same name is
  replaced; other files are left alone.

.PARAMETER PerPack
  Also build a separate .mcpack for each pack (e.g. a thaw pack on its own).

.PARAMETER SkipCheck
  Build without running the check first.
#>
param(
  [string]$Repo = (Get-Location).Path,
  [string]$OutDir,
  [switch]$PerPack,
  [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Repo = (Resolve-Path -LiteralPath $Repo).Path
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $Repo -Parent) 'builds' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# --- Check ------------------------------------------------------------------

if (-not $SkipCheck) {
  $issues = @(Get-AddonIssues $Repo)
  $errors = @($issues | Where-Object Level -eq 'Error')
  if ($errors.Count) {
    Write-Host "Not building $(Split-Path $Repo -Leaf): the check found $($errors.Count) error(s)." -ForegroundColor Red
    Write-Issues $errors
    Write-Host 'Fix them, or rerun with -SkipCheck to build anyway.'
    exit 1
  }
}

# --- Find the packs ---------------------------------------------------------

$packs = @(Get-Packs $Repo | Where-Object { $_.Manifest })
if (-not $packs.Count) { throw "No packs (folders with manifest.json) found in $Repo." }

$main    = Get-MainPack $packs
$name    = Get-CleanName (Get-PackName $main)
$version = Get-VersionString $main.Manifest.header.version

# --- Zip helper -------------------------------------------------------------

# Builds the zip with .NET directly instead of Compress-Archive: Windows
# PowerShell's Compress-Archive writes backslashes in entry names, which can
# break imports on Android, iOS and console. Zip entries must use "/".
function New-PackArchive {
  param(
    [hashtable]$Sources,  # folder name inside the zip ("" = zip root) -> folder on disk
    [string]$OutName
  )
  $final = Join-Path $OutDir $OutName
  if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final }
  $zip = [IO.Compression.ZipFile]::Open($final, 'Create')
  try {
    foreach ($prefix in $Sources.Keys) {
      $folder = $Sources[$prefix]
      foreach ($file in Get-PackFiles $folder) {
        $relative = (Get-RelativePath $folder $file.FullName) -replace '\\', '/'
        $entry = if ($prefix) { "$prefix/$relative" } else { $relative }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry) | Out-Null
      }
    }
  } finally {
    $zip.Dispose()
  }
  Write-Host ('  {0}  ({1} KB)' -f $OutName, [math]::Round((Get-Item -LiteralPath $final).Length / 1KB))
}

# --- Build ------------------------------------------------------------------

Write-Host "Packaging $name $version ($($packs.Count) packs) into $OutDir"

# .mcaddon: each pack FOLDER sits at the root of the zip.
$all = @{}
foreach ($p in $packs) { $all[(Split-Path $p.Dir -Leaf)] = $p.Dir }
New-PackArchive -Sources $all -OutName "$name-$version.mcaddon"

# .mcpack: the pack's CONTENTS sit at the root of the zip (manifest.json at top level).
if ($PerPack) {
  foreach ($p in $packs) {
    $packName = Get-CleanName (Get-PackName $p)
    $packVersion = Get-VersionString $p.Manifest.header.version
    $kind = Get-PackKind $p.Manifest
    New-PackArchive -Sources @{ '' = $p.Dir } -OutName "$packName-$kind-$packVersion.mcpack"
  }
}
