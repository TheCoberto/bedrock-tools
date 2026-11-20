# bedrock-tools

Shared tools for TheCoberto's Minecraft Bedrock add-ons. Clone it next to the add-on repos:

```
C:\Repos\Mods\Minecraft Bedrock\
  bedrock-tools\     <- this repo
  builds\            <- every built .mcaddon ends up here
  project-snow\
  fat-man\
  ...
```

In VS Code, open the `minecraft-bedrock-mod-suite.code-workspace` workspace and use **Ctrl+Shift+P → Tasks: Run Task** to run any of these without typing commands. "This add-on" tasks use the add-on of the file you have open.

| Script | What it does |
| --- | --- |
| `check.ps1` | Finds mistakes before they reach Minecraft |
| `package.ps1` | Checks an add-on, then builds its `.mcaddon` |
| `build-all.ps1` | Checks and builds every add-on at once |
| `install.ps1` | Installs everything in `builds` into Minecraft on this PC |
| `status.ps1` | One table of what still needs doing across every add-on |
| `promo.ps1` | Makes an add-on's promo banner and logo in the shared style |
| `release.ps1` | Releases an add-on start to finish: bump, PR, merge, release, build, install |
| `bump.ps1` | Updates an add-on's version everywhere |
| `sync.ps1` | Copies shared files from another add-on (Skeleton Variants → Bow Variants) |
| `install-ci.ps1` | Adds the GitHub Actions workflow to add-on repos |

From a terminal, run them with `powershell -ExecutionPolicy Bypass -File <script>`. Paths below are from inside an add-on repo.

## check.ps1

```powershell
..\bedrock-tools\check.ps1          # the add-on you're in
..\bedrock-tools\check.ps1 -All     # every add-on, plus clashes between them
```

