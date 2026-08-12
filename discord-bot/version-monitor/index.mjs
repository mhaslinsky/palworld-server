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
// Instance state is read, but only to judge the PUBLISHER, never to decide whether to
// check. The box stops itself when empty, so it is stopped most of the time, and a
// patch that lands while it sleeps is still the thing you want to know about before
// you next start it -- so the comparison itself uses the last published build and
// works fine on a sleeping box.
//
// What instance state buys is the one hole the comparison cannot see on its own: the
// installed build is whatever the on-box watcher last wrote, so if that watcher dies,
// loses its IAM, or starts writing to a different parameter, the value FREEZES and the
// monitor keeps reporting OK against a build the box may no longer run. That is this
// repo's house bug wearing the monitor's own clothes, and it is the same failure shape
// as 2026-07-19, where a dead timer was invisible until a human went looking. A frozen
// value is indistinguishable from a correct one by content alone; only its AGE gives it
// away, and age is only meaningful while the box is actually running. Hence: freshness
// is enforced when running and past boot grace, and ignored entirely when stopped.
//
// States, never collapsed into "fine":
//   OK        - Steam's public build matches what is installed
//   BEHIND    - Steam is ahead of the box                          -> alert
//   AHEAD     - the box is ahead of Steam's published build        -> alert
//   NO_DATA   - nothing usable has been published, OR the publisher
//               has gone silent on a running box                   -> alert
//   UNKNOWN   - the check itself could not run                     -> alert, because a
//               check that did not run has NOT cleared anything

import {SSMClient, GetParameterCommand, PutParameterCommand} from "@aws-sdk/client-ssm";
import {EC2Client, DescribeInstancesCommand} from "@aws-sdk/client-ec2";

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
const INSTANCE_ID = process.env.INSTANCE_ID;
// Sized by how long an UPDATE runs, not by the ~2 min publish interval:
// update-server.ps1 disables PalworldIdle for the duration, so the parameter
// legitimately goes unwritten that whole time. Do not lower it toward the interval.
const PUBLISH_STALE_MINUTES = numberSetting(process.env.PUBLISH_STALE_MINUTES, 45);
// A cold boot runs SteamCMD and the scheduled task has not necessarily fired yet, so
// without this every single start would raise a false "publisher is dead". Matches
// backup-monitor's grace, and for the same reason.
const BOOT_GRACE_MINUTES = numberSetting(process.env.BOOT_GRACE_MINUTES, 20);

const ssm = new SSMClient({region: REGION});
const ec2 = new EC2Client({region: REGION});

/**
 * An error carrying a COARSE failure class for dedupe.
 *
 * The UNKNOWN dedupe key used to be the raw `error.message`. Stable messages
 * ("steam API returned 503") re-nag on the intended 12h cadence, but an unstable one
 * (a timeout carrying a duration, an SDK message carrying a request id) mints a new
 * key on every run and alerts every 30 minutes all night. That is the opposite
 * failure from silencing and it ends the same way: the channel gets muted, and then
 * a real alert is missed. Key on the class, keep the full message in the alert body.
 */
