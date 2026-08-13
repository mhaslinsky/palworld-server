# Palworld Server: Client Mod Guide

What you (a player) need to install on **your own PC** to build freely on our Windows server.
Everything here is **client-side**: you install it in your Palworld game, not on the server.

> **Why:** relaxed building is enforced on **both** the server and each player's client. The
> server already has the mods; you need the matching ones locally or your builds get rejected.

## Step 1: Install UE4SS (required first, it loads the mods)

Use the **Palworld experimental** build, matched to the current game version
(**`v1.0.3.101283`** as of 2026-08-12). A mismatched UE4SS will crash the game.

- Download: https://github.com/UE4SS-RE/RE-UE4SS/releases (experimental). We run
  `UE4SS_v3.0.1-1012` on the server, unchanged across 1.0.1 to 1.0.2 to 1.0.3 and
  verified loading against `v1.0.3.101283`. **UE4SS itself did not need updating for
  the 1.0.3 patch** - only mod 1898 did (see the table below), which is the usual
  shape: the loader survives patches, the AOB-scanning DLL mod does not.
- Extract `dwmapi.dll` + the `ue4ss` folder into your game's Win64 folder:
  `...\steam\steamapps\common\Palworld\Pal\Binaries\Win64\`

## Step 2: Install the mods (drop each folder into `ue4ss\Mods\`)

Target folder: `...\Palworld\Pal\Binaries\Win64\ue4ss\Mods\`

| Mod | Nexus | Version | Required? | Notes |
|-----|-------|---------|-----------|-------|
| **Building Restrictions Disabler** | [1898](https://www.nexusmods.com/palworld/mods/1898) | **1.82** (DLL, client+server) | **Required to build freely** | Folder `BuildingRestrictionsDisabler\` (has `enabled.txt` + `dlls\main.dll`). Must be on both sides (the server already has it). **Update to 1.82 for game 1.0.3**: 1.78 loads and then logs `Version pattern not found`, so building goes silently vanilla. Older still, 1.75 on 1.0.2 reported `Incompatible game client version`. |
| **FSS – Full Sphere Summon** | [3620](https://www.nexusmods.com/palworld/mods/3620) | 0.7.0 (UE4SS Lua) | Optional | Folder `FullSphereSummon\` (has `enabled.txt` + `Scripts\main.lua`). Client-only; restores throw-to-summon. |
| **Max Stack Count** | [376](https://www.nexusmods.com/palworld/mods/376) | 1.3 (UE4SS Lua) | **Required for raised stacks** | Folder `MaxStackCount\` (has `enabled.txt` + `Scripts\main.lua`). Raises item stack caps from 9999 to 999,999,999. Must be on both sides (the server already has it): a vanilla client stays capped at 9999 even though the server allows more. Confirmed in-game by multiple players. |

After copying, confirm the paths exist with **no extra nested folder**, e.g.
`...\ue4ss\Mods\BuildingRestrictionsDisabler\dlls\main.dll`.

## Step 3: Verify in-game

Join the server and try an illegal build (overlap / on a slope / no foundation).
- **It places and sticks** → working.
- **Blue/green preview then a red error** → the mod isn't right on the server (tell the admin).
- **Normal vanilla block, no special preview** → your client mod isn't active (recheck Steps 1–2).

## When Palworld patches (this WILL happen again)

A base-game patch reliably breaks mod 1898 and reliably does not break UE4SS. 1898 finds
the code it patches by AOB signature scan, and a patch moves those bytes, so the mod
loads, registers, and then silently does nothing. **The symptom is not an error. It is
building quietly behaving like vanilla**, which is easy to mistake for "the server is
misconfigured".

The sequence on 2026-08-12, which is the shape to expect:

| Time (UTC) | What |
|-----------|------|
| 03:01 | Pocketpair ships 1.0.3. Steam updates CLIENTS on next launch |
| ~03:00 onward | Players who relaunch get **version incompatible** and cannot join at all |
| 05:44 | Mod 1898 publishes 1.82, the compatible build |

So there is a window, nearly three hours that night, where the base patch is out and the
mod is not. **This is why the server is never auto-updated**: updating inside that window
gets everyone connected again with relaxed building silently broken.

What to do as a player:

1. Wait for the admin to say the server is updated. Until then, do not be surprised by
   `version incompatible` - your client updated and the server has not yet.
2. Once it is updated, check [mod 1898](https://www.nexusmods.com/palworld/mods/1898)
   for a build matching the new game version and install it. Your builds get rejected
   client-side if your 1898 is older than the server's, even though the server is fine.
3. UE4SS itself almost certainly does not need touching.

The admin gets a Discord alert within 30 minutes of any Steam build change, so nobody
has to notice this by failing to connect.

## Don't run two building mods at once

If you previously had the old pak mods (`LessRestrictiveSettings_P`, `NoCollision*_P`) in
`Pal\Content\Paks\~mods\`, **remove them**: they conflict with 1898 and the result is that
*neither* works. Use only mod 1898 for building.

---

## Server-managed (no player action needed)

Tracked here so we know what's set. These live on the server / in Terraform:

- **UE4SS + Building Restrictions Disabler (1898)**: installed on the Windows dedicated server.
- **MaxStackCount** ([376](https://www.nexusmods.com/palworld/mods/376), 1.3, UE4SS Lua): installed
  on the Windows dedicated server. Raises item stack caps from 9999 to 999,999,999. Enabled purely
  via `enabled.txt` (same override mechanism as Building Restrictions Disabler), not listed in
  `mods.txt`. On `v1.0.3.101283` it LOADS - `UE4SS.log` shows
  `Max Stack Count version 1.3 intended for UE4SS 3.0.1 loaded for game version 0.4.11` -
  but the line that proves the rewrite actually FIRED,
  `[Max Stack Count] set from 9999 to 999999999 [palServerRegisterHook]`, was **not
  present** when checked on 2026-08-12 with zero players connected. It was last seen on
  `v1.0.2.101103`.

  Loaded is not working, and this repo has already been burned by exactly that gap: mod
  1898 spent a day logging itself as loaded while silently doing nothing. The likeliest
  benign explanation here is the hook's own name - `palServerRegisterHook` suggests it
  fires when a player registers, and nobody had connected since that launch. **Settle it
  the next time someone is on**, rather than assuming either way:

  ```powershell
  Select-String -Path C:\PalServer\Pal\Binaries\Win64\ue4ss\UE4SS.log -Pattern 'palServerRegisterHook'
  ```

  If it still does not appear with a player connected, the stack cap is vanilla and the
  mod needs a build matching 1.0.3. Note `UE4SS.log` is TRUNCATED on every launch, so
  check it during the session you care about, not after a restart.
  It carries a client hook too, and players must install it client-side to get the raised cap:
  a vanilla client stays hard-capped at 9999 even though the server allows more (confirmed in-game
  by multiple players). It is therefore listed under Step 2 as a required player install.
- **Base structure decay: OFF.** `BuildObjectDeteriorationDamageRate=0.000000` in
  `PalWorldSettings.ini`. Structures don't deteriorate.
- Existing world settings carried over: `BaseCampWorkerMaxNum=50`, `BaseCampMaxNumInGuild=10`,
  `PalSpawnNumRate=2.0`, `DeathPenalty=Item`, `PalEggDefaultHatchingTime=0.03`, global palbox
  import/export on.

**Maintenance note:** after any major Palworld patch, UE4SS and the mods likely need updated
builds. Expect building to break until the versions are re-matched (the server deliberately
does not auto-update). Keep this file's versions current when we bump anything.

**Updating a modded server.** `/palworld-update` (Discord) - or `scripts/update-server.ps1`
on the box - takes a **`mods`** mode. All three update the base game via SteamCMD first:

| `mods` | What it does | When |
|--------|--------------|------|
| `keep` (default) | Re-overlays the UE4SS build **currently on D:**, verifies the mod files. | The staged build already matches the new game version. |
| `vanilla` | **Disables UE4SS** (removes the `dwmapi.dll` loader) so the box is joinable regardless of mod compatibility. Building goes vanilla. | A patch dropped and matching mod builds aren't ready - restore playability now. |
| `restage` | `aws s3 sync`s a matching build from `s3://<backups-bucket>/ue4ss-stage/` onto the D: durable stage **first**, then overlays it. | You've prepared a matching build and want it live without RDP. |

