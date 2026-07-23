// Off-box observer for the rolling world backups.
//
// The backup job runs on the game box itself, so every way it can die -- dead
// scheduled task, expired IAM, full disk, REST save failing, the box being replaced
// -- is silent from the outside. Nobody learns backups stopped until they are
// needed. That is exactly how ~4.5h of the group's progress was lost on
// 2026-07-18: the only surviving copy was one pulled off by hand that morning.
//
// Every check here keys off instance state first, because the box stops itself
// when empty: "no backups while stopped" and "no roster while stopped" are both
// correct behaviour, not faults. Alarming on either would train everyone to ignore
// the alarm -- which is how the real one gets missed.
//
// It also watches the PalworldIdle task, via the roster parameter that watcher
// rewrites every cycle. The watcher fails OPEN (any error counts as "players
// present"), so a dead one never stops the box and never complains -- a stale
// roster is the only evidence it leaves. See commit history for 2026-07-19.
//
// Distinguishes these states, never collapsing them into "fine":
//   OK        - instance running, fresh backup present, watcher publishing
//   SLEEPING  - instance stopped, neither timer expected to run
//   BOOTING   - instance running but inside its boot grace; a check has not reached
//               a verdict yet, so this is deliberately NOT reported as OK
//   STALE     - instance running, newest object older than the threshold  -> alert
//   WATCHER_DEAD - instance running past its grace period, roster not updating -> alert
//   UNKNOWN   - the check itself failed, or was never configured -> alert, because a
//               check that cannot run has NOT cleared anything

import {EC2Client, DescribeInstancesCommand} from "@aws-sdk/client-ec2";
import {S3Client, ListObjectsV2Command} from "@aws-sdk/client-s3";
import {SSMClient, GetParameterCommand} from "@aws-sdk/client-ssm";

const REGION = process.env.AWS_REGION || "us-east-1";
const INSTANCE_ID = process.env.INSTANCE_ID;
const BUCKET = process.env.BACKUP_BUCKET;
const PREFIX = process.env.BACKUP_PREFIX || "world/linux/";
// Every threshold goes through this: `Number("")` is 0 and `Number("twenty")` is
// NaN, and EVERY comparison against NaN is false - so one fat-fingered env var
// would make `age > threshold` permanently false and all-clear forever. A
// threshold that cannot fire is the house bug wearing a config costume.
function minutesSetting(raw, fallback) {
  const parsed = Number(raw);
  if (raw === undefined || raw === null || raw === "" || !Number.isFinite(parsed)) return fallback;
  return parsed;
}

// Fallback matches terraform/backup_monitor.tf: 75 min tolerates a single missed or
// degraded 30-min run (newest healthy object ages to ~60) and only alerts on two in a
// row (~90). A missing env var must not silently reintroduce the noisy 45.
const STALE_MINUTES = minutesSetting(process.env.STALE_MINUTES, 75);
const MIN_BYTES = minutesSetting(process.env.MIN_BYTES, 1_000_000);
const WEBHOOK_PARAM = process.env.WEBHOOK_PARAM;
const ROSTER_PARAM = process.env.ROSTER_PARAM;
const ROSTER_STALE_MINUTES = minutesSetting(process.env.ROSTER_STALE_MINUTES, 10);
// The watcher publishes nothing until the game's REST API answers, and a cold boot
// runs SteamCMD before that. Without this grace the monitor would cry wolf after
// every single start - and an alarm that fires on normal operation gets muted.
// The same grace covers backups: after a long stop the newest object is legitimately
// hours old until the first post-boot backup lands.
const BOOT_GRACE_MINUTES = minutesSetting(process.env.BOOT_GRACE_MINUTES, 20);

const ec2 = new EC2Client({region: REGION});
const s3 = new S3Client({region: REGION});
const ssm = new SSMClient({region: REGION});

/**
 * Deliver an alert. THROWS if it cannot, so the Lambda invocation fails and
 * EventBridge/CloudWatch records an error.
 *
 * The earlier version logged and returned on every failure path, so a monitor
 * that had correctly detected missing backups could tell nobody and still report
 * a successful invocation - a watchdog that fails silently is worse than none,
 * because it is trusted. Note fetch() does NOT reject on 401/404/429/500, so the
 * response status must be checked explicitly.
 */
