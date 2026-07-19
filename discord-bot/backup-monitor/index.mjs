// Off-box observer for the rolling world backups.
//
// The backup job runs on the game box itself, so every way it can die -- dead
// systemd timer, expired IAM, full disk, REST save failing, the box being replaced
// -- is silent from the outside. Nobody learns backups stopped until they are
// needed. That is exactly how ~4.5h of the group's progress was lost on
// 2026-07-18: the only surviving copy was one pulled off by hand that morning.
//
// This runs on a schedule, OUTSIDE the box, and answers one question: is there a
// recent world backup in S3? It deliberately keys off instance state, because the
// box stops itself when empty and "no backups while stopped" is correct behaviour,
// not a fault -- alarming on that would train everyone to ignore the alarm.
//
// Distinguishes three states, never collapsing them into "fine":
//   OK        - instance running, fresh object present
//   SLEEPING  - instance stopped, no backup expected
//   STALE     - instance running, newest object older than the threshold  -> alert
//   UNKNOWN   - the check itself failed (API error) -> alert, because a check that
//               cannot run has NOT cleared anything

import {EC2Client, DescribeInstancesCommand} from "@aws-sdk/client-ec2";
import {S3Client, ListObjectsV2Command} from "@aws-sdk/client-s3";
import {SSMClient, GetParameterCommand} from "@aws-sdk/client-ssm";

const REGION = process.env.AWS_REGION || "us-east-1";
const INSTANCE_ID = process.env.INSTANCE_ID;
const BUCKET = process.env.BACKUP_BUCKET;
const PREFIX = process.env.BACKUP_PREFIX || "world/linux/";
const STALE_MINUTES = Number(process.env.STALE_MINUTES || 45);
const MIN_BYTES = Number(process.env.MIN_BYTES || 1_000_000);
const WEBHOOK_PARAM = process.env.WEBHOOK_PARAM;

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
  if (!WEBHOOK_PARAM) return;

  const result = await ssm.send(new GetParameterCommand({Name: WEBHOOK_PARAM, WithDecryption: true}));
  const url = result.Parameter?.Value;
  // An unset SSM parameter comes back as the literal string "None". That is a
  // deliberate "no webhook configured", not a failure.
  if (!url || url === "None") {
    console.log("no webhook configured — alert not delivered");
    return;
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

async function instanceState() {
  const result = await ec2.send(new DescribeInstancesCommand({InstanceIds: [INSTANCE_ID]}));
  return result.Reservations?.[0]?.Instances?.[0]?.State?.Name ?? "unknown";
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

export const handler = async () => {
  let state;
  try {
    state = await instanceState();
  } catch (error) {
    // The check itself failed. Silence here would read as an all-clear.
    await notify(`⚠️ **Backup monitor could not run** — EC2 lookup failed: ${error.message}`);
    return {status: "UNKNOWN", reason: error.message};
  }

  if (state !== "running") {
    console.log(`instance ${state} — no backup expected`);
    return {status: "SLEEPING", state};
  }

  let newest;
  try {
    newest = await newestBackup();
  } catch (error) {
    await notify(`⚠️ **Backup monitor could not run** — S3 list failed: ${error.message}`);
    return {status: "UNKNOWN", reason: error.message};
  }

  if (!newest) {
    await notify(`🚨 **No world backups exist at all** in \`s3://${BUCKET}/${PREFIX}\` while the server is running. Backups are NOT protecting you.`);
    return {status: "STALE", reason: "no objects"};
  }

  const ageMinutes = Math.round((Date.now() - new Date(newest.LastModified).getTime()) / 60000);

  // A tiny object is a failed backup wearing a success costume: the on-box script
  // has a size floor, but if it is ever bypassed this catches the empty-world class.
  if (newest.Size < MIN_BYTES) {
    await notify(`🚨 **Latest world backup looks corrupt** — \`${newest.Key}\` is only ${newest.Size} bytes (floor ${MIN_BYTES}). Treat backups as unreliable until checked.`);
    return {status: "STALE", reason: "undersized", key: newest.Key, size: newest.Size};
  }

  if (ageMinutes > STALE_MINUTES) {
    await notify(`🚨 **World backups have stopped** — newest is \`${newest.Key}\`, ${ageMinutes} min old (threshold ${STALE_MINUTES} min) while the server is running. Check \`palworld-backup.timer\` on the box.`);
    return {status: "STALE", ageMinutes, key: newest.Key};
  }

  console.log(`OK — newest ${newest.Key}, ${ageMinutes}m old, ${newest.Size} bytes`);
  return {status: "OK", ageMinutes, key: newest.Key, size: newest.Size};
};
