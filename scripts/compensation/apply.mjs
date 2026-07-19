// Apply the compensation grant. Run with APPLY=1 to actually write.
//
// Item IDs come from DISPLAY NAMES via reference/palworld-item-ids.tsv - never
// guessed. "Ingot" is CopperIngot (IronIngot displays as "Refined Ingot"), and
// "Circuit Board" is MachineParts2, whose ID contains neither word.
//
// Container facts discovered from the real save, not assumed:
//   - `slot_num` is the capacity; `slots` lists ONLY occupied slots
//   - slot_index values can have gaps (a gap is an empty slot)
//   - a slot is {dynamic_item, slot_index, count, static_id, local_id}
import {connect} from "./psp.mjs";

const LEVEL_SAV = process.env.SAVE_DIR
  || "/private/tmp/claude-501/-Users-mhaslinsky-Developer/93249842-eeb7-4aff-b632-d0468e7a0fc9/scratchpad/compensation/savecopy/0/E02C5819443F44ED89133A6C03B43E25/Level.sav";
const APPLY = process.env.APPLY === "1";
const EMPTY_LOCAL_ID = "00000000-0000-0000-0000-000000000000";
const MAX_STACK = 9999;

const ORGANS_AND_OIL = [
  ["PalOil", 300],          // High Quality Pal Oil
  ["ElectricOrgan", 300],   // Electric Organ
  ["FireOrgan", 300],       // Flame Organ
  ["IceOrgan", 300],        // Ice Organ - substituted for the requested "water organ", which does not exist
];

const GRANTS = {
  "5c104b96-0000-0000-0000-000000000000": {name: "ボンガー", items: [...ORGANS_AND_OIL]},
  "084390e6-0000-0000-0000-000000000000": {
    name: "The Cerulean Stimmer",
    items: [
      ...ORGANS_AND_OIL,
      ["CopperIngot", 300],     // "Ingot" - BASE tier
      ["Polymer", 300],
      ["MachineParts2", 300],   // "Circuit Board"
      ["Horn", 300],
      ["Bone", 300],
      ["PalSphere", 100],
      ["PalSphere_Mega", 100],
      ["PalSphere_Giga", 100],
      ["PalSphere_Tera", 100],  // "Hyper Sphere"
      ["Herbs", 300],           // Low Grade Medical Supplies
      ["Medicines", 300],       // Medical Supplies
      ["LuxuryMedicines", 300], // High Grade Medical Supplies
      ["Potion_Low", 300],
      ["Potion", 300],
      ["Potion_High", 300],
      ["Potion_Extreme", 300],
    ],
  },
};

/** Add items to a container: top up an existing stack, else take a free slot. */
function grantInto(container, wanted, log) {
  const slots = container.slots;
  const capacity = container.slot_num;
  const used = new Set(slots.map((slot) => slot.slot_index));

  for (const [staticId, qty] of wanted) {
    const existing = slots.find((slot) => slot.static_id === staticId);
    if (existing) {
      const before = existing.count;
      existing.count = Math.min(MAX_STACK, existing.count + qty);
      log.push(`  ${staticId}: ${before} -> ${existing.count} (topped up existing stack)`);
      continue;
    }
    // Lowest unused index, including gaps left by removed items.
    let index = -1;
    for (let candidate = 0; candidate < capacity; candidate += 1) {
      if (!used.has(candidate)) { index = candidate; break; }
    }
    if (index === -1) {
      // Refuse rather than silently dropping part of the grant.
      throw new Error(`no free slot for ${staticId}: container ${container.id} is full (${slots.length}/${capacity})`);
    }
    used.add(index);
    slots.push({dynamic_item: null, slot_index: index, count: qty, static_id: staticId, local_id: EMPTY_LOCAL_ID});
    log.push(`  ${staticId}: new stack of ${qty} in slot ${index}`);
  }
  slots.sort((a, b) => a.slot_index - b.slot_index);
}

const client = await connect(process.env.VERBOSE === "1");
await client.call("select_save", {type: "steam", path: LEVEL_SAV, local: true}, ["loaded_save_files"], 180000);
console.error(`loaded ${LEVEL_SAV}`);
console.error(APPLY ? "MODE: APPLY (will write)\n" : "MODE: dry run\n");

const modifiedPlayers = {};

for (const [uid, grant] of Object.entries(GRANTS)) {
  const details = await client.call(
    "request_player_details", {player_id: uid},
    ["get_player_details_response", "player_details"], 120000,
  );
  const player = structuredClone(details?.player ?? details);
  const container = player.common_container;
  const free = container.slot_num - container.slots.length;
  console.error(`${grant.name}: level ${player.level}, inventory ${container.slots.length}/${container.slot_num} (${free} free), granting ${grant.items.length} entries`);

  const log = [];
  grantInto(container, grant.items, log);
  console.error(log.join("\n"));
  console.error("");

  modifiedPlayers[uid] = player;
}

if (!APPLY) {
  console.error("Dry run complete - nothing written. Re-run with APPLY=1.");
  client.close();
  process.exit(0);
}

await client.call("update_save_file", {modified_players: modifiedPlayers}, ["progress_message", "updated_save_file", "loaded_save_files"], 180000);
console.error("update_save_file accepted");

await client.call("save_modded_save", undefined, ["progress_message", "saved_modded_save", "loaded_save_files"], 300000);
console.error("save_modded_save issued");

// Give the writer a moment, then report what is on disk.
await new Promise((resolve) => setTimeout(resolve, 5000));
console.error("done");
client.close();
