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

A hardened `AutoHatch\Scripts\main.lua` for Nexus mod 1959 v0.9.9.6. **This is no longer
the file the server runs.** `scripts/deploy-autohatch.ps1` now deploys
`AutoHatchFix-main.lua` instead (see "Building a replacement mod" below); on this server
the original mod's pak stays enabled as machinery AutoHatchFix drives, and this Lua stays
disabled. Kept here as the hardened reference copy the replacement was built from.

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

`deploy-autohatch.ps1 -ExpectedSha256` refuses to install whatever it fetched unless the
hash matches exactly, so do not hardcode one here to go stale again: derive it fresh from
the committed file before every deploy.

```bash
shasum -a 256 reference/AutoHatchFix-main.lua
```

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
- **Everyone's eggs landing on one player is not a misroute. It is one auto-hatch context
  collecting for everybody.** Settled 2026-08-29 by the control that had never been run:
  with player A logged fully OUT, player B's eggs deliver to B correctly and **do not
  auto-hatch at all**. With both online, B's incubators auto-hatch and the Pals go to A.

  So nothing is addressed to the wrong person. The mod sweeps every incubator under one
  global `UseAutoHatch` bool and performs each collection through a single player's context,
  which makes B's eggs arrive as though A had walked up and collected them. That accounts
  for every symptom at once: "first to hatch after a restart captures everything", the
  reproduction in both directions, and B's base auto-hatching only while A is connected.

  The mod's own bookkeeping is correct throughout, which is why four rounds of fixes aimed
  at it changed nothing:

  - `PlayerEggIncubators` attributes each incubator to its true owner (two to `084390E6`,
    six to `5C104B96`).
  - The hatch hook receives a correct, CHANGING `RequestPlayerId`: 256 for A's hatches and
    257 for B's.
  - `GameState.PlayerArray` maps `256 -> 084390E6` and `257 -> 5C104B96`, two distinct
    states, no duplicates.
  - The mod's own line reads `Owner PlayerUId: 5C104B96... Sending Pals to: 5C104B96...`

  `PlayerSettings`, the per-player map that `!autohatch on/off` writes, is EMPTY at hatch
  time while the global `UseAutoHatch` reads true. The per-player switch is not what gates
  the sweep.

Before concluding a Pal was destroyed, check the first breeder's Palbox and the ground around
the incubators. Both are ordinary outcomes.

The earlier reading of the same symptom, that the mod invents the wrong owner from Breeding
Farm slot 1, is superseded for the AUTO-HATCH path. The slot-1 rule still governs which eggs
the mod picks up, so slot 1 still matters; it is simply not what decides delivery.

**Workaround, reliable and free:** whoever wants the Pals should be the one hatching, and the
other player should be logged out, or should accept that everything lands with whoever the
active context belongs to. A player alone on the server always receives his own Pals.

**Why the Lua cannot fix it.** The decision is compiled inline. With the whole path
instrumented and every hook line tagged by caller, the only blueprint-sourced call during a
hatch is `ExecuteUbergraph_ModActor` (entry points 37358 on every hatch, 36895 on some).
`AutoHatch`, `GivePlayerID`, `FindBreedFarmBelongTo`, `AutoPickUpEgg`, `EggCleanUp`,
`PickUpAllEggs`, `OnUpdateHatchedCharacterDelegate_Event` and
`PalCharacterContainerManager::TryGetContainer` all registered successfully and fired ZERO
times from the blueprint. There is no reflected call boundary between "the mod knows the
owner" and "the Pal is granted", so there is nothing for a Lua hook to intercept.

**Caller tagging is mandatory for any future probe here.** A UE4SS hook fires for ANY caller,
including this file's own probes. Untagged, the probe's synthetic calls come back through the
hook and read as the blueprint's behaviour. That produced two separate false clearances of
`GetLoggedInPlayerUId`. Tagged, the truth is stark: the blueprint never calls that function
during a hatch at all. Every `bp:` line now carries `src=probe` or `src=BLUEPRINT`.

