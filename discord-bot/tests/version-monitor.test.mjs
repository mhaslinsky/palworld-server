// Red/green harness for the version-monitor handler.
//
//   cd discord-bot && npm install && npm test
//
// Same standard as backup-monitor.test.mjs: every alarm is exercised in its FIRING
// state, not just its quiet one. This monitor is especially prone to the house bug,
// because its failure modes -- a Steam API outage, a reshaped payload, a build
// parameter nothing ever published -- all naturally produce "no difference found",
// which is one careless `??` away from being reported as "you are up to date".
//
// The SDK client is constructed at module load, so its prototype is patched before
// the handler is imported.

import {SSMClient} from "@aws-sdk/client-ssm";

const HOUR = 3_600_000;

let delivered = [];   // alerts ATTEMPTED, whether or not the POST succeeded
let statePut = null;  // the dedupe record the handler wrote, if any

function install({steamBuild = "24575149", installedBuild = "24575149",
                  steamStatus = 200, steamBody = undefined, steamThrows = false,
                  installedRaw = undefined, buildParamThrows = false,
                  state = {}, webhook = "https://discord.test/webhook",
                  failDelivery = false}) {
  delivered = [];
  statePut = null;

  SSMClient.prototype.send = async command => {
    const name = command.input.Name;
    if (command.constructor.name === "PutParameterCommand") {
      statePut = JSON.parse(command.input.Value);
      return {};
    }
    if (name === "/palworld-server/installed_build_windows") {
      if (buildParamThrows) throw new Error("ParameterNotFound");
      return {Parameter: {Value: installedRaw !== undefined
        ? installedRaw
        : JSON.stringify({buildid: installedBuild, updated: 1786000000})}};
    }
    if (name === "/palworld-server/version_monitor_state") {
      return {Parameter: {Value: JSON.stringify(state)}};
    }
    return {Parameter: {Value: webhook}};
  };

  global.fetch = async (url, options) => {
    if (String(url).includes("api.steamcmd.net")) {
      if (steamThrows) throw new Error("network unreachable");
      return {
        ok: steamStatus === 200,
        status: steamStatus,
        statusText: steamStatus === 200 ? "OK" : "Service Unavailable",
        json: async () => steamBody !== undefined ? steamBody : {
          data: {"2394010": {depots: {branches: {public: {
            buildid: steamBuild, timeupdated: Math.floor(Date.now() / 1000) - 7200,
          }}}}},
        },
      };
    }
    delivered.push(JSON.parse(options.body).content);
    if (failDelivery) return {ok: false, status: 429, statusText: "Too Many Requests"};
    return {ok: true, status: 200};
  };
}

process.env.WEBHOOK_PARAM = "/palworld-server/discord_webhook_url";
process.env.BUILD_PARAM = "/palworld-server/installed_build_windows";
process.env.STATE_PARAM = "/palworld-server/version_monitor_state";
process.env.STEAM_APP_ID = "2394010";
process.env.REMIND_HOURS = "12";

const {handler} = await import("../version-monitor/index.mjs");

let failures = 0;

async function scenario(name, config, expect) {
  install(config);
  let result;
  let threw = null;
  try {
    result = await handler();
  } catch (error) {
    threw = error;
  }
  if (expect.throws) {
    const passed = threw !== null;
    if (!passed) failures++;
    console.log(`${passed ? "PASS" : "FAIL"}  ${name}`);
    console.log(`      threw=${threw ? threw.message.slice(0, 80) : "NO -- delivery failure was swallowed"}`);
    return;
  }
  if (threw) {
    failures++;
    console.log(`FAIL  ${name}\n      unexpected throw: ${threw.message}`);
    return;
  }
  const alerted = delivered.length > 0;
  const passed = result.status === expect.status && alerted === expect.alerts;
  if (!passed) failures++;
  console.log(`${passed ? "PASS" : "FAIL"}  ${name}`);
  console.log(`      status=${result.status} (want ${expect.status})  alerts=${delivered.length} (want ${expect.alerts})`);
  for (const alert of delivered) console.log(`      -> ${alert.split("\n")[0].slice(0, 95)}`);
}

console.log("--- GREEN: a current server must stay quiet ---");
await scenario("installed build matches Steam", {}, {status: "OK", alerts: false});

