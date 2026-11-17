<#
.SYNOPSIS
  Updates an add-on's version everywhere at once.

.DESCRIPTION
  In every pack of the add-on, sets the new version in:
    - header.version
    - each module's version (the ones that matched the old version)
    - dependencies on the add-on's own packs (e.g. the BP's dependency on its RP)
    - the version shown in the pack name, like "Snowfall [1.1.0]" or "v1.1.0"
    - pack.name in texts/*.lang, when the manifest uses a language key for its name
  Everything else in the files is left exactly as it was.

    # From inside an add-on repo
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\bump.ps1 -Part minor   # 1.1.0 -> 1.2.0
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\bump.ps1 -Version 2.0.0

  Remember to add a changelog entry afterwards.

.PARAMETER Part
  Which part to increase: major (1.4.2 -> 2.0.0), minor (1.4.2 -> 1.5.0) or
  patch (1.4.2 -> 1.4.3). Defaults to patch.

.PARAMETER Version
  Set an exact version instead, like 2.0.0.

.PARAMETER Repo
  The add-on repo. Defaults to the current folder.

.PARAMETER WhatIf
  Show what would change without changing anything.
#>
param(
  [ValidateSet('major', 'minor', 'patch')]
  [string]$Part = 'patch',
  [string]$Version,
  [string]$Repo = (Get-Location).Path,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Repo = (Resolve-Path -LiteralPath $Repo).Path
$packs = @(Get-Packs $Repo)
$broken = @($packs | Where-Object { $_.Error })
if ($broken.Count) { throw "Fix these manifests first: $($broken.Path -join ', ')" }
if (-not $packs.Count) { throw "No packs found in $Repo." }

# Work out the new version from the behavior pack's current one.
$main = Get-MainPack $packs
$old = @($main.Manifest.header.version | ForEach-Object { [int]$_ })
if ($Version) {
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3, not '$Version'." }
  $new = @($Version.Split('.') | ForEach-Object { [int]$_ })
} else {
  $new = switch ($Part) {
    'major' { @(($old[0] + 1), 0, 0) }
    'minor' { @($old[0], ($old[1] + 1), 0) }
    'patch' { @($old[0], $old[1], ($old[2] + 1)) }
  }
}
$newText = $new -join '.'
Write-Host "$(Split-Path $Repo -Leaf): $(Get-VersionString $old) -> $newText"

# Replaces a version array like [ 1, 0, 2 ] after a "version" key, keeping its spacing and line breaks.
function Set-VersionArrays([string]$text, [int[]]$from, [int[]]$to) {
  $pattern = '("version"\s*:\s*\[)(\s*)' + $from[0] + '(\s*,\s*)' + $from[1] + '(\s*,\s*)' + $from[2] + '(\s*\])'
  return [regex]::Replace($text, $pattern, {
      param($m)
      $m.Groups[1].Value + $m.Groups[2].Value + $to[0] + $m.Groups[3].Value + $to[1] + $m.Groups[4].Value + $to[2] + $m.Groups[5].Value
    })
}

# Replaces the version shown in a name, like [1.0.2] or v1.0.2.
function Set-NameVersion([string]$name, [string]$fromText, [string]$toText) {
  return $name -replace ('(?<=\[v?|\bv)' + [regex]::Escape($fromText) + '\b'), $toText
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$changed = 0
foreach ($pack in $packs) {
  $path = $pack.Path
  $bytes = [IO.File]::ReadAllBytes($path)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $text = [IO.File]::ReadAllText($path)
  $before = $text

  # Every "version" array equal to this pack's old version: header, modules, and
  # dependencies on the add-on's own packs (which always match the old version).
  $packOld = @($pack.Manifest.header.version | ForEach-Object { [int]$_ })
  $text = Set-VersionArrays $text $packOld $new
  if ((Get-VersionString $packOld) -ne (Get-VersionString $old)) { $text = Set-VersionArrays $text $old $new }

  # The version in the header's name.
  $nameMatch = [regex]::Match($text, '("name"\s*:\s*")((?:[^"\\]|\\.)*)(")')
  if ($nameMatch.Success) {
    $newName = Set-NameVersion $nameMatch.Groups[2].Value (Get-VersionString $packOld) $newText
    if ($newName -ne $nameMatch.Groups[2].Value) {
      $text = $text.Substring(0, $nameMatch.Groups[2].Index) + $newName + $text.Substring($nameMatch.Groups[2].Index + $nameMatch.Groups[2].Length)
    }
  }

  if ($text -ne $before) {
    $changed++
    Write-Host "  $(Get-RelativePath $Repo $path)"
    if (-not $WhatIf) {
      $out = $utf8.GetBytes($text)
      if ($hasBom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
      [IO.File]::WriteAllBytes($path, $out)
    }
  }

  # Names kept in a language file (e.g. "pack.name=Better on Bedrock v1.1.2").
  $key = [string]$pack.Manifest.header.name
  $langDir = Join-Path $pack.Dir 'texts'
  if ($key -match '^[\w.]+$' -and (Test-Path -LiteralPath $langDir)) {
    $fromText = Get-VersionString $packOld
    foreach ($lang in Get-ChildItem -LiteralPath $langDir -Filter '*.lang' -File) {
      $langBytes = [IO.File]::ReadAllBytes($lang.FullName)
      $langBom = $langBytes.Length -ge 3 -and $langBytes[0] -eq 0xEF -and $langBytes[1] -eq 0xBB -and $langBytes[2] -eq 0xBF
      $raw = [IO.File]::ReadAllText($lang.FullName)
      # Only the "<key>=..." line; line endings and everything else stay as they were.
      $updated = [regex]::Replace($raw, '(?m)^' + [regex]::Escape($key) + '=.*$', {
          param($m)
          Set-NameVersion $m.Value $fromText $newText
        })
      if ($updated -ne $raw) {
        $changed++
        Write-Host "  $(Get-RelativePath $Repo $lang.FullName)"
        if (-not $WhatIf) {
          $out = $utf8.GetBytes($updated)
          if ($langBom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
          [IO.File]::WriteAllBytes($lang.FullName, $out)
        }
      }
    }
  }
}

if ($WhatIf) { Write-Host "$changed file(s) would change. Nothing was written (-WhatIf)."; exit 0 }
Write-Host "Updated $changed file(s). Add a changelog entry for $newText, then build." -ForegroundColor Green

# Make sure the result still checks out.
$errors = @(Get-AddonIssues $Repo | Where-Object Level -eq 'Error')
if ($errors.Count) {
  Write-Host 'The check found errors after bumping:' -ForegroundColor Red
  Write-Issues $errors
  exit 1
}