### Replacing this mod with pure Lua: what is proven

The blueprint's routing cannot be intercepted, so the practical path is to stop using it.
Everything Auto Hatch does has a reflected equivalent, and the collection itself,
`ObtainHatchedCharacter_ServerInternal`, belongs to the GAME rather than the mod.

Proven on the live server 2026-08-29, via the manual `!hatchtest` command:

| Capability | Status |
|---|---|
| Enumerate every incubator in the world | **works**, `FindAllOf` returns 13, no join-time map |
| Resolve each one's owner, INCLUDING offline players | **works**, 29,237 of 29,237 map objects yield a builder |
| Group incubators by base camp | **works**, `GetBaseCampIdBelongTo()` |
| Detect a ready egg | **works**, `GetWorkProgress(slot)` non-nil plus `IsCompleted()` |
| Deliver to the named owner | **DOES NOT WORK. This closes the rewrite.** |

**The delivery call cannot be driven from Lua, and that is what ends this idea.** Measured
2026-08-29 under the best possible conditions: the tester's OWN incubator, ten COMPLETED
eggs, addressed to his own live `PlayerId` while connected. Three reflected entry points,
each measured by counting occupied slots either side of the call:

| Call | Result |
|---|---|
| `ObtainHatchedCharacter_ServerInternal(PlayerId, Archive)` | `call_ok=true`, `CONSUMED=false` |
| `RequestObtainSingleHatchedCharacter(SlotIndex)` | `CONSUMED=false` |
| `RequestObtainAllHatchedCharacter()` | `CONSUMED=false` |

`occupied BEFORE = 10`, `occupied AFTER = 10`, nothing on the ground, nothing in the party,
nothing in the Palbox. The likely reason is that `RequestObtain*` are client-originated RPCs
that must come from the owning player's controller, and `_ServerInternal` is the inner half
of that same flow, so calling either on the server-side model object skips the context that
makes them act.

**`call_ok=true` proved worthless three separate times here.** It is the return of a `pcall`,
so it reports only that the invocation did not throw. The ONLY evidence a hatch occurred is a
slot that emptied, which is why the probe counts occupied slots before and after. Any future
attempt at this must measure world state, never a return value.

**Ownership is a two-step join, and the first step is the one that catches people.** An egg
is a CONCRETE model (`UPalMapObjectConcreteModelBase` -> `...HatchingEggModelBase` ->
`...MultiHatchingEggModel`), while `BuildPlayerUId` is declared on `UPalMapObjectModel`, a
different object. Reading `BuildPlayerUId` off the egg returns a `TrivialObject`, which is
NOT a missing value: UE4SS answers any unknown name that way, so a wrong-object read looks
exactly like an unreadable field. Join with `egg:GetModelInstanceId()` against the map
object's `InstanceId`, then read `BuildPlayerUId` there.

This resolves owners for players who have never connected this server lifetime, which is
precisely what the mod's `PlayerEggIncubators` cannot do: that map is filled at player JOIN,
so an offline owner has no entry and his eggs are invisible to the sweep. That is the
mechanism behind "his eggs stop auto-hatching when he logs off".

**`IsWorkable` returned false on all 13 incubators**, including ones that had been
auto-hatching an hour earlier, so it reports whether the structure is operable rather than
whether an egg is ready. Use `GetWorkProgress(SlotIndex)` or `GetPalEggRankInfo(SlotIndex,
Out)` on `UPalMapObjectHatchingEggModelBase` instead.

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

## Building a replacement mod: the toolchain, and where a human is still required

The replacement is a LogicMod: a Blueprint `ModActor` in a pak, plus a Lua bridge. Build scripts
live in `reference/modkit/`, and `reference/AutoHatchFix-main.lua` is the Lua half.

### Build box

