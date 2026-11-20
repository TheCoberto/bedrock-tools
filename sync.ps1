<#
.SYNOPSIS
  Copies shared files from another add-on into this one.

.DESCRIPTION
  Some add-ons share content with another one (Bow Variants uses the bows from
  Skeleton Variants). The source add-on is where those files are edited; this
  copies them across so the two can't drift apart.

  The add-on that receives the files has a sync.json at its root:

    {
      "source": "../skeleton-variants",
      "packs": [
        {
          "from": "TheCoberto's Skeleton Variants/RP Skeleton Variants",
          "to": "Bow Variants RP",
          "files": [ "entity/explosive_arrow.json", "textures/items/explosive_bow*.png" ],
          "json": [
            { "file": "textures/item_texture.json", "path": "texture_data", "keys": [ "explosive_bow" ] }
          ],
          "lang": [
            { "file": "texts/en_US.lang", "keys": [ "item.thecoberto:explosive_arrow.name" ] }
          ]
        }
      ]
    }

  - "files" are copied whole. A * or ? in the file name matches several files.
  - "json" entries copy only the listed keys from the object at "path" (dots for
    nested objects, like "a.b"). The file's other keys are left alone.
  - "lang" entries copy only the listed key=value lines.

    # From inside the add-on that receives the files
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\sync.ps1
    powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\sync.ps1 -Check

.PARAMETER Repo
  The add-on that receives the files. Defaults to the current folder.

.PARAMETER Check
  Only report what differs. Exits with code 1 if anything is out of sync.
