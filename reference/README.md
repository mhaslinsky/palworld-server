# Palworld item IDs — display name is NOT the internal ID

`palworld-item-ids.tsv` maps every in-game English display name to the internal
item ID the save file actually stores. 2,372 items, sorted by display name.

**Read this before granting anyone an item.** The IDs and the names people say out
loud disagree in ways you cannot guess, and the failure is silent: you hand over a
plausible-looking wrong item and nobody notices until they try to craft with it.

## The traps that already caught us (2026-07-18)

| Someone says | Internal ID | Trap |
|---|---|---|
| "Ingot" (the base one) | `CopperIngot` | **NOT `IronIngot`** — that one displays as *"Refined Ingot"*, the tier ABOVE. Grabbing the obvious-looking ID gives the wrong tier. |
| "Circuit Board" | `MachineParts2` | The ID contains no form of "circuit" or "board". Searching IDs finds nothing and you conclude, wrongly, that the item does not exist. |
| "High Quality Pal Oil" | `PalOil` | The ID drops the qualifier entirely. There is no separate low-quality oil. |
| "Hyper Sphere" | `PalSphere_Tera` | Tiers are Pal / Mega / Giga / **Tera=Hyper** / Master=Ultra. The ID ladder and the display ladder use different words at the same rank. |
| "Flame Organ" | `FireOrgan` | Flame vs Fire. |
| "Water organ" | *does not exist* | Palworld has exactly three organs: Electric, Flame, Ice. A confident-sounding request can still name something that was never in the game. |
| "Medical Supplies" | `Medicines` | And *"Low Grade Medical Supplies"* is `Herbs` — the word "medicine" appears in neither ID. |

## How to look something up

Always search the **display_name** column, never guess at IDs:

```bash
grep -i 'circuit' reference/palworld-item-ids.tsv
grep -iP '^\s*Ingot\t' reference/palworld-item-ids.tsv    # exact display name
```

If a search of the item IDs finds nothing, that means nothing — check the names
before concluding an item is absent.

## Regenerating

Sourced from the Palworld Save Pal repo's bundled game data
(`~/Developer/palworld-save-pal/data/json/`), which ships `items.json` plus
`l10n/en/items.json`. Regenerate after a game update:

```bash
cd ~/Developer/palworld-save-pal && git pull
# then re-run the generator (see the palworld-server session notes / AIDB)
```

The same name-vs-ID split applies to Pals (`pals.json` + `l10n/en/pals.json`) —
extend this file if a Pal grant ever needs it.

## `BPModLoaderMod-main.lua`

The copy of UE4SS's `BPModLoaderMod\Scripts\main.lua` that the server runs, at
`Pal\Binaries\Win64\ue4ss\Mods\BPModLoaderMod\Scripts\main.lua` and in the D: UE4SS
stage. It is Okaetsu's `logicmod-temp-fix` branch plus one local patch, and it lives here
because nothing else in this repo versions the UE4SS stage: a mod update or a rebuilt
stage would otherwise lose it with no record of what was lost.

sha256 `2f31e30cb4132f3f2b4864b242e7484fb05ca4ebde85fd433db61faac3e1d60e`.

The patch is described in AGENTS.md rule 6. Short version: upstream's `LoadMod` returns
`false` on an invalid World without registering the mod for revalidation, so the retry
loop iterates an empty table and prints `Finished loading LogicMods!` having loaded
nothing. Search this file for `LOCAL PATCH` to find it.

Two upstream sources to diff against when UE4SS updates:
<https://github.com/Okaetsu/RE-UE4SS/blob/logicmod-temp-fix/assets/Mods/BPModLoaderMod/Scripts/main.lua>
is the fix, and the stock file sits on the box as `main.lua.stock`.

## `AutoHatch-main.lua`

A hardened `AutoHatch\Scripts\main.lua` for Nexus mod 1959 v0.9.9.6. **This is the file
the server runs**, deployed to live C: and the D: UE4SS stage.

It did not fix the crash, and was never going to: the crash was a missing
`MemberVariableLayout.ini` (AGENTS.md rule 6). What it does carry is one load-bearing
correction plus the instrumentation that found the real cause.

The correction: stock reads `messageStruct.senderPlayerUId` with a lower-case s on lines
80, 84 and 86, where the field is `SenderPlayerUId`. It returns nil, so `guidToString` gets
nil and `!autohatch on/off` cannot resolve a player. With this fixed the commands work.

The rest is defensive and worth keeping: `alive()` guards before every dereference and
every `_ModActor:` call, `guidToString(nil)` returning nil instead of throwing, and
`trace()` breadcrumbs on hook entry. Those breadcrumbs are what proved the Lua side
completed cleanly while the process still died, which is what redirected the investigation
off the mod's Lua and eventually onto the loader. The `OnCompleteInitializeParameter` hook
also derives the player state from the character's own controller rather than a
module-level `playerState` that holds whichever state was created last server-wide; that
dangling pointer was real, and is simply not what was crashing us.

sha256 `ba7401f61341d50ba76bead61d44b84be72850d8b7e04ff035b88b666585c33a`.

Every change is a guard or a breadcrumb; no gameplay logic is altered. The substantive one
is in the `OnCompleteInitializeParameter` hook: stock compares against a module-level
`playerState` holding a raw pointer to the last `PalPlayerState` created **server-wide**,
which dangles as soon as that player disconnects and is simply wrong with two players
online. It now takes the state from the character's own controller, which cannot be stale.
The rest guards each dereference, fixes `SenderPlayerUId` casing (stock reads a lower-case
name that does not exist, so `!autohatch on/off` never worked), and traces hook entry so
the last `[AutoHatch/guard]` line in `UE4SS.log` names whatever was running if it crashes
again.

Full analysis, test protocol and rollback:
`~/Developer/AIDB/_global/personal/palworld-server/2026-08-22-autohatch-crash-investigation.md`
