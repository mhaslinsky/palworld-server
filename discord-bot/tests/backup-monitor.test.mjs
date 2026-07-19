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

let delivered = [];   // alerts ATTEMPTED, whether or not the POST succeeded

function install({state = "running", upMinutes = 600, backupAgeMinutes = 5,
                  backupSize = 3_000_000, rosterAgeMinutes = 2, objects = true,
                  failDeliveryNumber = null, webhook = "https://discord.test/webhook",
                  ssmThrows = false, missingModifiedDate = false}) {
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
      if (ssmThrows) throw new Error("ParameterNotFound");
      return {Parameter: missingModifiedDate
        ? {Value: "{}"}
        : {Value: "{}", LastModifiedDate: ago(rosterAgeMinutes)}};
    }
    return {Parameter: {Value: webhook}};
  };

  global.fetch = async (_url, options) => {
    delivered.push(JSON.parse(options.body).content);
    if (failDeliveryNumber === delivered.length) {
      return {ok: false, status: 429, statusText: "Too Many Requests"};
    }
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
//
// The roster MUST be past ROSTER_STALE_MINUTES for this to test anything: a roster
// younger than the threshold would stay quiet with or without the grace, so the
// case would pass against a build that has no grace at all. It is realistic too -
// a stop/start leaves the parameter carrying its pre-stop timestamp.
// Expects BOOTING, not OK: a check still inside its grace has not cleared anything,
// so it must not borrow the other check's pass. Quiet (no alert) is the requirement
// here; "OK" would be the monitor claiming a verdict it has not reached.
await scenario("roster stale but still inside boot grace",
  {upMinutes: 5, rosterAgeMinutes: 15}, {status: "BOOTING", alerts: false});

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

console.log("\n--- RED: grace must EXPIRE, not just exist ---");
// The in-grace case proves a grace exists; this proves it ends. Without it, a wrong
// compound condition that suppressed forever would still pass every other case.
await scenario("just past boot grace, roster stale",
  {upMinutes: 21, rosterAgeMinutes: 15}, {status: "WATCHER_DEAD", alerts: true});

console.log("\n--- RED: a check that never ran must not read as OK ---");
// ROSTER_PARAM unset is deployment drift, and the liveness check silently switching
// itself off is exactly the state worth shouting about.
// ROSTER_PARAM is read at module load, so the env var must be gone BEFORE the module
// is evaluated. A query-string specifier gets a fresh module instance rather than the
// cached one; mutating process.env after the first import would not reach it.
delete process.env.ROSTER_PARAM;
const {handler: handlerNoRoster} = await import("../backup-monitor/index.mjs?no-roster");
process.env.ROSTER_PARAM = "/palworld-server/roster";
install({});
const noRoster = await handlerNoRoster();
if (noRoster.status === "UNKNOWN" && delivered.length > 0) {
  console.log("PASS  ROSTER_PARAM unset reports UNKNOWN and alerts");
} else {
  console.log(`FAIL  ROSTER_PARAM unset: status=${noRoster.status} (want UNKNOWN), alerts=${delivered.length} (want >0)`);
  failures++;
}

await scenario("SSM read throws", {ssmThrows: true}, {status: "UNKNOWN", alerts: true});
await scenario("roster has no LastModifiedDate",
  {missingModifiedDate: true}, {status: "UNKNOWN", alerts: true});

console.log("\n--- RED: a malformed threshold must not all-clear forever ---");
// Number("twenty") is NaN and every comparison against NaN is false, so an unguarded
// threshold would make `age > threshold` permanently false - an alarm that can never
// fire, configured by a typo. The guard falls back to the default instead.
process.env.ROSTER_STALE_MINUTES = "twenty";
const {handler: handlerBadEnv} = await import("../backup-monitor/index.mjs?bad-env");
process.env.ROSTER_STALE_MINUTES = "10";
install({rosterAgeMinutes: 940});
const badEnv = await handlerBadEnv();
if (badEnv.status === "WATCHER_DEAD" && delivered.length > 0) {
  console.log("PASS  malformed threshold falls back to the default and the alarm still fires");
} else {
  console.log(`FAIL  malformed threshold: status=${badEnv.status} (want WATCHER_DEAD), alerts=${delivered.length}`);
  failures++;
}

console.log("\n--- GREEN: cold boot must not cry wolf about BACKUPS either ---");
// After a long stop the newest object is legitimately hours old until the first
// post-boot backup lands. This fired on every single start before the grace applied.
await scenario("backups old but instance just started",
  {upMinutes: 5, backupAgeMinutes: 2880}, {status: "BOOTING", alerts: false});

console.log("\n--- RED: an undeliverable alert is a FAILURE, not a pass ---");
// notify() used to return quietly when no webhook was configured, so the invocation
// succeeded, the Errors metric stayed flat, and the SNS channel that exists so
// alerting does not depend on Discord never fired.
install({rosterAgeMinutes: 940, webhook: "None"});
let threwNoWebhook = false;
try { await handler(); } catch { threwNoWebhook = true; }
if (threwNoWebhook) {
  console.log("PASS  unconfigured webhook fails the invocation instead of reporting success");
} else {
  console.log("FAIL  a detected fault was silently undeliverable and the run still succeeded");
  failures++;
}

console.log("\n--- RED: a failed delivery must not swallow the OTHER alert ---");
// notify() throws on a non-2xx, so a delivery loop that does not catch will
// abandon the remaining alerts - one broken thing hiding another.
install({backupAgeMinutes: 120, rosterAgeMinutes: 940, failDeliveryNumber: 1});
let threw = false;
try {
  await handler();
} catch {
  threw = true;   // the invocation MUST still fail; the CloudWatch alarm watches it
}
if (delivered.length === 2 && threw) {
  console.log("PASS  both alerts attempted despite the first failing, and the invocation still threw");
} else {
  console.log(`FAIL  attempted=${delivered.length} (want 2), threw=${threw} (want true)`);
  failures++;
}

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
