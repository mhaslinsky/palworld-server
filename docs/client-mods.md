# Palworld Server — Client Mod Guide

What you (a player) need to install on **your own PC** to build freely on our Windows server.
Everything here is **client-side** — you install it in your Palworld game, not on the server.

> **Why:** relaxed building is enforced on **both** the server and each player's client. The
> server already has the mods; you need the matching ones locally or your builds get rejected.

## Step 1 — Install UE4SS (required first, it loads the mods)

Use the **Palworld experimental** build, matched to the current game version
(**`v1.0.1.100619`** as of 2026-07-21). A mismatched UE4SS will crash the game.

- Download: https://github.com/UE4SS-RE/RE-UE4SS/releases (experimental) — we run
  `UE4SS_v3.0.1-1012` on the server.
- Extract `dwmapi.dll` + the `ue4ss` folder into your game's Win64 folder:
  `...\steam\steamapps\common\Palworld\Pal\Binaries\Win64\`

## Step 2 — Install the mods (drop each folder into `ue4ss\Mods\`)

Target folder: `...\Palworld\Pal\Binaries\Win64\ue4ss\Mods\`

| Mod | Nexus | Version | Required? | Notes |
|-----|-------|---------|-----------|-------|
| **Building Restrictions Disabler** | [1898](https://www.nexusmods.com/palworld/mods/1898) | 1.75 (DLL, client+server) | **Required to build freely** | Folder `BuildingRestrictionsDisabler\` (has `enabled.txt` + `dlls\main.dll`). Must be on both sides — server already has it. |
| **FSS – Full Sphere Summon** | [3620](https://www.nexusmods.com/palworld/mods/3620) | 0.7.0 (UE4SS Lua) | Optional | Folder `FullSphereSummon\` (has `enabled.txt` + `Scripts\main.lua`). Client-only; restores throw-to-summon. |

After copying, confirm the paths exist with **no extra nested folder**, e.g.
`...\ue4ss\Mods\BuildingRestrictionsDisabler\dlls\main.dll`.

## Step 3 — Verify in-game

Join the server and try an illegal build (overlap / on a slope / no foundation).
- **It places and sticks** → working.
- **Blue/green preview then a red error** → the mod isn't right on the server (tell the admin).
- **Normal vanilla block, no special preview** → your client mod isn't active (recheck Steps 1–2).

## Don't run two building mods at once

If you previously had the old pak mods (`LessRestrictiveSettings_P`, `NoCollision*_P`) in
`Pal\Content\Paks\~mods\`, **remove them** — they conflict with 1898 and the result is that
*neither* works. Use only mod 1898 for building.

---

## Server-managed (no player action needed)

Tracked here so we know what's set. These live on the server / in Terraform:

- **UE4SS + Building Restrictions Disabler (1898)** — installed on the Windows dedicated server.
- **Base structure decay: OFF** — `BuildObjectDeteriorationDamageRate=0.000000` in
  `PalWorldSettings.ini`. Structures don't deteriorate.
- Existing world settings carried over: `BaseCampWorkerMaxNum=50`, `BaseCampMaxNumInGuild=10`,
  `PalSpawnNumRate=2.0`, `DeathPenalty=Item`, `PalEggDefaultHatchingTime=0.03`, global palbox
  import/export on.

**Maintenance note:** after any major Palworld patch, UE4SS and the mods likely need updated
builds — expect building to break until the versions are re-matched (the server deliberately
does not auto-update). Keep this file's versions current when we bump anything.