console.log("\n--- RED: the 2026-08-12 incident must alert ---");
// The exact numbers from the night this was written: the box sat on 24466863 while
// Steam's public build was 24575149 for three hours, and the first signal was a
// player getting "version incompatible".
await scenario("server behind after a patch",
  {steamBuild: "24575149", installedBuild: "24466863"},
  {status: "BEHIND", alerts: true});

console.log("\n--- RED: a check that CANNOT run must never read as all-clear ---");
// Each of these produces "no difference found" internally. Every one must alert.
await scenario("steam API unreachable", {steamThrows: true}, {status: "UNKNOWN", alerts: true});
await scenario("steam API 503", {steamStatus: 503}, {status: "UNKNOWN", alerts: true});
// A 200 whose shape changed, or the {"status":"error"} an unknown appid returns.
// Without the explicit buildid check this compares undefined against a real build.
await scenario("steam API returns 200 with no buildid",
  {steamBody: {status: "error"}}, {status: "UNKNOWN", alerts: true});
await scenario("build parameter unreadable", {buildParamThrows: true}, {status: "UNKNOWN", alerts: true});
await scenario("build parameter is not JSON", {installedRaw: "not json"}, {status: "UNKNOWN", alerts: true});
// The terraform sentinel. Must be NO_DATA, not a comparison against literal 0 --
// which would report the server as 24 million builds behind on every fresh deploy.
await scenario("nothing has published a build yet",
  {installedRaw: JSON.stringify({buildid: "0", updated: 0})},
  {status: "NO_DATA", alerts: true});
await scenario("build parameter unset (literal None)",
  {installedRaw: "None"}, {status: "NO_DATA", alerts: true});

console.log("\n--- RED: box ahead of Steam is a mismatch, not a pass ---");
await scenario("installed build newer than Steam's public build",
  {steamBuild: "24466863", installedBuild: "24575149"},
  {status: "AHEAD", alerts: true});

console.log("\n--- Dedupe: pace the nag without ever silencing a NEW situation ---");
await scenario("same drift already reported 1h ago",
  {steamBuild: "24575149", installedBuild: "24466863",
   state: {key: "behind:24575149:24466863", alertedAt: Date.now() - 1 * HOUR}},
  {status: "BEHIND", alerts: false});
await scenario("same drift reported 13h ago -- past REMIND_HOURS, nag again",
  {steamBuild: "24575149", installedBuild: "24466863",
   state: {key: "behind:24575149:24466863", alertedAt: Date.now() - 13 * HOUR}},
  {status: "BEHIND", alerts: true});
// A second patch on top of an unacknowledged one is a NEW situation. Keying the
// dedupe on the build pair rather than on "am I behind" is what makes this fire.
await scenario("a NEWER patch lands while already behind",
  {steamBuild: "24600000", installedBuild: "24466863",
   state: {key: "behind:24575149:24466863", alertedAt: Date.now() - 1 * HOUR}},
  {status: "BEHIND", alerts: true});
// Corrupt dedupe state must not suppress an alert. Losing the record costs one
// duplicate message; honouring it costs the alert itself.
await scenario("dedupe record is corrupt",
  {steamBuild: "24575149", installedBuild: "24466863", state: "not an object"},
  {status: "BEHIND", alerts: true});

console.log("\n--- Dedupe must RESET on recovery, or the next patch is swallowed ---");
install({});
await handler();
if (statePut && String(statePut.key).startsWith("ok:")) {
  console.log("PASS  a matching build clears the dedupe key");
} else {
  console.log(`FAIL  expected an ok: dedupe key after recovery, got ${JSON.stringify(statePut)}`);
  failures++;
}

console.log("\n--- RED: an undeliverable alert must FAIL the invocation ---");
// The whole point of the CloudWatch alarm. If notify() swallowed a 429, the monitor
// would detect a patch, tell nobody, and report success.
await scenario("webhook returns 429 while behind",
  {steamBuild: "24575149", installedBuild: "24466863", failDelivery: true},
  {throws: true});
await scenario("webhook parameter unset while behind",
  {steamBuild: "24575149", installedBuild: "24466863", webhook: "None"},
  {throws: true});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