async function notify(content) {
  // No webhook is NOT a pass. This used to return quietly, on the reasoning that an
  // unconfigured webhook is a deliberate choice - but notify() is only ever called
  // when something is already WRONG, and returning cleanly meant the invocation
  // succeeded, the Errors metric stayed flat, and the SNS channel that exists
  // precisely so alerting does not depend on Discord never fired. The monitor
  // detected the fault and told nobody, successfully.
  if (!WEBHOOK_PARAM) {
    throw new Error(`WEBHOOK_PARAM not set — alert NOT delivered: ${content}`);
  }

  const result = await ssm.send(new GetParameterCommand({Name: WEBHOOK_PARAM, WithDecryption: true}));
  const url = result.Parameter?.Value;
  // An unset SSM parameter comes back as the literal string "None".
  if (!url || url === "None") {
    throw new Error(`no webhook configured at ${WEBHOOK_PARAM} — alert NOT delivered: ${content}`);
  }

  const response = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({content}),
  });
  if (!response.ok) {
    throw new Error(`webhook returned ${response.status} ${response.statusText} — alert NOT delivered`);
  }
}

/**
 * State plus how long the instance has been up, which the watcher check needs to
 * tell "not started yet" from "started and broken".
 *
 * LaunchTime is the right clock for both cases it has to survive: a stop/start
 * refreshes it (so a cold boot gets its full grace period), while an in-place OS
 * reboot does not (so a watcher killed by a reboot - exactly the 2026-07-19
 * failure - is reported promptly instead of being handed a fresh grace period).
 */
async function instanceStatus() {
  const result = await ec2.send(new DescribeInstancesCommand({InstanceIds: [INSTANCE_ID]}));
  const instance = result.Reservations?.[0]?.Instances?.[0];
  return {
    state: instance?.State?.Name ?? "unknown",
    launchTime: instance?.LaunchTime ?? null,
  };
}

/**
 * Age in minutes of the roster parameter the idle watcher rewrites every cycle.
 * Returns null when no parameter is configured (the check is then skipped, and
 * says so - it does not report a pass it never performed).
 */
async function rosterAgeMinutes() {
  if (!ROSTER_PARAM) return null;
  const result = await ssm.send(new GetParameterCommand({Name: ROSTER_PARAM}));
  const modified = result.Parameter?.LastModifiedDate;
  if (!modified) throw new Error(`${ROSTER_PARAM} has no LastModifiedDate`);
  return Math.round((Date.now() - new Date(modified).getTime()) / 60000);
}