**Errors** (the add-on is broken or won't load right):
- `manifest.json` or any other JSON file doesn't parse. Comments are allowed, like in Minecraft.
- A text file isn't UTF-8, so color codes show up garbled in game.
- A pack or module UUID is invalid, or used twice.
- A pack has scripts in `scripts/` but no script module, so they never run, or its script entry file is missing.
- A pack depends on another pack in the repo at the wrong version.
- With `-All`: two add-ons share a pack UUID, so Minecraft treats them as the same pack.

**Warnings:** the version in the pack name doesn't match `header.version`; a Script API dependency with no script module; with `-All`, two add-ons share a module UUID.

It exits with code 1 when there are errors, so GitHub Actions marks the run as failed.

## package.ps1

```powershell
..\bedrock-tools\package.ps1                # builds into ..\builds
..\bedrock-tools\package.ps1 -PerPack       # also a .mcpack for each pack
..\bedrock-tools\package.ps1 -SkipCheck     # build even if the check finds errors
```

Runs the check first and stops on errors. The file is named from the behavior pack's manifest, so `Snowfall [1.1.0]` becomes `Snowfall-1.1.0.mcaddon`. Names kept in a language file (`pack.name`) are looked up.

Why not zip by hand:
- **Layout.** A `.mcaddon` needs each pack *folder* at the root of the zip; a `.mcpack` needs one pack's *contents* at the root. Zipping the wrong level is the usual cause of "import failed".
- **Path separators.** Windows' built-in `Compress-Archive` writes backslashes inside the zip, which can break imports on Android, iOS and console. This writes forward slashes.
- **Clean contents.** `.git`, `.vs`, `.github`, READMEs and old builds are left out, even when the repo itself is the pack.

## build-all.ps1

```powershell
.\build-all.ps1          # from bedrock-tools
.\build-all.ps1 -Force   # also build add-ons with check errors
```

Checks every add-on, then builds each one into `builds\`. An add-on with errors is skipped and listed at the end; the rest still build.

## install.ps1

```powershell
.\install.ps1           # from bedrock-tools
.\install.ps1 -WhatIf   # show what would change
.\install.ps1 -Force    # install even while Minecraft is running
```

Installs every add-on in `builds\` into Minecraft Bedrock on this PC, like double-clicking each `.mcaddon` but without the mess:

- Each pack **replaces** the installed pack with the same UUID, in the same folder, instead of being added next to it. New packs go into `development_behavior_packs` and `development_resource_packs`.
- Packs that already match the build are left alone. Line endings don't count, so a GitHub build and a local build of the same code match.
- If `builds\` holds several versions of an add-on, only the newest is installed.
- Every replaced or removed pack is backed up to `pack-backups\<date>` next to the repos.
- Packs listed in `retired.json` are removed. List an add-on there when another one replaces it (Explosive Arrow → Bow Variants). Add both its BP and RP UUIDs.
- Packs that aren't in `builds\` or `retired.json` are never touched.

Close Minecraft first: it only reads packs when it starts, so the script stops if it's running (unless you pass `-Force`). It finds Minecraft's `com.mojang` folder itself, for both the current Windows version (`%APPDATA%\Minecraft Bedrock\Users\Shared\games`) and the older Microsoft Store one; pass `-MinecraftDir` to use another.

Worlds that use an older version of an updated pack pick up the new one, because Minecraft matches packs by UUID.

## status.ps1

```powershell
.\status.ps1            # from bedrock-tools
.\status.ps1 -NoFetch   # skip fetching from GitHub (faster)
```

One row per repo: uncommitted or unpushed work, open PRs, the latest release, pack changes since that release, whether `builds\` has the current version, and whether the MCPEDL post is on the latest release. Then whether Minecraft has everything in `builds\` installed. Promo images, READMEs and workflow files don't count as changes. Exits with code 1 when something needs doing.

## listings.json

Where each add-on is published: its MCPEDL post, LootLabs link, the Google Drive file behind that link, and `postedVersion` (the version last uploaded to MCPEDL). After updating an MCPEDL post, set `postedVersion` to the new version. The listing text for each post is in the add-on's `listing/mcpedl.md`.

## release.ps1

```powershell
.\release.ps1 -Repo fat-man -Part minor -Notes "- Adds launcher sounds."
.\release.ps1 -Repo fat-man -Part minor -Notes "..." -WhatIf   # show the plan only
.\release.ps1 -Repo fat-man -NoBump -Notes "..."               # release the version already in the manifests
```

Commit and merge the change first; this does the rest:

1. Checks the repo is on its default branch, clean, and pushed, and pulls.
2. Bumps the version on a `release-<version>` branch and adds the notes to the add-on's `changelog.txt`/`.md` (in that file's style; an `Unreleased` heading is renamed to the version instead). Opens a PR, waits for the checks and merges it.
3. Creates the GitHub release `v<version>`, titled `<Add-on name> <version>`.
4. Waits for the release build, downloads the `.mcaddon` into `builds\` and removes older versions of that add-on.
5. Runs `install.ps1`, unless Minecraft is running or you pass `-NoInstall`.

`-CommitTrailer` and `-PrFooter` add lines to the end of the bump commit and PR description.

## bump.ps1

```powershell
..\bedrock-tools\bump.ps1                  # 1.4.2 -> 1.4.3
..\bedrock-tools\bump.ps1 -Part minor      # 1.4.2 -> 1.5.0
..\bedrock-tools\bump.ps1 -Part major      # 1.4.2 -> 2.0.0
..\bedrock-tools\bump.ps1 -Version 2.0.0
..\bedrock-tools\bump.ps1 -Part minor -WhatIf   # show what would change
```

Sets the new version in every pack of the add-on: `header.version`, module versions, dependencies on the add-on's own packs, the version in the pack name (`[1.1.0]` or `v1.1.0`), and `pack.name` in `texts/*.lang`. Everything else in the files, including formatting, stays as it was. All packs in the add-on move to the new version. Add a changelog entry afterwards.

## sync.ps1

```powershell
..\bedrock-tools\sync.ps1           # copy shared files into the add-on you're in
..\bedrock-tools\sync.ps1 -Check    # only report differences; exits 1 if out of sync
```

For add-ons that share content with another one. Edit the shared files in the **source** add-on, then sync. The add-on that receives them lists what's shared in a `sync.json` at its root (see `bow-variants/sync.json`):

- `files`: copied whole. `*` and `?` in the file name match several files.
- `json`: copies only the listed keys of one object (like `texture_data` in `item_texture.json`). The add-on's other keys are left alone.
- `lang`: copies only the listed `key=value` lines.

It only rewrites a JSON file when a value differs, and line-ending differences don't count as changes. A missing source file or key is an error, so renames in the source don't go unnoticed. The source repo isn't available in GitHub Actions, so this runs locally only.

## GitHub Actions

Every add-on repo has `.github/workflows/addon.yml`, which calls the shared workflow in this repo (`.github/workflows/addon.yml`):

- **Every push and pull request:** runs the check and builds the add-on. The `.mcaddon` is saved with the run (Actions tab → the run → Artifacts).
- **Every published release:** also attaches the `.mcaddon` to the release.

To release an add-on, use `release.ps1` (above). It bumps the version, creates the release, and puts the build in `builds\` and in Minecraft.

## Working with Claude Code

Start Claude Code in this folder. `CLAUDE.md` holds the suite's conventions, and `.claude/skills/` adds three commands:

| Command | What it does |
| --- | --- |
| `/suite-status` | Runs `status.ps1` and lists only what needs doing |
| `/release-addon <repo> [patch\|minor\|major]` | Writes release notes and runs `release.ps1` |
| `/install-addons` | Runs `install.ps1` after checking Minecraft is closed |

The workflow downloads this repo while it runs, so bedrock-tools must be **public**, or each add-on repo needs a `BEDROCK_TOOLS_TOKEN` secret with read access to it.

To change the workflow for every add-on, edit `templates/addon-ci.yml` and run `.\install-ci.ps1 -All`. Changes to the shared steps in `.github/workflows/addon.yml` apply to every add-on automatically.

## Starting a new add-on from a copy of another repo

Regenerate all four UUIDs (the header and module UUID in both the BP and RP manifests) before anything else, and point the copy at its own GitHub repo (`git remote set-url origin ...`). `check.ps1 -All` catches UUIDs you forget.

```powershell
1..4 | ForEach-Object { [guid]::NewGuid().ToString() }
```