function classifiedError(kind, message) {
  const error = new Error(message);
  error.kind = kind;
  return error;
}

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
    // Bounded like the Steam call. A hung webhook would otherwise burn the whole
    // 30s Lambda timeout, which surfaces as a less legible failure than a timeout.
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
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
  let response;
  try {
    response = await fetch(`${STEAM_API}/${STEAM_APP_ID}`, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  } catch (error) {
    // Transport failures carry the most variable messages of any path here
    // (timeouts, DNS, resets), which is exactly why they need the coarse class.
    throw classifiedError("steam-transport", `steam API unreachable: ${error.message}`);
  }
  if (!response.ok) {
    throw classifiedError("steam-http", `steam API returned ${response.status} ${response.statusText}`);
  }
  const body = await response.json();
  const branch = body?.data?.[STEAM_APP_ID]?.depots?.branches?.public;
  const buildid = branch?.buildid;
  // The endpoint answers 200 with {"status":"error"} for an unknown appid, and a
  // reshaped payload would otherwise surface as undefined === undefined -> "match".
  if (!buildid) {
    throw classifiedError("steam-shape", `steam API response had no public buildid for app ${STEAM_APP_ID}`);
  }
  // Validate the SHAPE here, at the boundary, not at the comparison. A non-numeric
  // build id means the response is malformed, which is UNKNOWN - but the comparison
  // downstream would have to guess a direction for it, and guessing "behind" turns a
  // broken API into a confident "Palworld has an update" telling people to patch.
  if (!/^\d+$/.test(String(buildid))) {
    throw classifiedError("steam-shape", `steam API returned a non-numeric buildid (${JSON.stringify(buildid)}) for app ${STEAM_APP_ID}`);
  }
  // "0" is the installed side's no-data sentinel and it is equally not a build here,
  // but it is truthy AND matches \d+, so both guards above wave it through. A mirror
  // answering 0 on an error would then compare as a genuine build and fire a false
  // AHEAD alert telling everyone the server is ahead of Steam.
  if (String(buildid) === "0") {
    throw classifiedError("steam-shape", `steam API returned buildid 0 for app ${STEAM_APP_ID}, which is a sentinel rather than a build`);
  }
  return {buildid: String(buildid), updated: Number(branch?.timeupdated) || null};
}

/**
 * The build actually installed, as published by palworld-idle.ps1 every cycle.
 *
 * Always returns an object. `buildid` is null when nothing usable has been published,
 * with `reason` carrying the publisher's own explanation when it left one -- which
 * separates "never published" from "published a deliberate I-don't-know". A read
 * failure THROWS instead, because that is a fault in the check rather than a state
 * of the box, and the two want different messages.
 */
async function installedBuild() {
  if (!BUILD_PARAM) {
    throw classifiedError("build-config", "BUILD_PARAM not set - nothing to compare against");
  }
  let result;
  try {
    result = await ssm.send(new GetParameterCommand({Name: BUILD_PARAM}));
  } catch (error) {
    throw classifiedError("build-read", `could not read ${BUILD_PARAM}: ${error.message}`);
  }
  const raw = result.Parameter?.Value;
  // SSM's own LastModifiedDate, NOT the `updated` field inside the payload. The
  // payload's timestamp is written by the box, so a box with a stopped clock or a
  // publisher writing a canned value could hand us a fresh-looking lie. The server
  // side of the write is the one thing the publisher cannot forge.
  const publishedAt = result.Parameter?.LastModifiedDate
    ? new Date(result.Parameter.LastModifiedDate).getTime()
    : null;
  // An unset SSM parameter comes back as the literal string "None". Same shape as
  // every other no-data return, so the caller has exactly one thing to check.
  if (!raw || raw === "None") return {buildid: null, reason: null, publishedAt};
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw classifiedError("build-json", `${BUILD_PARAM} is not valid JSON: ${error.message}`);
  }
  // Same shape guard readState() has. `JSON.parse("null")` is valid and returns null,
  // and the property access below would throw a bare TypeError that surfaces to the
  // operator as an unexplained stack rather than as "the parameter is malformed".
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw classifiedError("build-shape", `${BUILD_PARAM} is not a JSON object (got ${JSON.stringify(parsed)})`);
  }
  // Terraform seeds the parameter with buildid "0" so the resource can exist before
  // the box has ever published. The on-box watcher publishes the SAME empty-ish
  // sentinel when it cannot read the appmanifest, rather than leaving the previous
  // build id stranded there. Both mean "nothing known about this box right now", and
  // treating either as a real build would report the server as astronomically behind
  // or, worse, silently OK against a build it no longer runs.
  // The publisher attaches `error` when it had to clear the value because it could
  // not read the appmanifest. Carrying it out means the NO_DATA alert can say what
  // actually happened instead of "nothing has ever published", which would be a
  // plainly false statement about a box that published a deliberate I-don't-know.
  if (!parsed.buildid || parsed.buildid === "0") {
    return {buildid: null, reason: typeof parsed.error === "string" ? parsed.error : null, publishedAt};
  }
  // Same boundary validation as the Steam side. The publisher extracts \d+ from the
  // manifest, so anything else here means the parameter was written by something
  // else, and a bad value must not be handed to a comparison that assumes a number.
  if (!/^\d+$/.test(String(parsed.buildid))) {
    throw classifiedError("build-shape", `${BUILD_PARAM} has a non-numeric buildid (${JSON.stringify(parsed.buildid)})`);
  }
  return {buildid: String(parsed.buildid), updated: Number(parsed.updated) || null, publishedAt};
}

