// Verify the grant by RE-READING the save from disk. "update accepted" is not
// proof anything reached the file - the whole point of this session.
import {connect} from "./psp.mjs";

const LEVEL_SAV = process.env.SAVE_DIR
  || "/private/tmp/claude-501/-Users-mhaslinsky-Developer/93249842-eeb7-4aff-b632-d0468e7a0fc9/scratchpad/compensation/savecopy/0/E02C5819443F44ED89133A6C03B43E25/Level.sav";

const EXPECT = {
  "5c104b96-0000-0000-0000-000000000000": {
    name: "ボンガー",
    want: {PalOil: 300, ElectricOrgan: 300, FireOrgan: 300, IceOrgan: 300},
  },
  "084390e6-0000-0000-0000-000000000000": {
    name: "The Cerulean Stimmer",
    want: {
      PalOil: 300, ElectricOrgan: 300, FireOrgan: 300, IceOrgan: 300,
      CopperIngot: 300, Polymer: 300, MachineParts2: 300, Horn: 300, Bone: 300,
      PalSphere: 100, PalSphere_Mega: 106, PalSphere_Giga: 138, PalSphere_Tera: 120,
      Herbs: 300, Medicines: 300, LuxuryMedicines: 300,
      Potion_Low: 300, Potion: 300, Potion_High: 300, Potion_Extreme: 300,
    },
  },
};

const client = await connect(false);
await client.call("select_save", {type: "steam", path: LEVEL_SAV, local: true}, ["loaded_save_files"], 180000);
console.log(`reloaded from disk: ${LEVEL_SAV}\n`);

let failures = 0;
for (const [uid, expect] of Object.entries(EXPECT)) {
  const details = await client.call(
    "request_player_details", {player_id: uid},
    ["get_player_details_response", "player_details"], 120000,
  );
  const player = details?.player ?? details;
  const have = new Map();
  for (const slot of player.common_container.slots) {
    if (slot.static_id) have.set(slot.static_id, (have.get(slot.static_id) ?? 0) + slot.count);
  }
  console.log(`${expect.name} (level ${player.level}):`);
  for (const [staticId, wantCount] of Object.entries(expect.want)) {
    const actual = have.get(staticId) ?? 0;
    const ok = actual >= wantCount;
    if (!ok) failures += 1;
    console.log(`  ${ok ? "OK  " : "FAIL"} ${staticId.padEnd(18)} want>=${String(wantCount).padStart(4)}  have=${actual}`);
  }
  console.log("");
}

client.close();
if (failures) {
  console.log(`VERIFY FAILED: ${failures} item(s) missing or short`);
  process.exit(1);
}
console.log("VERIFY PASSED: every granted item is present on disk");
