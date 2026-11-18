<#
.SYNOPSIS
  One table showing what still needs doing across every add-on.

.DESCRIPTION
  For each add-on repo (and bedrock-tools), shows:
    - Local:     uncommitted files, commits not pushed, or behind GitHub
    - PRs:       open pull requests
    - Release:   the latest GitHub release
    - To do:     pack changes since that release, or a version that isn't released yet
    - Build:     whether builds\ has the current version's .mcaddon
  Then whether Minecraft has everything in builds\ installed.

  Promo images, READMEs and workflow files don't count as changes: builds leave
  them out, so they don't need a release.

    powershell -ExecutionPolicy Bypass -File status.ps1            # from bedrock-tools
    powershell -ExecutionPolicy Bypass -File status.ps1 -NoFetch   # skip git fetch (faster)

  Exits with code 1 when something needs doing.

.PARAMETER Workspace
  The folder that holds the add-on repos. Defaults to the folder bedrock-tools is in.

.PARAMETER NoFetch
  Don't fetch from GitHub first. Faster, but Local and To do may be out of date.
#>
param(
  [string]$Workspace = (Split-Path $PSScriptRoot -Parent),
  [switch]$NoFetch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
$buildsDir = Join-Path $Workspace 'builds'
$repos = @(Get-AddonRepos $Workspace) + @($PSScriptRoot) | Where-Object { Test-Path (Join-Path $_ '.git') }

# Windows PowerShell turns redirected error output into a failure, so relax that here.
function Invoke-Git([string]$Repo) {
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { return (& git -C $Repo @args 2>$null) } finally { $ErrorActionPreference = $saved }
}

# Local state of every repo.
$rows = foreach ($repo in $repos) {
  if (-not $NoFetch) { Invoke-Git $repo fetch --quiet --prune --tags | Out-Null }
  $url = (Invoke-Git $repo remote get-url origin) | Select-Object -First 1
  $slug = if ($url -match 'github\.com[:/](.+?)(\.git)?$') { $matches[1] } else { $null }
  $default = ((Invoke-Git $repo rev-parse --abbrev-ref origin/HEAD) -replace '^origin/', '')
  if (-not $default) { $default = 'main' }
  $branch = Invoke-Git $repo branch --show-current
  $dirty = @(Invoke-Git $repo status --porcelain).Count
  $counts = (Invoke-Git $repo rev-list --left-right --count "HEAD...origin/$default") -split '\s+'
  $unpushed = @(Invoke-Git $repo log --branches --not --remotes --oneline).Count

  $local = @()
  if ($branch -ne $default) { $local += "on $branch" }
  if ($dirty) { $local += "$dirty uncommitted" }
  if ($unpushed) { $local += "$unpushed unpushed" }
  if ($counts.Count -eq 2 -and [int]$counts[1] -gt 0) { $local += "$($counts[1]) behind" }

  $isTools = ($repo -eq $PSScriptRoot)
  $packs = @(if (-not $isTools) { Get-Packs $repo | Where-Object { $_.Manifest } })
  $version = $null; $buildName = $null; $cleanName = $null
  if ($packs.Count) {
    $main = Get-MainPack $packs
    $version = Get-VersionString $main.Manifest.header.version
    $cleanName = Get-CleanName (Get-PackName $main)
    $buildName = "$cleanName-$version.mcaddon"
  }

  [pscustomobject]@{
    Name = Split-Path $repo -Leaf; Repo = $repo; Slug = $slug; Default = $default; IsTools = $isTools
    Local = if ($local) { $local -join ', ' } else { 'ok' }
    Packs = $packs; Version = $version; BuildName = $buildName; CleanName = $cleanName
    PRs = '?'; Release = '?'; Todo = ''; Build = ''
  }
}

# Open PRs and latest release for every repo, in one GitHub query.
$withSlug = @($rows | Where-Object Slug)
$parts = for ($i = 0; $i -lt $withSlug.Count; $i++) {
  $owner, $name = $withSlug[$i].Slug -split '/', 2
  "r$i`: repository(owner: `"$owner`", name: `"$name`") { pullRequests(states: OPEN) { totalCount } latestRelease { tagName } releases(first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName isPrerelease } } }"
}
$github = $null
# The query goes through a file: Windows PowerShell mangles quotes in arguments to other programs.
$queryFile = [IO.Path]::GetTempFileName()
try {
  [IO.File]::WriteAllText($queryFile, "{ $($parts -join ' ') }")
  $ErrorActionPreference = 'Continue'
  $json = & gh api graphql -F "query=@$queryFile" 2>$null
  if ($LASTEXITCODE -eq 0) { $github = ($json -join "`n" | ConvertFrom-Json).data }
} catch {} finally { $ErrorActionPreference = 'Stop'; Remove-Item -LiteralPath $queryFile -ErrorAction SilentlyContinue }
if (-not $github) { Write-Host 'Could not reach GitHub; PRs and releases are unknown.' -ForegroundColor Yellow }

