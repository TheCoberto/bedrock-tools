<#
.SYNOPSIS
  Releases an add-on from start to finish: bump, PR, merge, GitHub release,
  download the build into builds\, and install it into Minecraft.

.DESCRIPTION
  1. Checks the repo is on its default branch with nothing uncommitted and
     nothing unpushed, and pulls the latest from GitHub.
  2. Bumps the version on a release-<version> branch (bump.ps1) and adds the
     notes to the add-on's changelog (changelog.txt/.md, in its own style; an
     "Unreleased" heading is renamed to the version instead) and to
     listing\curseforge.md (changelog and File section). Commits, pushes
     and opens a PR. Skipped with -NoBump.
  3. Waits for the PR's checks, then merges it with a merge commit.
  4. Creates the GitHub release v<version>, titled "<Add-on name> <version>".
  5. Waits for the release build, then downloads its .mcaddon into builds\,
     replacing older versions of the same add-on.
  6. Runs install.ps1, unless -NoInstall or Minecraft is running.

    # From bedrock-tools. -Repo takes a folder name or path.
    .\release.ps1 -Repo fat-man -Part minor -Notes "- Adds launcher sounds."
    .\release.ps1 -Repo fat-man -Part minor -Notes "..." -WhatIf   # show the plan only

  Commit the change being released first; this only commits the version bump.

.PARAMETER Repo
  The add-on repo: a folder name next to bedrock-tools (like fat-man) or a path.

.PARAMETER Part
  Which part of the version to increase: major, minor or patch (default).

.PARAMETER Version
  Set an exact version instead, like 2.0.0.

.PARAMETER NoBump
  Release the version that's already in the manifests.

.PARAMETER Notes
  The release notes (Markdown). Required.

.PARAMETER Title
  The release title. Defaults to "<Add-on name> <version>".

.PARAMETER CommitTrailer
  Lines added to the end of the bump commit message, like a Co-Authored-By line.

.PARAMETER PrFooter
  Text added to the end of the PR description.

.PARAMETER NoInstall
  Don't run install.ps1 at the end.

.PARAMETER WhatIf
  Show what would happen without changing anything.
