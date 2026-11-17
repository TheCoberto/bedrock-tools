# Shared helpers for the bedrock-tools scripts. Load with:  . "$PSScriptRoot/lib.ps1"
# Works in Windows PowerShell 5.1 (local) and PowerShell 7 on Linux (GitHub Actions).

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Folders and files that are never part of a pack.
$script:SkipDirs  = '[\\/](\.git|\.vs|\.vscode|\.github|node_modules|dist|builds|promo)([\\/]|$)'
$script:SkipFiles = '^(\.gitignore|\.gitattributes|.*\.md|.*\.mcaddon|.*\.mcpack)$'
# Text files Minecraft reads, which must be UTF-8.
$script:TextExtensions = @('.json', '.lang', '.mcfunction', '.js', '.txt', '.material')

$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

# --- JSON ---------------------------------------------------------------------

# Minecraft allows // and /* */ comments in JSON; PowerShell doesn't. Strip them,
# leaving anything inside strings (like "https://...") alone.
function Remove-JsonComments([string]$Text) {
  if ($Text.IndexOf('//') -lt 0 -and $Text.IndexOf('/*') -lt 0) { return $Text }
  $sb = New-Object System.Text.StringBuilder $Text.Length
  $i = 0; $n = $Text.Length; $inString = $false
  while ($i -lt $n) {
    $c = $Text[$i]
    if ($inString) {
      [void]$sb.Append($c)
      if ($c -eq [char]'\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
      if ($c -eq [char]'"') { $inString = $false }
      $i++; continue
    }
    if ($c -eq [char]'"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
    if ($c -eq [char]'/' -and $i + 1 -lt $n) {
      $next = $Text[$i + 1]
      if ($next -eq [char]'/') { while ($i -lt $n -and $Text[$i] -ne [char]"`n") { $i++ }; continue }
      if ($next -eq [char]'*') {
        $end = $Text.IndexOf('*/', $i + 2)
        $i = if ($end -lt 0) { $n } else { $end + 2 }
        continue
      }
    }
    [void]$sb.Append($c); $i++
  }
  return $sb.ToString()
}

function Read-JsonFile([string]$Path) {
  $text = Remove-JsonComments ([IO.File]::ReadAllText($Path))
  return $text | ConvertFrom-Json
}

# Only checks that a file is valid JSON. ConvertFrom-Json in Windows PowerShell
# wrongly rejects valid JSON with keys that differ only in case ("I" and "i" in a
# crafting recipe) or empty keys, so use a dictionary-based parser instead.
function Test-JsonFile([string]$Path) {
  $text = Remove-JsonComments ([IO.File]::ReadAllText($Path))
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    [void]($text | ConvertFrom-Json -AsHashtable -Depth 1024)
    return
  }
  if (-not $script:JsonSerializer) {
    Add-Type -AssemblyName System.Web.Extensions
    $script:JsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:JsonSerializer.MaxJsonLength = [int]::MaxValue
    $script:JsonSerializer.RecursionLimit = 1000
  }
  try { [void]$script:JsonSerializer.DeserializeObject($text) }
  catch {
    # The parser reports a character position and repeats the whole file; turn that into a line number.
    $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    $m = [regex]::Match($msg, '^(.*?)\s*\((\d+)\)')
    if ($m.Success) {
      $pos = [Math]::Min([int]$m.Groups[2].Value, $text.Length)
      $line = ($text.Substring(0, $pos) -split "`n").Count
      throw "$($m.Groups[1].Value) (around line $line)"
    }
    throw (($msg -split "`n")[0])
  }
}

# --- Packs ----------------------------------------------------------------------

function Get-RelativePath([string]$Root, [string]$Path) {
  return $Path.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/')
}

# Every pack (folder with a manifest.json) in a repo.
function Get-Packs([string]$Repo) {
  $Repo = (Resolve-Path -LiteralPath $Repo).Path
  @(Get-ChildItem -LiteralPath $Repo -Recurse -Filter "manifest.json" -File -ErrorAction SilentlyContinue |
    Where-Object { ('/' + (Get-RelativePath $Repo $_.FullName)) -notmatch $script:SkipDirs } |
    ForEach-Object {
      $manifest = $null; $parseError = $null
      try { $manifest = Read-JsonFile $_.FullName } catch { $parseError = $_.Exception.Message }
      [pscustomobject]@{ Dir = $_.DirectoryName; Path = $_.FullName; Manifest = $manifest; Error = $parseError }
    })
}

# Files that belong in a pack (skips .git, .vs, README, old builds...).
function Get-PackFiles([string]$PackDir) {
  @(Get-ChildItem -LiteralPath $PackDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { ('/' + (Get-RelativePath $PackDir $_.FullName)) -notmatch $script:SkipDirs -and $_.Name -notmatch $script:SkipFiles })
}

function Get-ModuleTypes($manifest) { @($manifest.modules | ForEach-Object { $_.type }) }

function Test-IsBehaviorPack($manifest) {
  $types = Get-ModuleTypes $manifest
  return ($types -contains 'data' -or $types -contains 'script')
}

function Get-PackKind($manifest) {
  if ((Get-ModuleTypes $manifest) -contains 'resources') { return 'RP' }
  if (Test-IsBehaviorPack $manifest) { return 'BP' }
  return 'pack'
}

# The behavior pack names and versions the add-on.
function Get-MainPack($packs) {
  $valid = @($packs | Where-Object { $_.Manifest })
  $bp = $valid | Where-Object { Test-IsBehaviorPack $_.Manifest } | Select-Object -First 1
  if ($bp) { return $bp }
  return $valid | Select-Object -First 1
}

function Get-VersionString($versionArray) { return (@($versionArray) -join '.') }

# A manifest can name the pack with a language key such as "pack.name" and put
# the real name in texts/en_US.lang. Look it up when that's the case.
function Get-PackName($pack) {
  $name = [string]$pack.Manifest.header.name
  if ($name -notmatch '^[\w.]+$' -or $name -notmatch '\.') { return $name }
  $lang = Join-Path (Join-Path $pack.Dir 'texts') 'en_US.lang'
  if (Test-Path -LiteralPath $lang) {
    $line = Get-Content -LiteralPath $lang -Encoding UTF8 | Where-Object { $_ -like "$name=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($name.Length + 1).Trim() }
  }
  return $name
}

# Minecraft's color-code character. Written as a code so these scripts stay plain
# ASCII: Windows PowerShell misreads non-ASCII characters in .ps1 files saved
# without a byte-order mark.
$script:ColorCode = [string][char]0x00A7

# "Skeleton Variants <color codes>[1.0.1]" -> "Skeleton-Variants", for file names.
function Get-CleanName([string]$name) {
  $name = $name -replace "$($script:ColorCode).", ''                    # color/format codes
  $name = $name -replace '\[[^\]]*\]', ''                               # tags like [1.0.2]
  $name = $name -replace '\([^)]*(\d|Behaviou?r|Resource)[^)]*\)', ''   # (v1.8.30), (Behavior)
  $name = $name -replace '\bv?\d+(\.\d+){1,3}\b', ''                    # versions like v1.1.2
  $name = $name -replace '[\s\-:]*\b(Behaviou?r|Resource)s?(\s+Pack)?\s*$', ''  # "- Behavior Pack"
  $name = $name -replace '[\s\-:]*\b(BP|RP)\s*$', ''                    # "- BP"
  $name = ($name.Trim(' ', '-', ':') -replace '[\\/:*?"<>|]', '') -replace '\s+', '-'
  return $name
}

# Every folder in the workspace that contains at least one pack.
function Get-AddonRepos([string]$Workspace) {
  @(Get-ChildItem -LiteralPath $Workspace -Directory |
    Where-Object { $_.Name -notin @('bedrock-tools', 'builds') -and $_.Name -notmatch '^\.' } |
    Where-Object { @(Get-Packs $_.FullName).Count -gt 0 } |
    ForEach-Object { $_.FullName })
}

# --- Checks ---------------------------------------------------------------------

function New-Issue([string]$Level, [string]$Where, [string]$Message) {
  [pscustomobject]@{ Level = $Level; Where = $Where; Message = $Message }
}

function Test-Guid([string]$value) {
  $g = [guid]::Empty
  return [guid]::TryParse($value, [ref]$g)
}

function Test-VersionArray($value) {
  $arr = @($value)
  if ($arr.Count -ne 3) { return $false }
  foreach ($x in $arr) { if ($x -isnot [int] -and $x -isnot [long]) { return $false } }
  return $true
}

# Problems inside one add-on repo. Returns a list of issues (Level = Error or Warning).
function Get-AddonIssues([string]$Repo) {
  $Repo = (Resolve-Path -LiteralPath $Repo).Path
  $issues = New-Object System.Collections.ArrayList
  $packs = Get-Packs $Repo
  if ($packs.Count -eq 0) { [void]$issues.Add((New-Issue Error '' 'No packs found (no manifest.json).')); return $issues }

  $declared = @{}   # uuid -> list of "where (kind)"
  foreach ($pack in $packs) {
    $where = Get-RelativePath $Repo $pack.Path
    if ($pack.Error) { [void]$issues.Add((New-Issue Error $where "manifest.json doesn't parse: $($pack.Error)")); continue }
    $m = $pack.Manifest

    # UUIDs and versions
    $ids = @(@{ Id = $m.header.uuid; Kind = 'header' }) + @($m.modules | ForEach-Object { @{ Id = $_.uuid; Kind = "$($_.type) module" } })
    foreach ($id in $ids) {
      if (-not (Test-Guid $id.Id)) { [void]$issues.Add((New-Issue Error $where "The $($id.Kind) UUID '$($id.Id)' isn't a valid UUID.")); continue }
      $key = ([string]$id.Id).ToLower()
      if (-not $declared.ContainsKey($key)) { $declared[$key] = New-Object System.Collections.ArrayList }
      [void]$declared[$key].Add("$where ($($id.Kind))")
    }
    if (-not (Test-VersionArray $m.header.version)) {
      [void]$issues.Add((New-Issue Error $where 'header.version must be three numbers, like [ 1, 0, 0 ].'))
    } else {
      $version = Get-VersionString $m.header.version
      $nameVersion = [regex]::Match([string]$m.header.name, '\[v?(\d+\.\d+\.\d+)\]|\bv(\d+\.\d+\.\d+)\b')
      if ($nameVersion.Success) {
        $shown = if ($nameVersion.Groups[1].Success) { $nameVersion.Groups[1].Value } else { $nameVersion.Groups[2].Value }
        if ($shown -ne $version) { [void]$issues.Add((New-Issue Warning $where "The pack name says $shown but header.version is $version.")) }
      }
    }

    # Scripts
    # Only scripts/ holds code Minecraft runs. Other .js files, like the bridge.
    # editor's components/ templates, don't count.
    $scriptModules = @($m.modules | Where-Object { $_.type -eq 'script' })
    $scriptsDir = Join-Path $pack.Dir 'scripts'
    $hasScripts = (Test-Path -LiteralPath $scriptsDir) -and
      @(Get-ChildItem -LiteralPath $scriptsDir -Recurse -Filter '*.js' -File -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasScripts -and $scriptModules.Count -eq 0) {
      [void]$issues.Add((New-Issue Error $where 'The pack has .js files but no script module, so the scripts never run.'))
    }
    foreach ($sm in $scriptModules) {
      if (-not $sm.entry) { [void]$issues.Add((New-Issue Error $where 'A script module has no "entry" file.')); continue }
      $entry = Join-Path $pack.Dir ($sm.entry -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $entry)) { [void]$issues.Add((New-Issue Error $where "The script entry '$($sm.entry)' doesn't exist.")) }
    }
    $apiDeps = @($m.dependencies | Where-Object { $_.module_name -like '@minecraft/*' })
    if ($apiDeps.Count -gt 0 -and $scriptModules.Count -eq 0) {
      [void]$issues.Add((New-Issue Warning $where 'Depends on the Script API but has no script module. The dependency can be removed.'))
    }
  }

  # Dependencies on other packs in this repo must match their version.
  $byHeader = @{}
  foreach ($p in $packs | Where-Object { $_.Manifest }) { $byHeader[([string]$p.Manifest.header.uuid).ToLower()] = $p }
  foreach ($pack in $packs | Where-Object { $_.Manifest }) {
    $where = Get-RelativePath $Repo $pack.Path
    foreach ($dep in @($pack.Manifest.dependencies | Where-Object { $_.uuid })) {
      $target = $byHeader[([string]$dep.uuid).ToLower()]
      if (-not $target) { [void]$issues.Add((New-Issue Warning $where "Depends on pack $($dep.uuid), which isn't in this repo.")); continue }
      $want = Get-VersionString $dep.version; $have = Get-VersionString $target.Manifest.header.version
      if ($want -ne $have) {
        [void]$issues.Add((New-Issue Error $where "Depends on $(Split-Path $target.Dir -Leaf) version $want, but that pack is version $have."))
      }
    }
  }

  # Every pack and module needs its own UUID.
  foreach ($key in $declared.Keys) {
    if ($declared[$key].Count -gt 1) {
      [void]$issues.Add((New-Issue Error '' "UUID $key is used more than once: $($declared[$key] -join '; ')."))
    }
  }

  # Files: JSON must parse, text must be UTF-8.
  foreach ($pack in $packs) {
    foreach ($file in Get-PackFiles $pack.Dir) {
      $ext = $file.Extension.ToLower()
      if ($script:TextExtensions -notcontains $ext) { continue }
      $where = Get-RelativePath $Repo $file.FullName
      $bytes = [IO.File]::ReadAllBytes($file.FullName)
      try { [void]$script:StrictUtf8.GetString($bytes) }
      catch { [void]$issues.Add((New-Issue Error $where "Isn't saved as UTF-8, so color codes and other special characters will show up garbled. Re-save it as UTF-8.")); continue }
      if ($ext -eq '.json' -and $file.Name -ne 'manifest.json') {
        try { Test-JsonFile $file.FullName }
        catch { [void]$issues.Add((New-Issue Error $where "JSON doesn't parse: $(($_.Exception.Message -split "`n")[0])")) }
      }
    }
  }

  return $issues
}

# Problems between add-ons: two add-ons can't share a pack UUID. Shared module
# UUIDs are only a warning, since Minecraft tells packs apart by the header UUID.
function Get-CrossRepoIssues([string[]]$Repos) {
  $issues = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($repo in $Repos) {
    $repoName = Split-Path $repo -Leaf
    foreach ($pack in Get-Packs $repo | Where-Object { $_.Manifest }) {
      $entries = @(@{ Id = $pack.Manifest.header.uuid; Header = $true }) + @($pack.Manifest.modules | ForEach-Object { @{ Id = $_.uuid; Header = $false } })
      foreach ($e in $entries) {
        $key = ([string]$e.Id).ToLower()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = New-Object System.Collections.ArrayList }
        [void]$seen[$key].Add([pscustomobject]@{ Repo = $repoName; Header = $e.Header })
      }
    }
  }
  foreach ($key in $seen.Keys) {
    $repos = @($seen[$key] | ForEach-Object { $_.Repo } | Sort-Object -Unique)
    if ($repos.Count -lt 2) { continue }
    $isHeader = @($seen[$key] | Where-Object { $_.Header }).Count -gt 0
    $level = if ($isHeader) { 'Error' } else { 'Warning' }
    $what = if ($isHeader) { 'pack' } else { 'module' }
    [void]$issues.Add((New-Issue $level '' "The $what UUID $key is shared by: $($repos -join ', ')."))
  }
  return $issues
}

function Write-Issues($issues, [string]$Indent = '  ') {
  foreach ($i in $issues | Sort-Object Level) {
    $tag = if ($i.Level -eq 'Error') { 'ERROR' } else { 'warn ' }
    $color = if ($i.Level -eq 'Error') { 'Red' } else { 'Yellow' }
    $where = if ($i.Where) { "$($i.Where): " } else { '' }
    Write-Host "$Indent$tag $where$($i.Message)" -ForegroundColor $color
  }
}