/**
 * Is the on-box publisher still writing?
 *
 * Returns null when the question does not apply -- no instance configured, the box is
 * not running, or it is still inside its boot grace -- which the caller must treat as
 * "not checked", never as "publisher healthy". A stale parameter on a STOPPED box is
 * correct and expected: the box sleeps most of the time and the last known build is
 * still the right thing to compare against.
 *
 * A lookup failure THROWS, because a freshness check that could not run has not
 * established freshness, and this whole function exists to stop a frozen value from
 * being read as a live one.
 */
async function publisherSilence(publishedAt, nowMs) {
  // Fail CLOSED, exactly as BUILD_PARAM does. Returning null here would mean an env
  // typo or a partial deploy silently disables the only defence against a frozen
  // parameter reporting OK forever -- absence of the signal becoming a pass, which is
  // the bug this whole function exists to close, one level up.
  if (!INSTANCE_ID) {
    throw classifiedError("instance-config", "INSTANCE_ID not set - publisher freshness cannot be judged");
  }
  let instance;
  try {
    const result = await ec2.send(new DescribeInstancesCommand({InstanceIds: [INSTANCE_ID]}));
    instance = result.Reservations?.[0]?.Instances?.[0];
  } catch (error) {
    throw classifiedError("instance-state", `could not read the state of ${INSTANCE_ID}: ${error.message}`);
  }
  // No instance in the response is NOT "the box is asleep". It means the configured
  // INSTANCE_ID does not resolve -- a rebuild, a wrong id, a stale terraform output --
  // and silently skipping the freshness check there would let a stale build report OK
  // for exactly as long as the misconfiguration lasts.
  if (!instance) {
    throw classifiedError("instance-missing", `${INSTANCE_ID} matched no instance, so publisher freshness cannot be judged`);
  }
  const state = instance.State?.Name;
  // Only these are a normal sleep cycle. `terminated` and `shutting-down` are not:
  // the box this monitor describes is going away, and reporting OK about its build
  // would be describing a machine that no longer exists.
  if (state === "stopped" || state === "stopping" || state === "pending") return null;
  if (state !== "running") {
    throw classifiedError("instance-state", `${INSTANCE_ID} is ${state || "in an unknown state"}, so publisher freshness cannot be judged`);
  }

  // LaunchTime is the right clock: a stop/start refreshes it so a cold boot gets its
  // full grace, while an in-place reboot does not -- and a reboot killing the
  // scheduled task is exactly the 2026-07-19 failure this must still catch.
  const launchTime = instance.LaunchTime ? new Date(instance.LaunchTime).getTime() : null;
  const upMinutes = launchTime === null ? null : (nowMs - launchTime) / 60000;
  if (upMinutes !== null && upMinutes < BOOT_GRACE_MINUTES) return null;

  // Never published at all, on a box that has been up past its grace, is itself the
  // publisher being silent -- not an absence of evidence.
  if (publishedAt === null) {
    return {ageMinutes: null, upMinutes};
  }
  const ageMinutes = (nowMs - publishedAt) / 60000;
  if (ageMinutes <= PUBLISH_STALE_MINUTES) return null;
  return {ageMinutes, upMinutes};
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
  let silence;
  try {
    // Sequential on purpose: the Steam call is the one that fails, and there is no
    // point reading SSM to compare against a number we do not have.
    steam = await steamBuild();
    installed = await installedBuild();
    // Before ANY comparison, because a frozen parameter compares perfectly well and
    // that is the entire problem. Running this after the equality check would mean
    // the false OK had already been returned.
    silence = await publisherSilence(installed.publishedAt, nowMs);
  } catch (error) {
    // The coarse class, never the raw message: an unstable message would mint a new
    // dedupe key every run and alert every 30 minutes. `other` covers anything thrown
    // without a class, which is the conservative direction (it groups rather than
    // splits, so the worst case is one missed distinction, not a night of spam).
    const key = `unknown:${error.kind || "other"}`;
    const state = await readState();
    if (!alreadyReported(state, key, nowMs)) {
      await notify(`:warning: **Palworld version check could not run** - ${error.message}. This is the check itself failing, so it has NOT confirmed the server is current.`);
      await writeState({key, alertedAt: nowMs});
    }
    return {status: "UNKNOWN", reason: error.message};
  }

  // Ordered ahead of the no-data branch on purpose: a silent publisher on a running
  // box is a more specific and more actionable statement than "no build published",
  // and it is the only branch that can explain a value that LOOKS fine.
  if (silence) {
    const key = "publisher-silent";
    const state = await readState();
    if (!alreadyReported(state, key, nowMs)) {
      const age = silence.ageMinutes === null
        ? "has never been written"
        : `has not been written in ${Math.round(silence.ageMinutes)} min (threshold ${PUBLISH_STALE_MINUTES} min)`;
      await notify(`:rotating_light: **Palworld version check cannot trust the installed build** - the server has been up ${Math.round(silence.upMinutes ?? 0)} min but \`${BUILD_PARAM}\` ${age}. The on-box publisher writes it every ~2 min, so it has stopped: check the \`PalworldIdle\` scheduled task and the instance role's \`ssm:PutParameter\` grant. Until it resumes, any build shown here is FROZEN and a matching build does NOT mean the server is current.`);
      await writeState({key, alertedAt: nowMs});
    }
    return {status: "NO_DATA", reason: "publisher silent", steam: steam.buildid, installed: installed.buildid};
  }

  if (!installed.buildid) {
    // Two different situations, and saying the wrong one sends the reader to the
    // wrong place. No reason = nothing ever wrote the parameter, which a normal boot
    // fixes. A reason = the publisher ran, could not read the appmanifest, and
    // deliberately cleared the value, which means the INSTALL is suspect, not the
    // publisher. The old text asserted "has never been published" for both.
    const key = installed.reason ? "no-data-cleared" : "no-data-never";
    const state = await readState();
    if (!alreadyReported(state, key, nowMs)) {
      const message = installed.reason
        ? `:warning: **Palworld version check has no usable installed build** - the on-box watcher cleared \`${BUILD_PARAM}\` because it could not read the build manifest (${installed.reason}). The install itself is suspect: check that SteamCMD finished and that \`C:\\PalServer\\steamapps\` is intact.`
        : `:warning: **Palworld version check has no installed build to compare against** - \`${BUILD_PARAM}\` has never been published. The on-box watcher writes it every cycle, so this clears itself once the box next runs; if it persists, \`PalworldIdle\` is not publishing.`;
      await notify(message);
      await writeState({key, alertedAt: nowMs});
    }
    return {status: "NO_DATA", steam: steam.buildid, reason: installed.reason};
  }

  if (steam.buildid === installed.buildid) {
    console.log(`OK - installed ${installed.buildid} matches Steam public build`);
    // Clear the dedupe record so the NEXT patch alerts immediately rather than being
    // suppressed by a stale key from the last one. Read first and write only on a
    // CHANGE: an unconditional write is a PutParameter every 30 minutes forever,
    // rewriting the same value and churning a new parameter version each time.
    if (STATE_PARAM) {
      const state = await readState();
      const key = `ok:${steam.buildid}`;
      if (state.key !== key) await writeState({key, alertedAt: nowMs});
    }
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