The recommended patch-day flow:

1. Get the UE4SS **experimental** build + mod 1898 build matching the *new* game version
   (GitHub / Nexus - both need a human; Nexus needs a login, which is why the server never
   fetches them at boot).
2. Upload that tree to **`s3://<backups-bucket>/ue4ss-stage/Win64/…`** (mirrors the on-box
   layout: `ue4ss-stage/Win64/dwmapi.dll`, `ue4ss-stage/Win64/ue4ss/…`, etc.).
3. Run **`/palworld-update mods:restage`**. It syncs S3 → D:, overlays D: → the game, verifies,
   relaunches, and reports whether relaxed building survived.

If matching builds aren't out yet, run **`/palworld-update mods:vanilla`** to restore joinability
now (building disabled), then `mods:restage` later once they are. Running plain `/palworld-update`
(`keep`) with an **incompatible** staged UE4SS will **crash-loop** the server - the report calls
that out; recover with `mods:vanilla`. Bump the versions in the table above whenever you restage.

**One-time setup - seed the S3 baseline.** `mods:restage` pulls from `s3://<bucket>/ue4ss-stage/`,
which starts empty. Publish the box's current proven-good stage once with
`scripts/seed-ue4ss-stage.ps1` (it refuses to publish an incomplete stage). Run it over SSM Run
Command (`AWS-RunPowerShellScript`, no RDP) - paste:

```powershell
$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$b = (Get-Content C:\PalServer\idle.conf.json -Raw | ConvertFrom-Json).BackupBucket
& $aws s3 cp "s3://$b/scripts/windows/seed-ue4ss-stage.ps1" C:\PalServer\scripts\seed-ue4ss-stage.ps1 --only-show-errors
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PalServer\scripts\seed-ue4ss-stage.ps1
```

Thereafter, to publish a **new** matching build: update `D:\PalServer\ue4ss-stage\Win64` on the box
(or upload it straight to `s3://<bucket>/ue4ss-stage/Win64/…`), then `/palworld-update mods:restage`.
Re-running the seed script republishes whatever is currently on D:.

**A restage can transfer NOTHING and still report success.** Syncing S3 to local, the AWS CLI
ignores same-sized objects unless the *local* copy is newer, and a rebuilt DLL very often lands
on the same byte count: mod 1898 v1.78 is exactly the same size as v1.75 (1270272 bytes). On
2026-07-30 the restage therefore transferred nothing, exited 0, overlaid the old DLL, and
reported the mod loaded. `update-server.ps1` now passes `--exact-timestamps` for this. If you
ever sync the stage by hand, pass it too, and confirm by hash rather than by exit code:

```powershell
(Get-FileHash 'D:\PalServer\ue4ss-stage\Win64\ue4ss\Mods\BuildingRestrictionsDisabler\dlls\main.dll' -Algorithm SHA256).Hash
```

**Reading the mod's own verdict.** File presence proves the overlay copied, not that the mod
works. After a relaunch, `Win64\ue4ss\UE4SS.log` (truncated on each launch) tells you which of three
things happened:

| What the log says | Meaning |
|---|---|
| `Found all AOBs for restriction <...>` | Working. It hooked real restrictions. |
| `Incompatible game client version ... !` | Terminal. The mod build does not support this game build. |
| `Version pattern not found :(` repeatedly, with **no** later `Version pattern found` | The scan never succeeded. Building is vanilla. |

A handful of `Version pattern not found` lines followed by success is **normal cold-boot retry
noise**, not a fault: a healthy 1.78 start printed it 13 times before hooking. Likewise
`Could not find all AOBs for restriction <Disable "Not connected to structure">` is expected on
1.78 and only means that one restriction stays enforced.