#>
param(
  [string]$Repo = (Get-Location).Path,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Repo = (Resolve-Path -LiteralPath $Repo).Path
$configPath = Join-Path $Repo 'sync.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "No sync.json in $Repo." }
$config = Read-JsonFile $configPath

$sourceRepo = Join-Path $Repo $config.source
if (-not (Test-Path -LiteralPath $sourceRepo)) { throw "The source add-on '$($config.source)' wasn't found next to this repo." }
$sourceRepo = (Resolve-Path -LiteralPath $sourceRepo).Path

$utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Differences = 0
$script:Problems = 0

function Write-Change([string]$what, [string]$path) {
  $script:Differences++
  Write-Host "  $what $path"
}

function Write-Problem([string]$message) {
  $script:Problems++
  Write-Host "  ERROR $message" -ForegroundColor Red
}

# --- JSON writing -----------------------------------------------------------------
# ConvertTo-Json in Windows PowerShell indents badly and escapes characters like §,
# so files that change are written with this instead (2 spaces, short arrays on one line).

function ConvertTo-JsonString([string]$s) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($c in $s.ToCharArray()) {
    switch ($c) {
      '"' { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      "`n" { [void]$sb.Append('\n') }
      "`r" { [void]$sb.Append('\r') }
      "`t" { [void]$sb.Append('\t') }
      default {
        if ([int]$c -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Test-Primitive($v) { return ($null -eq $v) -or ($v -is [string]) -or ($v -is [bool]) -or ($v -is [ValueType]) }

function Format-Json($v, [int]$depth = 0) {
  $pad = '  ' * $depth
  $inner = '  ' * ($depth + 1)
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return ConvertTo-JsonString $v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [ValueType]) { return [Convert]::ToString($v, [Globalization.CultureInfo]::InvariantCulture) }
  if ($v -is [System.Collections.IList]) {
    $items = @($v)
    if (-not $items.Count) { return '[]' }
    $allPrimitive = -not @($items | Where-Object { -not (Test-Primitive $_) }).Count
    if ($allPrimitive) {
      $line = '[ ' + (($items | ForEach-Object { Format-Json $_ }) -join ', ') + ' ]'
      if ($line.Length -le 80) { return $line }
    }
    $parts = $items | ForEach-Object { $inner + (Format-Json $_ ($depth + 1)) }
    return "[`n" + ($parts -join ",`n") + "`n$pad]"
  }
  $props = @($v.PSObject.Properties)
  if (-not $props.Count) { return '{}' }
  $parts = $props | ForEach-Object { $inner + (ConvertTo-JsonString $_.Name) + ': ' + (Format-Json $_.Value ($depth + 1)) }
  return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

# Follows a dotted path ("a.b") to an object, creating missing objects when asked.
function Get-JsonObject($root, [string]$path, [switch]$Create) {
  $node = $root
  if (-not $path) { return $node }
  foreach ($part in $path.Split('.')) {
    $prop = $node.PSObject.Properties[$part]
    if (-not $prop) {
      if (-not $Create) { return $null }
      $node | Add-Member -NotePropertyName $part -NotePropertyValue ([pscustomobject]@{})
      $prop = $node.PSObject.Properties[$part]
    }
    $node = $prop.Value
  }
  return $node
}

# --- Syncing ------------------------------------------------------------------------

function Sync-Files($pack, [string]$fromDir, [string]$toDir) {
  foreach ($pattern in @($pack.files)) {
    $relDir = Split-Path $pattern -Parent
    $leaf = Split-Path $pattern -Leaf
    $srcDir = Join-Path $fromDir $relDir
    $matches_ = @()
    if (Test-Path -LiteralPath $srcDir) {
      $matches_ = @(Get-ChildItem -LiteralPath $srcDir -File | Where-Object { $_.Name -like $leaf })
    }
    if (-not $matches_.Count) { Write-Problem "$pattern isn't in the source pack."; continue }

    foreach ($src in $matches_) {
      $dest = Join-Path (Join-Path $toDir $relDir) $src.Name
      $rel = Get-RelativePath $Repo $dest
      $srcBytes = [IO.File]::ReadAllBytes($src.FullName)
      if (Test-Path -LiteralPath $dest) {
        $destBytes = [IO.File]::ReadAllBytes($dest)
        # Git may have changed line endings in either copy, so text files ignore them.
        if ($script:TextExtensions -contains $src.Extension.ToLower()) {
          $same = ($utf8.GetString($srcBytes) -replace "`r`n", "`n") -eq ($utf8.GetString($destBytes) -replace "`r`n", "`n")
        } else {
          $same = [Linq.Enumerable]::SequenceEqual($srcBytes, $destBytes)
        }
        if ($same) { continue }
        Write-Change 'changed' $rel
      } else {
        Write-Change 'new    ' $rel
      }
      if (-not $Check) {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent))
        [IO.File]::WriteAllBytes($dest, $srcBytes)
      }
    }
  }
}

function Sync-JsonKeys($pack, [string]$fromDir, [string]$toDir) {
  foreach ($entry in @($pack.json)) {
    if (-not $entry) { continue }
    $srcPath = Join-Path $fromDir $entry.file
    $destPath = Join-Path $toDir $entry.file
    $rel = Get-RelativePath $Repo $destPath
    if (-not (Test-Path -LiteralPath $srcPath)) { Write-Problem "$($entry.file) isn't in the source pack."; continue }
    if (-not (Test-Path -LiteralPath $destPath)) { Write-Problem "$rel doesn't exist. Create it with the keys this add-on doesn't share, then sync."; continue }

    $srcObj = Get-JsonObject (Read-JsonFile $srcPath) $entry.path
    if ($null -eq $srcObj) { Write-Problem "$($entry.file) in the source has no '$($entry.path)'."; continue }
    $destRoot = Read-JsonFile $destPath
    $destObj = Get-JsonObject $destRoot $entry.path -Create

    $fileChanged = $false
    foreach ($key in @($entry.keys)) {
      $srcProp = $srcObj.PSObject.Properties[$key]
      if (-not $srcProp) { Write-Problem "$($entry.file) in the source has no '$key'."; continue }
      $destProp = $destObj.PSObject.Properties[$key]
      if ($destProp -and (Format-Json $destProp.Value) -eq (Format-Json $srcProp.Value)) { continue }
      Write-Change $(if ($destProp) { 'changed' } else { 'new    ' }) "$rel -> $key"
      if ($destProp) { $destProp.Value = $srcProp.Value }
      else { $destObj | Add-Member -NotePropertyName $key -NotePropertyValue $srcProp.Value }
      $fileChanged = $true
    }
    if ($fileChanged -and -not $Check) {
      [IO.File]::WriteAllText($destPath, (Format-Json $destRoot) + "`n", $utf8)
    }
  }
}

function Sync-LangKeys($pack, [string]$fromDir, [string]$toDir) {
  foreach ($entry in @($pack.lang)) {
    if (-not $entry) { continue }
    $srcPath = Join-Path $fromDir $entry.file
    $destPath = Join-Path $toDir $entry.file
    $rel = Get-RelativePath $Repo $destPath
    if (-not (Test-Path -LiteralPath $srcPath)) { Write-Problem "$($entry.file) isn't in the source pack."; continue }

    $srcLines = [IO.File]::ReadAllText($srcPath) -split "\r?\n"
    $text = if (Test-Path -LiteralPath $destPath) { [IO.File]::ReadAllText($destPath) } else { '' }
    $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $before = $text

    foreach ($key in @($entry.keys)) {
      $prefix = "$key="
      $srcLine = $srcLines | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
      if (-not $srcLine) { Write-Problem "$($entry.file) in the source has no '$key'."; continue }
      $pattern = '(?m)^' + [regex]::Escape($prefix) + '[^\r\n]*'
      $existing = [regex]::Match($text, $pattern)
      if ($existing.Success) {
        if ($existing.Value -eq $srcLine) { continue }
        Write-Change 'changed' "$rel -> $key"
        $text = $text.Substring(0, $existing.Index) + $srcLine + $text.Substring($existing.Index + $existing.Length)
      } else {
        Write-Change 'new    ' "$rel -> $key"
        if ($text.Length -and -not $text.EndsWith("`n")) { $text += $newline }
        $text += $srcLine + $newline
      }
    }
    if ($text -ne $before -and -not $Check) {
      [void](New-Item -ItemType Directory -Force -Path (Split-Path $destPath -Parent))
      [IO.File]::WriteAllText($destPath, $text, $utf8)
    }
  }
}

$name = Split-Path $Repo -Leaf
Write-Host "$name <- $(Split-Path $sourceRepo -Leaf)"
foreach ($pack in @($config.packs)) {
  $fromDir = Join-Path $sourceRepo $pack.from
  $toDir = Join-Path $Repo $pack.to
  if (-not (Test-Path -LiteralPath $fromDir)) { Write-Problem "Source pack '$($pack.from)' wasn't found."; continue }
  if (-not (Test-Path -LiteralPath $toDir)) { Write-Problem "Pack '$($pack.to)' wasn't found in $name."; continue }
  Sync-Files $pack $fromDir $toDir
  Sync-JsonKeys $pack $fromDir $toDir
  Sync-LangKeys $pack $fromDir $toDir
}

if ($script:Problems) {
  Write-Host "$($script:Problems) problem(s) in sync.json or the source add-on." -ForegroundColor Red
  exit 1
}
if (-not $script:Differences) { Write-Host 'Everything is in sync.' -ForegroundColor Green; exit 0 }
if ($Check) {
  Write-Host "$($script:Differences) difference(s). Run sync.ps1 without -Check to copy them across." -ForegroundColor Yellow
  exit 1
}
Write-Host "Synced $($script:Differences) change(s). Review them with git diff, then commit." -ForegroundColor Green