#>
param(
  [Parameter(Mandatory = $true)][string]$Repo,
  [ValidateSet('major', 'minor', 'patch')][string]$Part = 'patch',
  [string]$Version,
  [switch]$NoBump,
  [string]$Notes,
  [string]$Title,
  [string]$CommitTrailer,
  [string]$PrFooter,
  [switch]$NoInstall,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$workspace = Split-Path $PSScriptRoot -Parent
$builds = Join-Path $workspace 'builds'
if (-not (Test-Path -LiteralPath $Repo)) { $Repo = Join-Path $workspace $Repo }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$repoName = Split-Path $Repo -Leaf
if (-not $Notes -and -not $WhatIf) { throw 'Pass -Notes with the release notes.' }

function Step([string]$text) { Write-Host "-- $text" -ForegroundColor Cyan }

# Runs git or gh in the repo and stops on failure. Returns stdout.
function Run {
  $exe, $rest = $args
  Push-Location -LiteralPath $Repo
  try {
    $out = & $exe @rest
    if ($LASTEXITCODE) { throw "$exe $($rest -join ' ') failed (exit code $LASTEXITCODE)." }
    return $out
  } finally { Pop-Location }
}

# Runs a command with all output hidden and returns its exit code. Windows
# PowerShell turns redirected error output into a failure, so relax that here.
function Get-ExitCode {
  $exe, $rest = $args
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  Push-Location -LiteralPath $Repo
  try { & $exe @rest *> $null; return $LASTEXITCODE }
  finally { Pop-Location; $ErrorActionPreference = $saved }
}

# The PR's checks as gh "buckets" (pass, fail, pending, skipping, cancel).
# Empty while GitHub hasn't reported any checks yet.
function Get-CheckBuckets([string]$branch) {
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  Push-Location -LiteralPath $Repo
  try { return @(& gh pr checks $branch --json bucket -q '.[].bucket' 2> $null | Where-Object { $_ }) }
  finally { Pop-Location; $ErrorActionPreference = $saved }
}

# Waits until the PR's checks have all finished, and throws if any failed.
# GitHub can take a few minutes to start checks, and `gh pr checks --watch`
# fails straight away when there are none yet, so wait for them to appear first.
# More checks can appear while watching (one run per workflow trigger), so look
# again after each watch until nothing is pending.
function Wait-Checks([string]$branch, [string]$pr) {
  $deadline = (Get-Date).AddMinutes(5)
  while (-not (Get-CheckBuckets $branch).Count) {
    if ((Get-Date) -gt $deadline) { throw "No checks started on $pr within 5 minutes. Check GitHub Actions, merge the PR, then rerun with -NoBump." }
    Start-Sleep -Seconds 5
  }
  Start-Sleep -Seconds 10 # let the other workflow runs register
  while ($true) {
    Get-ExitCode gh pr checks $branch --watch | Out-Null
    $buckets = Get-CheckBuckets $branch
    if ($buckets -contains 'fail' -or $buckets -contains 'cancel') { throw "Checks failed on $pr. Fix them, merge the PR, then rerun with -NoBump." }
    if ($buckets -notcontains 'pending') { return }
  }
}

# Text with quotes and newlines goes through a file: Windows PowerShell
# mangles quotes in arguments to other programs.
function New-TextFile([string]$text) {
  $f = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($f, $text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  return $f
}

# The add-on's changelog (changelog.txt or .md anywhere in the repo), or $null.
function Find-Changelog {
  Get-ChildItem -LiteralPath $Repo -Recurse -File |
    Where-Object { $_.Name -match '^changelog\.(txt|md)$' -and $_.FullName -notmatch '\\\.git\\' } |
    Sort-Object { $_.FullName.Length } | Select-Object -First 1
}

# Adds a "<version>" entry with the notes to the top of the changelog, in the
# file's own style ("1.2.0" lines or "## 1.2.0" headings). An "Unreleased"
# heading is renamed to the version instead, keeping its entries. Returns what
# it did, or $null when there's nothing to do.
function Update-Changelog([string]$file, [string]$ver, [string]$notes) {
  $bytes = [IO.File]::ReadAllBytes($file)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes).TrimStart([char]0xFEFF)
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = [Collections.Generic.List[string]]($text -split "\r?\n")
  $markdown = [bool]($lines | Where-Object { $_ -match '^##\s+\S' })
  $prefix = if ($markdown) { '## ' } else { '' }

  if ($lines | Where-Object { $_ -match "^(##\s+)?v?$([regex]::Escape($ver))\s*$" }) { return $null }

  $unreleased = -1
  $firstVersion = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($unreleased -lt 0 -and $lines[$i] -match '^(##\s+)?unreleased\s*$') { $unreleased = $i }
    if ($firstVersion -lt 0 -and $lines[$i] -match '^(##\s+)?v?\d+\.\d+\.\d+') { $firstVersion = $i }
  }

  if ($unreleased -ge 0 -and ($firstVersion -lt 0 -or $unreleased -lt $firstVersion)) {
    $lines[$unreleased] = "$prefix$ver"
    $did = "renamed Unreleased to $ver"
  } else {
    $entry = @("$prefix$ver")
    if ($markdown) { $entry += '' }
    $entry += @($notes.Trim() -split "\r?\n") + ''
    $at = $firstVersion
    if ($at -lt 0) {
      # No versions yet: after a "# Changelog" title if there is one.
      $at = 0
      if ($lines.Count -and $lines[0] -match '^#\s') { $at = 1; while ($at -lt $lines.Count -and -not $lines[$at].Trim()) { $at++ } }
    }
    $lines.InsertRange($at, [string[]]$entry)
    $did = "added $ver entry"
  }
  [IO.File]::WriteAllText($file, ($lines -join $nl), (New-Object Text.UTF8Encoding($bom)))
  return $did
}