`ssh ascension-mdns` (Windows 11). The numeric aliases in `~/.ssh/config` all time out from the
Mac because a mesh VPN fragments `10.0.0.0/24` onto the tunnel; `ascension.local` resolves over
the mesh IPv6 and works. Do NOT diagnose with `ping`: the Windows profile is Public so ICMP is
dropped regardless of whether SSH is fine.

| Component | Where |
|---|---|
| Engine | `D:\Program Files\Epic Games\UE_5.1` (5.1.1, confirmed from `Build.version`) |
| Kit | `C:\Dev\PalworldModdingKit` |
| Wwise SDK | `D:\Audiokinetic\Wwise_2021.1.11.7933` |
| MSVC | 14.38.33130 **pinned**, alongside 14.44.35207 |

### Things that cost a build cycle each

**Pin MSVC 14.38.33130.** UE 5.1 rejects 14.44 outright with `Detected compiler newer than
Visual Studio 2022` and C4668 on `__has_feature`. The wiki's pin is not arbitrary.

**`setup.exe modify` returns 87 on this box**, with or without `--productId`/`--channelId`. Use
the `vs_BuildTools.exe` bootstrapper with the same `--add` arguments; it works first time.

**UnrealBuildTool needs .NET 6**, and `SwarmInterface` needs the .NET FRAMEWORK SDK. Different
things, both required; the box had neither.

**Omit `ToolchainVersion` from `BuildConfiguration.xml`.** The wiki includes it and UE 5.1's
schema rejects it as an invalid child of `WindowsPlatform`.

**Wwise is installed by hand, not by the Launcher's integrate button.** Unpack
`Unreal.5.0.tar.xz` from the offline installer bundle, copy the `Wwise` folder into `Plugins`,
build `Plugins\Wwise\ThirdParty` from the SDK's `Win32_vc170`, `x64_vc170` and `include`,
duplicate those as `vc160`, and patch `Wwise.uplugin` from `5.0.0` to `5.1`. Wwise cannot be
removed instead: the kit's own C++ uses `UAkAudioEvent` and `UPalAkComponent` throughout, and
the `Pal` module is what supplies the type definitions the mod needs.

**Never write a `.uproject` with `Set-Content -Encoding UTF8`.** PowerShell 5.1 adds a BOM and
the Wwise Launcher then rejects the file as "not a valid Unreal Engine project" while every
JSON parser still reads it happily. Use targeted text edits and `UTF8Encoding($false)`.

**`NiagaraUIRenderer` must be disabled** in `Pal.uproject`. Its DLL builds fine and then fails
to load (`GetLastError=4551`), which stops the editor before it reaches any script. Nothing in
this mod needs it.

### The one step that cannot be automated

Blueprint node and pin editing is C++ only in UE 5.1. `EdGraphPin` is not a reflected UObject,
and `K2Node_FunctionEntry.UserDefinedPins` is not a reflected property at all: reading it errors
"Failed to find property" rather than the "protected and cannot be read" that `FunctionReference`
on the same object gives, so it was never exposed rather than merely guarded.

So `build_modactor.py` creates the asset with an EMPTY `DoHatch` graph, and a human finishes it
in the editor on `/Game/Mods/AutoHatchFix/ModActor`:

1. Select the `DoHatch` entry node and add two inputs: `EggModel` (object reference, type
   `/Script/Pal.PalMapObjectHatchingEggModelBase`) and `PlayerId` (integer).
2. Drag from `EggModel`, add **Obtain Hatched Character (Server Internal)**, wire `EggModel` to
   its target pin and `PlayerId` to the int32 parameter.
3. Compile and save.

**Record whether that node exposes the `Archive` (`FPalNetArchive`) pin, and whether it can be
left unconnected.** The Lua attempt passed an empty table there and the call consumed nothing
while reporting success, so a correctly marshalled archive is a live candidate for why the
Blueprint route would work where Lua did not.

Verify with `verify_modactor.py` in a SEPARATE editor process. Checking inside the run that
created the asset proves only that objects are live in memory.
