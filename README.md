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

In VS Code, open `C:\Repos\VS Code Workspaces\minecraft-bedrock-mod-suite.code-workspace` and use **Ctrl+Shift+P → Tasks: Run Task** to run any of these without typing commands. "This add-on" tasks use the add-on of the file you have open.

| Script | What it does |
| --- | --- |
| `check.ps1` | Finds mistakes before they reach Minecraft |
| `package.ps1` | Checks an add-on, then builds its `.mcaddon` |
| `build-all.ps1` | Checks and builds every add-on at once |
| `bump.ps1` | Updates an add-on's version everywhere |
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

## bump.ps1

```powershell
..\bedrock-tools\bump.ps1                  # 1.4.2 -> 1.4.3
..\bedrock-tools\bump.ps1 -Part minor      # 1.4.2 -> 1.5.0
..\bedrock-tools\bump.ps1 -Part major      # 1.4.2 -> 2.0.0
..\bedrock-tools\bump.ps1 -Version 2.0.0
..\bedrock-tools\bump.ps1 -Part minor -WhatIf   # show what would change
```

Sets the new version in every pack of the add-on: `header.version`, module versions, dependencies on the add-on's own packs, the version in the pack name (`[1.1.0]` or `v1.1.0`), and `pack.name` in `texts/*.lang`. Everything else in the files, including formatting, stays as it was. All packs in the add-on move to the new version. Add a changelog entry afterwards.

## GitHub Actions

Every add-on repo has `.github/workflows/addon.yml`, which calls the shared workflow in this repo (`.github/workflows/addon.yml`):

- **Every push and pull request:** runs the check and builds the add-on. The `.mcaddon` is saved with the run (Actions tab → the run → Artifacts).
- **Every published release:** also attaches the `.mcaddon` to the release.

To release an add-on:

```powershell
..\bedrock-tools\bump.ps1 -Part minor
# add a changelog entry, commit, push
gh release create v1.2.0 --generate-notes
```

The workflow downloads this repo while it runs, so bedrock-tools must be **public**, or each add-on repo needs a `BEDROCK_TOOLS_TOKEN` secret with read access to it.

To change the workflow for every add-on, edit `templates/addon-ci.yml` and run `.\install-ci.ps1 -All`. Changes to the shared steps in `.github/workflows/addon.yml` apply to every add-on automatically.

## Starting a new add-on from a copy of another repo

Regenerate all four UUIDs (the header and module UUID in both the BP and RP manifests) before anything else, and point the copy at its own GitHub repo (`git remote set-url origin ...`). `check.ps1 -All` catches UUIDs you forget.

```powershell
1..4 | ForEach-Object { [guid]::NewGuid().ToString() }
```
