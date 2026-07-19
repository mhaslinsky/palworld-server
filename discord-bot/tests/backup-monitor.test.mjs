// Red/green harness for the backup-monitor handler.
//
//   cd discord-bot && npm install && npm test
//
// The point is not coverage. It is that this repo has twice shipped a guard that
// could not fail -- a roster publish inside a bare try/catch, a shutdown branch
// that matched no condition -- so every alarm here is exercised in its FIRING
// state, not just its quiet one. A guard nobody has watched bite is decoration.
//
// The SDK clients are constructed at module load, so their prototypes are patched
// before the handler is imported.

import {EC2Client} from "@aws-sdk/client-ec2";
import {S3Client} from "@aws-sdk/client-s3";
import {SSMClient} from "@aws-sdk/client-ssm";

const MINUTE = 60_000;
const ago = minutes => new Date(Date.now() - minutes * MINUTE);

let delivered = [];

function install({state = "running", upMinutes = 600, backupAgeMinutes = 5,
                  backupSize = 3_000_000, rosterAgeMinutes = 2, objects = true}) {
  delivered = [];

  EC2Client.prototype.send = async () => ({
    Reservations: [{Instances: [{State: {Name: state}, LaunchTime: ago(upMinutes)}]}],
  });

  S3Client.prototype.send = async () => ({
    Contents: objects
      ? [{Key: "world/linux/latest.tgz", LastModified: ago(backupAgeMinutes), Size: backupSize}]
      : [],
    IsTruncated: false,
  });

  SSMClient.prototype.send = async command => {
    if (command.input.Name === "/palworld-server/roster") {
      return {Parameter: {Value: "{}", LastModifiedDate: ago(rosterAgeMinutes)}};
    }
    return {Parameter: {Value: "https://discord.test/webhook"}};
  };

  global.fetch = async (_url, options) => {
    delivered.push(JSON.parse(options.body).content);
    return {ok: true, status: 200};
  };
}

process.env.INSTANCE_ID = "i-test";
process.env.BACKUP_BUCKET = "test-bucket";
process.env.WEBHOOK_PARAM = "/palworld-server/discord_webhook_url";
process.env.ROSTER_PARAM = "/palworld-server/roster";
process.env.ROSTER_STALE_MINUTES = "10";
process.env.BOOT_GRACE_MINUTES = "20";
process.env.STALE_MINUTES = "45";
process.env.MIN_BYTES = "1000000";

const {handler} = await import("../backup-monitor/index.mjs");

let failures = 0;

async function scenario(name, config, expect) {
  install(config);
  const result = await handler();
  const alerted = delivered.length > 0;
  const passed = result.status === expect.status && alerted === expect.alerts;
  if (!passed) failures++;
  console.log(`${passed ? "PASS" : "FAIL"}  ${name}`);
  console.log(`      status=${result.status} (want ${expect.status})  alerts=${delivered.length}`);
  for (const alert of delivered) console.log(`      -> ${alert.slice(0, 95)}`);
}

console.log("--- GREEN: a healthy system must stay quiet ---");
await scenario("everything healthy", {}, {status: "OK", alerts: false});
await scenario("instance stopped", {state: "stopped"}, {status: "SLEEPING", alerts: false});
// A cold boot runs SteamCMD before the REST API answers, so the watcher publishes
// nothing for several minutes. Alerting here would fire on every normal start.
await scenario("roster stale but still inside boot grace",
  {upMinutes: 5, rosterAgeMinutes: 5}, {status: "OK", alerts: false});

console.log("\n--- RED: every fault must produce an alert ---");
// The 2026-07-19 failure: palworld-idle.timer was started but never enabled, a
// reboot killed it, and the box ran ~16h with no idle shutdown. The roster going
// stale was the only external symptom.
await scenario("idle watcher dead",
  {rosterAgeMinutes: 940, upMinutes: 960}, {status: "WATCHER_DEAD", alerts: true});
await scenario("backups stopped", {backupAgeMinutes: 120}, {status: "STALE", alerts: true});
await scenario("undersized backup", {backupSize: 1000}, {status: "STALE", alerts: true});
await scenario("no backups at all", {objects: false}, {status: "STALE", alerts: true});

console.log("\n--- RED: both broken at once must report BOTH ---");
// Regression guard: an earlier shape delivered alerts as each check ran, and
// notify() throws on a failed delivery by design -- so a failed backup alert
// skipped the watcher check entirely and hid a dead watcher behind a stale backup.
await scenario("backups stale AND watcher dead",
  {backupAgeMinutes: 120, rosterAgeMinutes: 940}, {status: "WATCHER_DEAD", alerts: true});
if (delivered.length !== 2) {
  console.log(`FAIL  expected 2 alerts, got ${delivered.length} — one fault masked the other`);
  failures++;
} else {
  console.log("PASS  both faults alerted independently");
}

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
