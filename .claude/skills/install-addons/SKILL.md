---
name: install-addons
description: Install the add-ons in the builds folder into Minecraft Bedrock on this PC, replacing old versions and removing retired packs. Use when the user wants to play, test or apply add-ons to their worlds.
---

1. From bedrock-tools, preview: `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -WhatIf`.
2. If nothing would change, say so and stop.
3. If Minecraft is running (`Get-Process Minecraft.Windows*`), ask the user to close it first. Don't use `-Force` unless they ask.
4. Run `install.ps1`, then report what was updated, installed or removed in one or two lines, and where the backups went.

Worlds pick up updated packs automatically (matched by UUID). A newly installed add-on still has to be turned on in each world's settings.
