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