# Brings listing\curseforge.md up to the new version: adds a changelog entry at
# the top of its Changelog section and points the File section at the new
# build, with the notes as its changelog. Returns what it did, or $null.
function Update-Listing([string]$file, [string]$ver, [string]$notes) {
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $text = [IO.File]::ReadAllText($file)
  $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $body = ($notes.Trim() -split "\r?\n") -join $nl
  $did = @()

  if ($text -notmatch "(?m)^\*\*$([regex]::Escape($ver))\*\*\s*$") {
    $text = [regex]::Replace($text, '(?m)^(### Changelog\r?\n\r?\n)', { param($m) $m.Groups[1].Value + "**$ver**$nl$body$nl$nl" }, 1)
    $did += 'changelog'
  }
  # File section: build name, display name and the file's changelog (everything after "- **Changelog:**").
  $file2 = [regex]::Replace($text, '(?m)^(- \*\*File:\*\* `builds\\.+?-)\d+\.\d+\.\d+(\.mcaddon`)', "`${1}$ver`${2}")
  $file2 = [regex]::Replace($file2, '(?m)^(- \*\*Display name:\*\* .+ )\d+\.\d+\.\d+\s*$', "`${1}$ver")
  $file2 = [regex]::Replace($file2, '(?s)(- \*\*Changelog:\*\*\r?\n\r?\n).*$', { param($m) $m.Groups[1].Value + $body + $nl })
  if ($file2 -ne $text) { $text = $file2; $did += 'file section' }

  if (-not $did) { return $null }
  [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
  return "updated $($did -join ' and ')"
}

function Get-AddonInfo {
  $main = Get-MainPack @(Get-Packs $Repo)
  $name = Get-CleanName (Get-PackName $main)
  [pscustomobject]@{ Version = Get-VersionString $main.Manifest.header.version; CleanName = $name; Display = $name -replace '-', ' ' }
}

# 1. Clean, on the default branch, up to date.
Step "Checking $repoName"
Run git fetch --quiet --prune --tags | Out-Null
$default = (Run git rev-parse --abbrev-ref origin/HEAD) -replace '^origin/', ''
$branch = Run git branch --show-current
if ($branch -ne $default) { throw "$repoName is on branch '$branch'. Switch to '$default' first." }
if (@(Run git status --porcelain).Count) { throw "$repoName has uncommitted changes. Commit them (on a branch, through a PR) first." }
if (@(Run git log "origin/$default..HEAD" --oneline).Count) { throw "$repoName has commits on $default that aren't on GitHub. Push them through a PR first." }
Run git pull --quiet --ff-only | Out-Null
$slug = (Run gh repo view --json nameWithOwner -q .nameWithOwner)

$info = Get-AddonInfo
$current = $info.Version
if ($NoBump) { $new = $current }
elseif ($Version) { $new = $Version }
else {
  $v = @($current.Split('.') | ForEach-Object { [int]$_ })
  $new = switch ($Part) { 'major' { "$($v[0] + 1).0.0" } 'minor' { "$($v[0]).$($v[1] + 1).0" } 'patch' { "$($v[0]).$($v[1]).$($v[2] + 1)" } }
}
$tag = "v$new"
if (-not $Title) { $Title = "$($info.Display) $new" }
if ((Get-ExitCode gh release view $tag -R $slug) -eq 0) { throw "$slug already has a release $tag." }

Write-Host "  $repoName ($slug): $current -> $new, release '$Title' on $default"
if ($WhatIf) {
  if (-not $NoBump) {
    $changelog = Find-Changelog
    $cl = if ($changelog) { "add the notes to $($changelog.FullName.Substring($Repo.Length + 1)) (or rename its Unreleased heading)" } else { 'no changelog file to update' }
    if (Test-Path -LiteralPath (Join-Path $Repo 'listing\curseforge.md')) { $cl += ', update listing\curseforge.md' }
    Write-Host "  Would bump to $new on branch release-$new, $cl, open a PR, wait for checks and merge it."
  }
  Write-Host "  Would create release $tag, wait for its build, download $($info.CleanName)-$new.mcaddon into builds\ (removing older versions) and $(if ($NoInstall) { 'not install it' } else { 'run install.ps1' })."
  exit 0
}

# 2-3. Bump through a PR.
if (-not $NoBump) {
  Step "Bumping to $new"
  $bumpBranch = "release-$new"
  Run git checkout --quiet -b $bumpBranch | Out-Null
  & (Join-Path $PSScriptRoot 'bump.ps1') -Repo $Repo -Version $new | Out-Null
  $changelog = Find-Changelog
  if ($changelog) {
    $did = Update-Changelog $changelog.FullName $new $Notes
    $rel = $changelog.FullName.Substring($Repo.Length + 1)
    Write-Host "  $rel`: $(if ($did) { $did } else { "already has $new" })"
  } else { Write-Host '  No changelog file; skipped.' }
  $listing = Join-Path $Repo 'listing\curseforge.md'
  if (Test-Path -LiteralPath $listing) {
    $did = Update-Listing $listing $new $Notes
    Write-Host "  listing\curseforge.md: $(if ($did) { $did } else { "already has $new" })"
  }
  $message = "Bump to $new"
  if ($CommitTrailer) { $message += "`n`n$CommitTrailer" }
  $msgFile = New-TextFile $message
  Run git commit --quiet -a -F $msgFile | Out-Null
  if (Get-ExitCode git push --quiet -u origin $bumpBranch) { throw "Couldn't push $bumpBranch." }

  $body = "Version bump for the $new release."
  if ($PrFooter) { $body += "`n`n$PrFooter" }
  $bodyFile = New-TextFile $body
  $pr = Run gh pr create --base $default --head $bumpBranch --title "Bump to $new" --body-file $bodyFile
  Write-Host "  $pr"

  Step 'Waiting for checks'
  Wait-Checks $bumpBranch $pr

  Step 'Merging'
  Run gh pr merge $bumpBranch --merge --delete-branch | Out-Null
  Run git checkout --quiet $default | Out-Null
  Run git pull --quiet --ff-only | Out-Null
  Run git fetch --quiet --prune | Out-Null
  if ((Get-AddonInfo).Version -ne $new) { throw "After merging, the manifest version isn't $new." }
}

# 4. Release.
Step "Creating release $tag"
$notesFile = New-TextFile $Notes
$url = Run gh release create $tag -R $slug --target $default --title $Title --notes-file $notesFile
Write-Host "  $url"

# 5. Wait for the release build and download it.
Step 'Waiting for the release build'
$runId = $null
for ($i = 0; $i -lt 30 -and -not $runId; $i++) {
  $runId = Run gh run list -R $slug --event release --branch $tag --limit 1 --json databaseId -q '.[0].databaseId'
  if (-not $runId) { Start-Sleep -Seconds 4 }
}
if (-not $runId) { throw "The release build didn't start. Check the Actions tab of $slug." }
if (Get-ExitCode gh run watch $runId -R $slug --exit-status) { throw "The release build failed: https://github.com/$slug/actions/runs/$runId" }

$temp = Join-Path ([IO.Path]::GetTempPath()) ("release-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  Run gh release download $tag -R $slug -D $temp -p '*.mcaddon' | Out-Null
  $asset = Get-ChildItem -LiteralPath $temp -Filter '*.mcaddon' | Select-Object -First 1
  if (-not $asset) { throw "Release $tag has no .mcaddon attached." }
  # GitHub renames some characters (Coberto's -> Coberto.s), so use the local name.
  $buildName = "$($info.CleanName)-$new.mcaddon"
  New-Item -ItemType Directory -Path $builds -Force | Out-Null
  Get-ChildItem -LiteralPath $builds -Filter "$($info.CleanName)-*.mcaddon" |
    Where-Object { $_.Name -match "^$([regex]::Escape($info.CleanName))-\d+\.\d+\.\d+\.mcaddon$" -and $_.Name -ne $buildName } |
    ForEach-Object { Write-Host "  removed old build $($_.Name)"; Remove-Item -LiteralPath $_.FullName }
  Copy-Item -LiteralPath $asset.FullName -Destination (Join-Path $builds $buildName) -Force
  Write-Host "  builds\$buildName"
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

# 6. Install.
if ($NoInstall) { Write-Host 'Done. Not installed (-NoInstall).' -ForegroundColor Green; exit 0 }
if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Minecraft.Windows*' }) {
  Write-Host "Done, but Minecraft is running. Close it and run install.ps1." -ForegroundColor Yellow
  exit 0
}
Step 'Installing into Minecraft'
& (Join-Path $PSScriptRoot 'install.ps1')
exit 0
