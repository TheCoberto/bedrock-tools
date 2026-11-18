<#
.SYNOPSIS
  Releases an add-on from start to finish: bump, PR, merge, GitHub release,
  download the build into builds\, and install it into Minecraft.

.DESCRIPTION
  1. Checks the repo is on its default branch with nothing uncommitted and
     nothing unpushed, and pulls the latest from GitHub.
  2. Bumps the version on a release-<version> branch (bump.ps1), commits,
     pushes and opens a PR. Skipped with -NoBump.
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

# Text with quotes and newlines goes through a file: Windows PowerShell
# mangles quotes in arguments to other programs.
function New-TextFile([string]$text) {
  $f = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($f, $text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  return $f
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
  if (-not $NoBump) { Write-Host "  Would bump to $new on branch release-$new, open a PR, wait for checks and merge it." }
  Write-Host "  Would create release $tag, wait for its build, download $($info.CleanName)-$new.mcaddon into builds\ (removing older versions) and $(if ($NoInstall) { 'not install it' } else { 'run install.ps1' })."
  exit 0
}

# 2-3. Bump through a PR.
if (-not $NoBump) {
  Step "Bumping to $new"
  $bumpBranch = "release-$new"
  Run git checkout --quiet -b $bumpBranch | Out-Null
  & (Join-Path $PSScriptRoot 'bump.ps1') -Repo $Repo -Version $new | Out-Null
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
  # gh exits 1 while no checks are reported yet; give them a minute to appear.
  for ($i = 0; $i -lt 15 -and (Get-ExitCode gh pr checks $bumpBranch) -eq 1; $i++) { Start-Sleep -Seconds 4 }
  if (Get-ExitCode gh pr checks $bumpBranch --watch) { throw "Checks failed on $pr. Fix them, merge the PR, then rerun with -NoBump." }

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
