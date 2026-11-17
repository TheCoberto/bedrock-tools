# bedrock-tools

Scripts shared by TheCoberto's Minecraft Bedrock add-on repos.

## package.ps1

Builds an importable `.mcaddon` from any add-on repo. It finds every pack (any folder with a `manifest.json`) and names the file after the behavior pack's manifest, so `Snowfall [1.1.0]` becomes `Snowfall-1.1.0.mcaddon`.

```powershell
# From inside an add-on repo: builds into that repo's dist folder
powershell -ExecutionPolicy Bypass -File ..\bedrock-tools\package.ps1

# A specific repo into a shared folder
powershell -ExecutionPolicy Bypass -File package.ps1 -Repo ..\stronger-skeletons -OutDir ..\builds

# Also build a separate .mcpack for each pack
powershell -ExecutionPolicy Bypass -File package.ps1 -Repo ..\project-snow -OutDir ..\builds -PerPack
```

Double-click a built file to import it into Minecraft. Importing only adds the packs to the library; each world still chooses which packs to turn on.

Why a script instead of zipping by hand:

- **Layout.** A `.mcaddon` needs each pack *folder* at the root of the zip, while a `.mcpack` needs one pack's *contents* at the root. Zipping the wrong level is the usual cause of "import failed".
- **Path separators.** Windows' built-in `Compress-Archive` writes backslashes inside the zip. Windows Minecraft tolerates that, but imports on Android, iOS and console can fail. The script writes the zip itself with forward slashes.
- **Versioned names.** The version is read from the manifest, so the file name is always right and old builds don't get mixed up with new ones.

## Checklist when starting a new add-on from a copy of another repo

Regenerate all four UUIDs (the header and module UUID in both the BP and RP manifests) before anything else. Minecraft identifies a pack by its header UUID, so two add-ons sharing one can't be installed together.

```powershell
1..4 | ForEach-Object { [guid]::NewGuid().ToString() }
```