for ($i = 0; $i -lt $withSlug.Count; $i++) {
  $row = $withSlug[$i]
  if (-not $github) { continue }
  $r = $github."r$i"
  if (-not $r) { continue }
  $row.PRs = [string]$r.pullRequests.totalCount
  $tag = if ($r.latestRelease) { $r.latestRelease.tagName } elseif ($r.releases.nodes) { $r.releases.nodes[0].tagName + ' (pre)' } else { $null }
  $row.Release = if ($tag) { $tag } elseif ($row.IsTools) { '-' } else { 'none' }
}

# What still needs releasing, and whether builds\ has the current version.
foreach ($row in $rows | Where-Object { -not $_.IsTools }) {
  $tag = ($row.Release -replace ' \(pre\)$', '')
  $todo = @()
  if ($tag -and $tag -notin @('?', 'none')) {
    if ($row.Version -and ($tag -replace '^v', '') -ne $row.Version) { $todo += "$($row.Version) not released" }
    $packDirs = @($row.Packs | ForEach-Object { (Get-RelativePath $row.Repo $_.Dir).Replace('\', '/') + '/' })
    $changed = @(Invoke-Git $row.Repo diff --name-only $tag "origin/$($row.Default)" | Where-Object {
      $f = $_; @($packDirs | Where-Object { $_ -eq '/' -or $f.StartsWith($_) }).Count -gt 0
    } | Where-Object { $_ -notmatch '(^|/)(promo/|README|.*\.md$)' })
    if ($changed.Count) { $todo += "$($changed.Count) file(s) changed since $tag" }
  } elseif ($tag -eq 'none') { $todo += 'never released' }
  $row.Todo = if ($todo) { $todo -join ', ' } else { '-' }

  if ($row.BuildName) {
    $have = Test-Path -LiteralPath (Join-Path $buildsDir $row.BuildName)
    $old = @(Get-ChildItem -LiteralPath $buildsDir -Filter "$($row.CleanName)-*.mcaddon" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne $row.BuildName -and $_.Name -match "^$([regex]::Escape($row.CleanName))-\d+\.\d+\.\d+\.mcaddon$" })
    $row.Build = if (-not $have) { "missing $($row.BuildName)" } elseif ($old) { "old: $($old.Name -join ', ')" } else { 'ok' }
  }
}

$rows | Sort-Object { $_.IsTools }, Name |
  Format-Table @{ n = 'Add-on'; e = { $_.Name } }, Local, PRs, Release, @{ n = 'To do'; e = { $_.Todo } }, Build -AutoSize |
  Out-String -Width 200 | Write-Host

# Installed in Minecraft?
$install = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -WhatIf 2>&1 |
  ForEach-Object { "$_" } | Where-Object { $_ -match 'Would change|update|install |remove|ERROR' }
$installLine = ($install | Where-Object { $_ -match 'Would change' }) -replace '\s*\(nothing was changed\)', ''
$installOk = $installLine -match '^Would change: 0 updated, 0 installed, 0 removed'
if ($installOk) { Write-Host 'Minecraft: everything in builds is installed.' -ForegroundColor Green }
else { Write-Host 'Minecraft: not up to date. Run install.ps1:' -ForegroundColor Yellow; $install | ForEach-Object { Write-Host "  $($_.Trim())" } }

$needs = @($rows | Where-Object {
  $_.Local -ne 'ok' -or ($_.PRs -notin @('0', '?')) -or ($_.Todo -notin @('', '-')) -or ($_.Build -notin @('', 'ok'))
})
if ($needs.Count -or -not $installOk) {
  Write-Host "Needs attention: $(@($needs.Name) -join ', ')" -ForegroundColor Yellow
  exit 1
}
Write-Host 'Everything is committed, pushed, released, built and installed.' -ForegroundColor Green
exit 0