/** Newest object under the prefix. S3 has no "sort by date", so page and track the max. */
async function newestBackup() {
  let token;
  let newest = null;
  do {
    const page = await s3.send(new ListObjectsV2Command({
      Bucket: BUCKET,
      Prefix: PREFIX,
      ContinuationToken: token,
    }));
    for (const object of page.Contents ?? []) {
      if (!newest || object.LastModified > newest.LastModified) newest = object;
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  return newest;
}

/** Backups: is there a recent, plausibly-sized object? */
async function checkBackups(upMinutes) {
  let newest;
  try {
    newest = await newestBackup();
  } catch (error) {
    return {status: "UNKNOWN", reason: error.message,
      alert: `⚠️ **Backup monitor could not run** — S3 list failed: ${error.message}`};
  }

  if (!newest) {
    return {status: "STALE", reason: "no objects",
      alert: `🚨 **No world backups exist at all** in \`s3://${BUCKET}/${PREFIX}\` while the server is running. Backups are NOT protecting you.`};
  }

  const ageMinutes = Math.round((Date.now() - new Date(newest.LastModified).getTime()) / 60000);

  // A tiny object is a failed backup wearing a success costume: the on-box script
  // has a size floor, but if it is ever bypassed this catches the empty-world class.
  if (newest.Size < MIN_BYTES) {
    return {status: "STALE", reason: "undersized", key: newest.Key, size: newest.Size,
      alert: `🚨 **Latest world backup looks corrupt** — \`${newest.Key}\` is only ${newest.Size} bytes (floor ${MIN_BYTES}). Treat backups as unreliable until checked.`};
  }

  if (ageMinutes > STALE_MINUTES) {
    // The box stops itself when empty, so after a long sleep the newest object is
    // legitimately hours old until the first post-boot backup lands. Alerting on
    // that would fire on every single start - and an alarm that goes off during
    // normal operation is one everybody learns to ignore.
    if (upMinutes !== null && upMinutes < BOOT_GRACE_MINUTES) {
      return {status: "BOOTING", ageMinutes, key: newest.Key, upMinutes};
    }
    return {status: "STALE", ageMinutes, key: newest.Key,
      alert: `🚨 **World backups have stopped** — newest is \`${newest.Key}\`, ${ageMinutes} min old (threshold ${STALE_MINUTES} min) while the server is running. Check the \`PalworldBackup\` scheduled task on the box (\`Get-ScheduledTaskInfo -TaskName PalworldBackup\`).`};
  }

  return {status: "OK", ageMinutes, key: newest.Key, size: newest.Size};
}

/** Idle watcher: is it still publishing the roster? */
async function checkWatcher(launchTime) {
  // Terraform always wires this, so an unset ROSTER_PARAM means drift or a partial
  // deploy - and "the liveness check silently switched itself off" is exactly the
  // state worth shouting about. Returning a quiet SKIPPED here previously let the
  // aggregation report a top-level OK that no check had earned.
  if (!ROSTER_PARAM) {
    return {status: "UNKNOWN", reason: "ROSTER_PARAM not set",
      alert: "⚠️ **Idle-watcher check is not configured** — `ROSTER_PARAM` is unset on the monitor, so nothing is watching whether the box still shuts down when empty. This is deployment drift; Terraform sets it."};
  }

  let ageMinutes;
  try {
    ageMinutes = await rosterAgeMinutes();
  } catch (error) {
    return {status: "UNKNOWN", reason: error.message,
      alert: `⚠️ **Idle-watcher check could not run** — reading \`${ROSTER_PARAM}\` failed: ${error.message}`};
  }

  const upMinutes = launchTime
    ? Math.round((Date.now() - new Date(launchTime).getTime()) / 60000)
    : null;
  if (upMinutes !== null && upMinutes < BOOT_GRACE_MINUTES) {
    return {status: "BOOTING", upMinutes, rosterAgeMinutes: ageMinutes};
  }

  if (ageMinutes > ROSTER_STALE_MINUTES) {
    // Name BOTH causes. The watcher publishes the roster only after a successful
    // REST poll, so a stale parameter means either the timer is dead OR the game
    // is hung and never answers - and the fail-open design means the box will not
    // stop when empty in either case. Naming only the timer would send whoever
    // responds at the wrong component during a live incident.
    return {status: "WATCHER_DEAD", rosterAgeMinutes: ageMinutes, upMinutes,
      alert: `🚨 **Idle-shutdown is not publishing** — \`${ROSTER_PARAM}\` has not updated in ${ageMinutes} min (threshold ${ROSTER_STALE_MINUTES} min) while the server is up. The box will NOT stop when empty and is billing continuously. Either the \`PalworldIdle\` scheduled task is dead (check \`Get-ScheduledTaskInfo -TaskName PalworldIdle\`) or the game's REST API is hung (check the \`PalServer-Win64-Shipping\` process).`};
  }

  return {status: "OK", rosterAgeMinutes: ageMinutes};
}

export const handler = async () => {
  let instance;
  try {
    instance = await instanceStatus();
  } catch (error) {
    // The check itself failed. Silence here would read as an all-clear.
    await notify(`⚠️ **Backup monitor could not run** — EC2 lookup failed: ${error.message}`);
    return {status: "UNKNOWN", reason: error.message};
  }

  if (instance.state !== "running") {
    console.log(`instance ${instance.state} — neither timer expected to run`);
    return {status: "SLEEPING", state: instance.state};
  }

  // Both checks run before ANY alert is delivered, so a delivery failure cannot
  // skip a check that has not happened yet.
  const upMinutes = instance.launchTime
    ? Math.round((Date.now() - new Date(instance.launchTime).getTime()) / 60000)
    : null;
  const backups = await checkBackups(upMinutes);
  const watcher = await checkWatcher(instance.launchTime);

  // Every alert gets its own delivery ATTEMPT. notify() throws by design, so a bare
  // `for (...) await notify(...)` would abandon the second alert when the first
  // fails - one broken thing hiding another, which is the whole failure mode this
  // function exists to prevent. Failures are collected and re-thrown together: the
  // invocation must still fail loudly (that is what the CloudWatch alarm watches),
  // but not at the cost of an alert that would otherwise have got through.
  const deliveryFailures = [];
  for (const alert of [backups.alert, watcher.alert].filter(Boolean)) {
    try {
      await notify(alert);
    } catch (error) {
      deliveryFailures.push(error.message);
    }
  }
  if (deliveryFailures.length > 0) {
    throw new Error(`${deliveryFailures.length} alert(s) NOT delivered: ${deliveryFailures.join("; ")}`);
  }

  // Worst-case wins, so a single "OK" can never paper over the other check.
  //
  // "OK" is reserved for a run where every check actually reached a verdict. A
  // check that was still inside its boot grace has not cleared anything yet, so it
  // reports BOOTING rather than borrowing the other check's pass - absence of a
  // signal is not a negative signal, and this top-level string is what a human
  // skims in the logs.
  const failed = [backups, watcher].some(check => check.alert);
  const inconclusive = [backups, watcher].some(check => check.status === "BOOTING");
  const status = failed
    ? (watcher.alert ? watcher.status : backups.status)
    : (inconclusive ? "BOOTING" : "OK");

  console.log(`${status} — backups:${backups.status} watcher:${watcher.status}`);
  return {status, backups, watcher};
};
