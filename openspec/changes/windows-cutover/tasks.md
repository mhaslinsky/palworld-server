## 1. Phase A — Rebuild + validate Windows (Linux untouched, no player impact)

- [x] 1.1 Confirm a recent Linux backup exists and record the world GUID from it (done: `E02C5819443F44ED89133A6C03B43E25` from `20260721T031953Z.tgz`)
- [x] 1.2 Snapshot the Windows D: save volume `vol-0a09078e2d03adfd1` (done: `snap-0ad1d65d4f5017494`)
- [x] 1.3 `git status` clean; `terraform plan -out=tfplan`; READ it; confirmed ONLY `aws_instance.server_windows[0]` + `aws_volume_attachment.windows_save[0]` affected, `aws_instance.server` absent (`Plan: 2 add, 0 change, 2 destroy`)
- [x] 1.4 Quoted plan + go-ahead received; `terraform apply tfplan` complete. **New Windows instance `i-0d8807c3513cc1173`** (was `i-03b0719f765c523c1`; temp IP `100.53.201.122`)
- [x] 1.5 Building mod = **4 content `.pak`s** restored from `D:\PalServer\mods` → `~mods`. **No UE4SS** — plain content paks, so BLOCKER-1 (UE4SS-vs-build compat) does not apply. Loaded clean on freshly-pulled build `v1.0.1.100619`
- [!] 1.6 GATE BLOCKED — ROOT CAUSE FOUND: relaxed building works in the owner's **single-player** (client mounts `~mods` natively) but NOT on the rebuilt dedicated server. The dedicated server needs a **loader (UE4SS)** to mount `~mods`/LogicMods paks; Saturday's working box had UE4SS installed **interactively**, and **the repo never codifies a UE4SS install** (grep: comments only) — so the rebuild wiped it. Corroborated by: the original migration plan (titled "server-side UE4SS building mods"), web research (RE-UE4SS #319 = exact "SP works, dedicated doesn't" symptom), and the owner independently finding UE4SS dedicated-server install docs on pwmodding.wiki. `PalModSettings.ini` has `bGlobalEnableMod=True` but empty `WorkshopRootDir`/no `ActiveModList`; `~WorkshopMods` absent. Dedicated server emits no readable UE game log, so mount was never directly observable.

## 1c. FIX — install UE4SS on the dedicated server (in progress)

- [ ] Obtain the **Palworld-fork UE4SS** version-matched to build `v1.0.1.100619` (reuse Saturday's known-good files if the owner still has them; else source from GitHub/pwmodding). Files: `ue4ss` folder + `dwmapi.dll` (+ `MemberVariableLayout.ini`) → `C:\PalServer\Pal\Binaries\Win64\`
- [ ] Restart server; verify UE4SS loads and the `~mods` building paks mount; owner re-tests relaxed building on the test box (temp IP)
- [ ] Watch for UE4SS-on-dedicated regressions (RE-UE4SS #452: connection refusal / character-creation loop) — test on the throwaway box, never near the live world
- [ ] **Codify UE4SS into `windows_user_data.ps1.tftpl`** (stage on D: like the paks, restore to Win64 on boot) so a future rebuild does not wipe it again — this is the regression's real fix
- [x] Owner chose mod **1898** "Building Restrictions Disabler" (Cetino) as the building solution — its "DLL Mod for client and server" variant is a **UE4SS C++ mod** (`BuildingRestrictionsDisabler/dlls/main.dll` + `enabled.txt`), confirmed via parallel.ai extract. **Requires UE4SS experimental** (not standard); goes in `Win64\ue4ss\Mods\`; **both client AND server must be modded**; 1.0.1 Steam/GamePass, Windows-only. Staged to `s3://…/scripts/windows/mods/BuildingRestrictionsDisabler-1898.zip`
- [ ] BLOCKER — pick the UE4SS experimental build matching game `v1.0.1.100619` (mismatch crashes on boot). GitHub `experimental-latest` = `UE4SS_v3.0.1-1012-gc838a8ac`; Palworld needs a matching `MemberVariableLayout`. Options: reuse owner's Saturday UE4SS files (guaranteed match) OR install latest experimental + Palworld config on the throwaway box and iterate via `ue4ss\UE4SS.log`
- [x] Owner modded their CLIENT locally (UE4SS + mod 1898) — both-sides gating satisfied
- [x] Server-side install DONE + verified: `ue4ss` + `dwmapi.dll` in Win64; `UE4SS.log` shows `BuildingRestrictionDisabler` v0.1.75.0 loaded, AOBs found, **client version match `v1.0.1.100619`**, activated. Server up (no crash, no connection-refusal regression); REST worldguid still `E02C…B43E25`. UE4SS + mod zips staged on `D:\PalServer\ue4ss-stage\` for rebuild persistence
- [x] FINAL GATE PASSED — owner confirmed relaxed building works in-game (2026-07-21) once isolated to **only** mod 1898. Root of the "still broken": the old `~mods` paks AND 1898 were both loaded and **conflicted**; moving the 5 paks to `~mods_disabled` (leaving only the 1898 UE4SS mod) fixed it
- [ ] **Codify into `windows_user_data.ps1.tftpl`** (pure-ASCII!) — the regression's permanent fix: on boot, restore UE4SS (`ue4ss` + `dwmapi.dll`) + mod 1898 into Win64 from `D:\PalServer\ue4ss-stage\`, and STOP restoring the old conflicting building paks (current template copies `D:\PalServer\mods\*.pak` → `~mods`; that reintroduces the conflict). Decide pal-size pak's fate (currently disabled; cosmetic, owner said non-critical)
- [ ] Clean the persistent source: remove the old building paks from `D:\PalServer\mods` so a boot can't re-restore them

## 1d. Extra mods + settings (owner requests, 2026-07-21 ~2am)

- [x] Base decay OFF — inserted `BuildObjectDeteriorationDamageRate=0.000000` at front of `OptionSettings` on the Windows box; verified live via REST (`= 0`). **Must also add to `windows_instance.tf` `option_settings`** so a rebuild keeps it
- [x] FSS "Full Sphere Summon" (Nexus 3620) — **client-only** UE4SS Lua mod (`ue4ss\Mods\FullSphereSummon\`); owner installs on their PC; nothing server-side
- [ ] CODIFY roundup for `windows_instance.tf` / user_data: (a) `BuildObjectDeteriorationDamageRate=0.000000` in option_settings; (b) UE4SS + mod 1898 restore from `D:\PalServer\ue4ss-stage\`; (c) DROP the old-pak `~mods` copy step (conflicts with 1898)
- [x] Client mod install guide written: `docs/client-mods.md` (UE4SS + 1898 required, 3620 optional client-only, base-decay-off noted, version-tracking table)

## PAUSED 2026-07-21 ~02:20 local — resume tomorrow after work

- Windows box `i-0d8807c3513cc1173` **stopped** (billing halted; D: volume persists with world copy + mods + `ue4ss-stage`). Linux `i-09d1d8ae70eb28369` stopped, world safe on `prevent_destroy` vol, EIP still on it. Nothing cut over — no live-service change.
- **NEXT SESSION (the official cutover):** 1) take a FRESH consistent save from Linux (graceful stop → new backup) — the test copy on D: is stale; 2) run Phase B (place fresh save + GUID surgery, rehearsed) → Phase C (codify TF + repoint control plane + move EIP) → verify → Phase D soak. 3) Do the CODIFY roundup BEFORE/at cutover so the live box survives rebuilds.
- Uncommitted in repo: `openspec/`, `docs/client-mods.md`, `.claude/` (OpenSpec init). Commit as part of the cutover PR.
- [x] 1.7 `BaseWorkerPalSize50Percent_P.pak` placed in `D:\PalServer\mods` + `~mods`; server restarted, still serves real world (visual effect = owner confirms)

## 1b. Test-copy rehearsal (done — de-risks Phase B)

- [x] Brought the freshest S3 backup (`20260721T035044Z.tgz`) onto the Windows D: via server-side S3 copy → box pull (read-only; Linux world volume + S3 originals never touched)
- [x] Proved the Phase-B mechanics end to end: `tar` extract → strip `._*` → `DedicatedServerName` GUID surgery → served-GUID guard returns `E02C…B43E25` (not empty). The real cutover reruns this with a fresh consistent save after a graceful Linux stop
- [ ] NOTE for Phase C: `PalworldIdle` scheduled task is **Disabled** on the Windows box — must be enabled (`enable --now` equivalent) so idle-shutdown works post-cutover

## 2. Phase B — Migrate the real world (brief owner-only Linux stop)

- [ ] 2.1 Re-confirm the roster (owner-only) before stopping
- [ ] 2.2 Graceful-stop Linux (`systemctl stop palworld.service`); verify `Level.sav` mtime advanced
- [ ] 2.3 Trigger a fresh `backup-to-s3` so the copy is current to this instant
- [ ] 2.4 Download that fresh object onto Windows; extract to `D:\PalServer\SaveGames\0\<GUID>\` (strip `._*` / `COPYFILE_DISABLE=1`); never touch the Linux world volume
- [ ] 2.5 GUID surgery: set `DedicatedServerName=<GUID>` in Windows `GameUserSettings.ini`
- [ ] 2.6 Start Windows; verify REST `/v1/api/info` `worldguid == <GUID>` and players/levels present. Do NOT proceed if it mismatches

## 3. Phase C — Repoint control plane + EIP (Terraform, not player-facing)

- [ ] 3.1 Edit `discord.tf` (INSTANCE_ID + StartInstances ARN → Windows), `backup_monitor.tf` (INSTANCE_ID → Windows, BACKUP_PREFIX → `world/windows/`), `presence.tf` (instance_id → Windows), roster repoint + IAM, `network.tf` EIP association → Windows, `outputs.tf` cosmetic
- [ ] 3.2 `terraform plan -out=tfplan`; READ; confirm no `aws_instance.server` replace/destroy; quote `Plan:`; apply
- [ ] 3.3 Verify: `/palworld-start` starts Windows; `/status` + presence read the live roster; idle-shutdown stops Windows; monitor watches `world/windows/`

## 4. Phase D — Soak + decommission

- [ ] 4.1 Keep the Linux instance stopped (not terminated) ~1 week as rollback
- [ ] 4.2 After the soak: snapshot the Windows save, then decommission the Linux instance/volumes deliberately
