# Bedrock add-on suite

TheCoberto's Minecraft Bedrock add-ons. Each add-on is its own GitHub repo next to this one in `..\`; `..\builds\` holds the built `.mcaddon` files. Scripts here run in Windows PowerShell 5.1: `powershell -NoProfile -ExecutionPolicy Bypass -File <script>`.

## Scripts (use these instead of doing the steps by hand)
- `status.ps1`: one table of what needs doing across every repo (uncommitted, unpushed, open PRs, unreleased changes, builds, installed). Start here.
- `release.ps1 -Repo <folder> -Part patch|minor|major -Notes "..."`: bump → PR → merge → GitHub release → download into builds → install. `-WhatIf` previews, `-NoBump` releases the current version. Writes the notes into the add-on's changelog.
- `install.ps1`: installs `builds\` into Minecraft. Needs Minecraft closed.
- `check.ps1`, `package.ps1`, `build-all.ps1`, `bump.ps1`, `sync.ps1`: see README.md.

## Conventions
- Never commit to the default branch. Branch, push, open a PR, wait for checks, merge with a merge commit (`gh pr merge --merge --delete-branch`). CleanupUtility's default branch is `master`; the rest use `main`.
- Changes to promo images, READMEs or workflows don't need a release. Pack changes do: bump the version (`release.ps1` does it).
- Release title: `<Add-on name> <version>` (like "Rocket Launcher 1.3.0"). Notes: short player-facing bullets, no PR lists.
- `builds\` holds only the latest release of each add-on, named like `Rocket-Launcher-1.3.0.mcaddon`.
- When an add-on is folded into or replaced by another, add its BP and RP header UUIDs to `retired.json` (after checking no world uses them), remove its build, and run `install.ps1`.
- Bow files are edited in skeleton-variants and copied to bow-variants with `sync.ps1`.
- Other Claude sessions may be working in these repos at the same time. Branch from an up-to-date default branch and check `git log` before assuming a commit is yours.
- Minecraft data: `%APPDATA%\Minecraft Bedrock\Users\Shared\games\com.mojang` (packs), `...\Users\<id>\games\com.mojang\minecraftWorlds` (worlds).
