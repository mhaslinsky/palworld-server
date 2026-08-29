# Palworld item IDs: display name is NOT the internal ID

`palworld-item-ids.tsv` maps every in-game English display name to the internal
item ID the save file actually stores. 2,372 items, sorted by display name.

**Read this before granting anyone an item.** The IDs and the names people say out
loud disagree in ways you cannot guess, and the failure is silent: you hand over a
plausible-looking wrong item and nobody notices until they try to craft with it.

## The traps that already caught us (2026-07-18)

| Someone says | Internal ID | Trap |
|---|---|---|
| "Ingot" (the base one) | `CopperIngot` | **NOT `IronIngot`**: that one displays as *"Refined Ingot"*, the tier ABOVE. Grabbing the obvious-looking ID gives the wrong tier. |
| "Circuit Board" | `MachineParts2` | The ID contains no form of "circuit" or "board". Searching IDs finds nothing and you conclude, wrongly, that the item does not exist. |
| "High Quality Pal Oil" | `PalOil` | The ID drops the qualifier entirely. There is no separate low-quality oil. |
| "Hyper Sphere" | `PalSphere_Tera` | Tiers are Pal / Mega / Giga / **Tera=Hyper** / Master=Ultra. The ID ladder and the display ladder use different words at the same rank. |
| "Flame Organ" | `FireOrgan` | Flame vs Fire. |
| "Water organ" | *does not exist* | Palworld has exactly three organs: Electric, Flame, Ice. A confident-sounding request can still name something that was never in the game. |
| "Medical Supplies" | `Medicines` | And *"Low Grade Medical Supplies"* is `Herbs`, and the word "medicine" appears in neither ID. |

## How to look something up

Always search the **display_name** column, never guess at IDs:

```bash
grep -i 'circuit' reference/palworld-item-ids.tsv
grep -iP '^\s*Ingot\t' reference/palworld-item-ids.tsv    # exact display name
```

If a search of the item IDs finds nothing, that means nothing: check the names
before concluding an item is absent.

## Regenerating

Sourced from the Palworld Save Pal repo's bundled game data
(`~/Developer/palworld-save-pal/data/json/`), which ships `items.json` plus
`l10n/en/items.json`. Regenerate after a game update:

```bash
cd ~/Developer/palworld-save-pal && git pull
# then re-run the generator (see the palworld-server session notes / AIDB)
```

The same name-vs-ID split applies to Pals (`pals.json` + `l10n/en/pals.json`), so
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

sha256 `7c2efee4dcefdf50be7b68a683ebe25178846cfa7324762decd6d0caaddd5ad9`, verified
on the live box and required verbatim by `scripts/deploy-autohatch.ps1 -ExpectedSha256`.

Every change is a guard or a breadcrumb; no gameplay logic is altered. The substantive one
is in the `OnCompleteInitializeParameter` hook: stock compares against a module-level
`playerState` holding a raw pointer to the last `PalPlayerState` created **server-wide**,
which dangles as soon as that player disconnects and is simply wrong with two players
online. It now takes the state from the character's own controller, which cannot be stale.
The rest guards each dereference, fixes `SenderPlayerUId` casing (stock reads a lower-case
name that does not exist, so `!autohatch on/off` never worked), and traces hook entry so
the last `[AutoHatch/guard]` line in `UE4SS.log` names whatever was running if it crashes
again.

### Who an auto-hatched Pal belongs to

Palworld assigns no owner to an egg laid in a Breeding Farm. The mod invents one, and the
author's FAQ explains how: it takes the owner of the Pal in the **first position** of the
Breeding Farm, saves that player ID when the egg is laid, and delivers to it at hatch time.
Every ownership failure we have seen follows from that one rule.

- **Put a regular Pal owned by the intended recipient in slot 1.** A Global Palbox Pal there
  is a documented known issue: the eggs simply do not auto-hatch.
- **Keep Palbox space free.** On a full Palbox, the mod drops the Pal on the ground. The
  author states outright that he cannot detect a full Palbox, so nothing warns you.
- **Everyone's eggs landing on one player is an open upstream bug**, reported as "All Guild
  Members eggs are hatching to me" and independently described as the first person to breed
  after a server start collecting everyone's Pals. Our own logs show 35 hatches addressed to
  a single UId, matching that pattern.

Before concluding a Pal was destroyed, check the first breeder's Palbox and the ground around
the incubators. Both are ordinary outcomes of the rule above.

### The `sentBytes` latch: tested, and it wedges the server

Stock returns early from the hatch hook after the first hatch of a server's lifetime, so the
blueprint receives one character archive per server start and none after.
`SEND_BYTES_EVERY_HATCH` was set true on 2026-08-28 to test whether that latch was what made
every player's eggs route to one recipient. **It is now `false` and must stay there.**

The test failed twice over, and both results are worth keeping.

It did not fix the routing. Every one of the 24 hatches that ran under the flag logged
`hatch:recipient 0`, and the mod's own line read
`Sending Pals to: 084390E6000000000000000000000000 (Player ID: 0)`. One recipient, exactly as
before. The routing decision lives entirely in the compiled blueprint, so the Lua cannot
reach it.

It also wedged the live server. The archive handed to the hook doubled on every hatch, and
because the send loop makes one `GetBytes` call per byte, so did the work:

| Hatch | Bytes sent | Wall time |
|---|---|---|
| 21 | 6,881,280 | baseline |
| 22 | 13,762,560 | 99s |
| 23 | 27,525,120 | 199s |
| 24 | ~55,050,240 | never finished |

The game thread never returned from hatch 24. The process stayed alive at a full core with a
12.8 GB working set, so the REST API stopped answering, the roster publish froze, and the
watchdog stood down because it looks for a missing process and found a running one. No crash
dump was written, which is why this reads as a crash to a player and as healthy to every
automated check. Recovery was a force-kill plus this flag.

Why doubling: unproven, and the blueprint half is compiled, so it may stay that way. The
shape fits the blueprint accumulating each archive into a buffer that is then handed back as
the next hatch's archive. What is certain is the measurement above.

The hook now also logs the player id the game passed in and the egg object it came from. The
mod recorded neither, so misroutes previously had to be inferred from missing deliveries
instead of spotted in a log line.

That id is the blueprint's `RequestPlayerId`, which names who ASKED for the hatch, not who
the Pal was granted to. The two are the same for a normal hatch and diverge for exactly the
bug being chased, so reading it as the recipient hid the misroute in the one case that
mattered. Keep it and the observed destination container as separate signals.

Full analysis, test protocol and rollback:
`~/Developer/AIDB/_global/personal/palworld-server/2026-08-22-autohatch-crash-investigation.md`
