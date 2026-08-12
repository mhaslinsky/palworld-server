// Off-box watcher for Palworld game updates.
//
// The failure this exists to prevent, observed 2026-08-12: Pocketpair shipped a
// patch at 03:01Z. Steam auto-updated every player's CLIENT on its next launch, the
// SERVER kept running the build it booted with, and the first anyone heard about it
// was a player getting "version incompatible" at 2am. Nothing in the system knew a
// patch existed. Diagnosis took a human plus a session; the signal itself is one
// unauthenticated HTTP call.
//
// Deliberately does NOT auto-update. update-server.ps1 argues the case in its own
// header and 2026-08-12 is the evidence: the base patch landed at 03:01Z and mod
// 1898's compatible build did not appear until 05:44Z. An unattended updater run in
// that window produces a joinable server with relaxed building silently broken --
// every check green, the thing people actually use dead. Alert; let a human choose.
//
// Deliberately does NOT key off instance state either, unlike backup-monitor. The box
// stops itself when empty, so it is stopped most of the time, and a patch that lands
// while it sleeps is still the thing you want to know about before you next start it.
// The installed build is read from an SSM parameter the on-box watcher publishes, so
// it survives the box being down.
//
// States, never collapsed into "fine":
//   OK        - Steam's public build matches what is installed
//   BEHIND    - Steam is ahead of the box                          -> alert
//   AHEAD     - the box is ahead of Steam's published build        -> alert
//   NO_DATA   - nothing has ever published an installed build      -> alert
//   UNKNOWN   - the check itself could not run                     -> alert, because a
//               check that did not run has NOT cleared anything

import {SSMClient, GetParameterCommand, PutParameterCommand} from "@aws-sdk/client-ssm";

const REGION = process.env.AWS_REGION || "us-east-1";
const WEBHOOK_PARAM = process.env.WEBHOOK_PARAM;
const BUILD_PARAM = process.env.BUILD_PARAM;
const STATE_PARAM = process.env.STATE_PARAM;
// Palworld's DEDICATED SERVER app. The client (1623730) is a separate app that
// updates on its own schedule; what decides whether the box is compatible is this one.
const STEAM_APP_ID = process.env.STEAM_APP_ID || "2394010";
const STEAM_API = process.env.STEAM_API || "https://api.steamcmd.net/v1/info";
const MOD_URL = process.env.MOD_URL || "https://www.nexusmods.com/palworld/mods/1898";

// Same guard as backup-monitor: Number("") is 0 and Number("soon") is NaN, and every
// comparison against NaN is false -- so one fat-fingered env var turns a reminder
// that should fire into one that never can.
function numberSetting(raw, fallback) {
  const parsed = Number(raw);
  if (raw === undefined || raw === null || raw === "" || !Number.isFinite(parsed)) return fallback;
  return parsed;
}

// While the box is behind, re-alert this often. Without it the monitor alerts once
// and then goes quiet for a build nobody acted on, which reads identically to "no
// problem". With it, an ignored patch keeps nagging on a cadence that is not spam.
const REMIND_HOURS = numberSetting(process.env.REMIND_HOURS, 12);
const FETCH_TIMEOUT_MS = numberSetting(process.env.FETCH_TIMEOUT_MS, 8000);

const ssm = new SSMClient({region: REGION});

/**
 * Deliver an alert. THROWS if it cannot, so the invocation fails and the CloudWatch
 * alarm fires over SNS -- a channel that does not depend on Discord being healthy.
 * notify() is only ever called when something is already wrong, so a quiet return
 * here would mean the monitor detected a fault and told nobody, successfully.
 */
async function notify(content) {
  if (!WEBHOOK_PARAM) {
    throw new Error(`WEBHOOK_PARAM not set - alert NOT delivered: ${content}`);
  }
  const result = await ssm.send(new GetParameterCommand({Name: WEBHOOK_PARAM, WithDecryption: true}));
  const url = result.Parameter?.Value;
  // An unset SSM parameter comes back as the literal string "None".
  if (!url || url === "None") {
    throw new Error(`no webhook configured at ${WEBHOOK_PARAM} - alert NOT delivered: ${content}`);
  }
  const response = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({content}),
  });
  // fetch() does not reject on 401/404/429/500, so the status must be checked.
  if (!response.ok) {
    throw new Error(`webhook returned ${response.status} ${response.statusText} - alert NOT delivered`);
  }
}

