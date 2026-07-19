// Read-only: load the save COPY and print who is in it, so compensation can be
// decided from real numbers instead of guesses. Writes nothing.
import {connect} from "./psp.mjs";

// NOTE: this is the path to Level.sav ITSELF, not its directory - the server
// calls .parent() on whatever it is given.
const SAVE_DIR = process.env.SAVE_DIR
  || "/private/tmp/claude-501/-Users-mhaslinsky-Developer/93249842-eeb7-4aff-b632-d0468e7a0fc9/scratchpad/compensation/savecopy/0/E02C5819443F44ED89133A6C03B43E25/Level.sav";

const client = await connect(process.env.VERBOSE === "1");

console.error(`loading ${SAVE_DIR} ...`);
await client.call(
  "select_save",
  {type: "steam", path: SAVE_DIR, local: true},
  ["loaded_save_files"],
  180000,
);
console.error("save loaded");

const players = await client.call("get_player_summaries", undefined, ["get_player_summaries", "players"], 120000);

// The shape varies by version; normalise whatever came back into rows.
const rows = Array.isArray(players) ? players : Object.values(players ?? {});
console.log(JSON.stringify(rows, null, 2));

client.close();