/**
 * Steam's current public-branch build for the app.
 *
 * api.steamcmd.net is a community mirror of `steamcmd +app_info_print`, chosen over
 * running steamcmd ourselves because the alternative is keeping a host alive purely
 * to ask one question. That makes it a third-party dependency on the critical path,
 * so every failure here becomes a loud UNKNOWN rather than a skipped check: an
 * outage must not read as "no patch available".
 */
async function steamBuild() {
  const response = await fetch(`${STEAM_API}/${STEAM_APP_ID}`, {
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`steam API returned ${response.status} ${response.statusText}`);
  }
  const body = await response.json();
  const branch = body?.data?.[STEAM_APP_ID]?.depots?.branches?.public;
  const buildid = branch?.buildid;
  // The endpoint answers 200 with {"status":"error"} for an unknown appid, and a
  // reshaped payload would otherwise surface as undefined === undefined -> "match".
  if (!buildid) {
    throw new Error(`steam API response had no public buildid for app ${STEAM_APP_ID}`);
  }
  // Validate the SHAPE here, at the boundary, not at the comparison. A non-numeric
  // build id means the response is malformed, which is UNKNOWN - but the comparison
  // downstream would have to guess a direction for it, and guessing "behind" turns a
  // broken API into a confident "Palworld has an update" telling people to patch.
  if (!/^\d+$/.test(String(buildid))) {
    throw new Error(`steam API returned a non-numeric buildid (${JSON.stringify(buildid)}) for app ${STEAM_APP_ID}`);
  }
  return {buildid: String(buildid), updated: Number(branch?.timeupdated) || null};
}

/**
 * The build actually installed, as published by palworld-idle.ps1 every cycle.
 * Returns null when nothing has published yet -- distinct from a read failure,
 * because the two want different messages and only one of them is a fault.
 */
async function installedBuild() {
  if (!BUILD_PARAM) {
    throw new Error("BUILD_PARAM not set - nothing to compare against");
  }
  const result = await ssm.send(new GetParameterCommand({Name: BUILD_PARAM}));
  const raw = result.Parameter?.Value;
  if (!raw || raw === "None") return null;
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`${BUILD_PARAM} is not valid JSON: ${error.message}`);
  }
  // Terraform seeds the parameter with buildid "0" so the resource can exist before
  // the box has ever published. The on-box watcher publishes the SAME empty-ish
  // sentinel when it cannot read the appmanifest, rather than leaving the previous
  // build id stranded there. Both mean "nothing known about this box right now", and
  // treating either as a real build would report the server as astronomically behind
  // or, worse, silently OK against a build it no longer runs.
  if (!parsed.buildid || parsed.buildid === "0") return null;
  // Same boundary validation as the Steam side. The publisher extracts \d+ from the
  // manifest, so anything else here means the parameter was written by something
  // else, and a bad value must not be handed to a comparison that assumes a number.
  if (!/^\d+$/.test(String(parsed.buildid))) {
    throw new Error(`${BUILD_PARAM} has a non-numeric buildid (${JSON.stringify(parsed.buildid)})`);
  }
  return {buildid: String(parsed.buildid), updated: Number(parsed.updated) || null};
}

/** Dedupe state, so a standing problem nags on a schedule instead of every run. */
async function readState() {
  if (!STATE_PARAM) return {};
  try {
    const result = await ssm.send(new GetParameterCommand({Name: STATE_PARAM}));
    const raw = result.Parameter?.Value;
    if (!raw || raw === "None") return {};
    const parsed = JSON.parse(raw);
    // `JSON.parse("null")` is valid JSON and returns null, which then throws on the
    // first property access in alreadyReported() - killing the invocation on the very
    // path that was about to deliver an alert. A string or array parses cleanly and
    // is equally not a dedupe record. Anything that is not a plain object is treated
    // as "no record", which is the conservative direction: it alerts.
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return parsed;
  } catch (error) {
    // A missing or corrupt dedupe record must not suppress the alert it is meant to
    // pace. Losing it costs one duplicate message; honouring it costs the alert.
    console.log(`dedupe state unreadable (${error.message}) - treating as first sighting`);
    return {};
  }
}

async function writeState(state) {
  if (!STATE_PARAM) return;
  await ssm.send(new PutParameterCommand({
    Name: STATE_PARAM,
    Type: "String",
    Overwrite: true,
    Value: JSON.stringify(state),
  }));
}

/**
 * Has this exact situation already been reported recently?
 * Keyed on the build PAIR: a newer upstream build, or an update that moved the box
 * to a different build while still behind, is a new situation and alerts immediately.
 */
function alreadyReported(state, key, nowMs) {
  if (state.key !== key) return false;
  const alertedAt = Number(state.alertedAt);
  if (!Number.isFinite(alertedAt)) return false;
  return nowMs - alertedAt < REMIND_HOURS * 3600 * 1000;
}

function agePhrase(epochSeconds, nowMs) {
  if (!epochSeconds) return "";
  const hours = (nowMs - epochSeconds * 1000) / 3600000;
  if (hours < 1) return " (published under an hour ago)";
  if (hours < 48) return ` (published ~${Math.round(hours)}h ago)`;
  return ` (published ~${Math.round(hours / 24)}d ago)`;
}

export const handler = async () => {
  const nowMs = Date.now();

  let steam;
  let installed;
  try {
    // Sequential on purpose: the Steam call is the one that fails, and there is no
    // point reading SSM to compare against a number we do not have.
    steam = await steamBuild();
    installed = await installedBuild();
  } catch (error) {
    const key = `unknown:${error.message}`;
    const state = await readState();
    if (!alreadyReported(state, key, nowMs)) {
      await notify(`:warning: **Palworld version check could not run** - ${error.message}. This is the check itself failing, so it has NOT confirmed the server is current.`);
      await writeState({key, alertedAt: nowMs});
    }
    return {status: "UNKNOWN", reason: error.message};
  }

  if (!installed) {
    const key = "no-data";
    const state = await readState();
    if (!alreadyReported(state, key, nowMs)) {
      await notify(`:warning: **Palworld version check has no installed build to compare against** - \`${BUILD_PARAM}\` has never been published. The on-box watcher writes it every cycle, so this clears itself once the box next runs; if it persists, \`PalworldIdle\` is not publishing.`);
      await writeState({key, alertedAt: nowMs});
    }
    return {status: "NO_DATA", steam: steam.buildid};
  }

  if (steam.buildid === installed.buildid) {
    console.log(`OK - installed ${installed.buildid} matches Steam public build`);
    // Clear the dedupe record so the NEXT patch alerts immediately rather than being
    // suppressed by a stale key from the last one.
    if (STATE_PARAM) await writeState({key: `ok:${steam.buildid}`, alertedAt: nowMs});
    return {status: "OK", build: steam.buildid};
  }

  // Both sides were validated as \d+ at their boundaries, so this is a plain numeric
  // compare with no fallback to guess about. Build ids are monotonic integers, and
  // they are already past the 2^53 mantissa question by six orders of magnitude short
  // of it, so Number is exact here.
  const behind = Number(steam.buildid) > Number(installed.buildid);

  const key = `${behind ? "behind" : "ahead"}:${steam.buildid}:${installed.buildid}`;
  const state = await readState();
  if (alreadyReported(state, key, nowMs)) {
    console.log(`${behind ? "BEHIND" : "AHEAD"} - already reported within ${REMIND_HOURS}h`);
    return {status: behind ? "BEHIND" : "AHEAD", steam: steam.buildid, installed: installed.buildid, reported: false};
  }

  const message = behind
    ? [
        `:rotating_light: **Palworld has an update** - the server is on build \`${installed.buildid}\`, Steam's public build is \`${steam.buildid}\`${agePhrase(steam.updated, nowMs)}.`,
        "Players whose Steam has already updated will get **version incompatible** and cannot join.",
        "Run `/palworld-update` to patch the server.",
        `Check <${MOD_URL}> for a matching mod 1898 build first - a base patch usually lands before the mod catches up, and \`mods:keep\` on a stale mod leaves building silently vanilla. If a new one is out, stage it and use \`mods:restage\`.`,
      ].join("\n")
    : `:warning: **Palworld version mismatch** - the server is on build \`${installed.buildid}\` but Steam's public build is \`${steam.buildid}\`, which is OLDER. Either Steam's API is lagging or the box is on a non-public branch. Worth a look before the next update.`;

  await notify(message);
  await writeState({key, alertedAt: nowMs});

  return {status: behind ? "BEHIND" : "AHEAD", steam: steam.buildid, installed: installed.buildid, reported: true};
};
