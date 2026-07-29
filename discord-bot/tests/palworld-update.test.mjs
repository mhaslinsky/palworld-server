// Red/green harness for the /palworld-update path (entry handler + worker).
//
//   cd discord-bot && npm install && npm test
//
// Same intent as the sibling harnesses: watch each guard FIRE. This command drops
// every player and then runs SteamCMD on a live box, so the guards that matter are the
// ones that decide whether SendCommand goes out at all. The subtle one is the mods
// defaulting: the SSM command string interpolates `mods` directly, and it is safe ONLY
// because an unrecognised value is coerced to "keep" before it gets there. A refactor
// that loosened that would be an injection, and this is what would catch it.
//
// Requests are signed with a real Ed25519 key so the signature path runs for real.
// SDK clients are patched at the prototype before import.

import { generateKeyPairSync, sign as edSign } from "node:crypto";
import { EC2Client } from "@aws-sdk/client-ec2";
import { LambdaClient } from "@aws-sdk/client-lambda";
import { SSMClient } from "@aws-sdk/client-ssm";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");

process.env.DISCORD_PUBLIC_KEY = rawPublicKey;
process.env.DISCORD_APP_ID = "app-test";
process.env.INSTANCE_ID = "i-test";
process.env.SERVER_ADDRESS = "test:8211";
process.env.ALLOWED_USER_IDS = "allowed-user";
process.env.ROSTER_PARAM = "/palworld-server/roster_windows";
process.env.BACKUP_BUCKET = "palworld-server-backups-000000000000";
process.env.AWS_REGION = "us-east-1";
process.env.AWS_LAMBDA_FUNCTION_NAME = "palworld-server-discord";

// --- controllable SDK behaviour ---------------------------------------------------
let sentCommands = [];       // every SSM SendCommand input
let invokes = [];            // every Lambda self-invoke payload
let instanceStateName = "running";
let sendCommandThrows = false;
let rosterValue = JSON.stringify({ count: 0, names: "", updated: Math.floor(Date.now() / 1000) });

EC2Client.prototype.send = async () => ({
  Reservations: [{ Instances: [{ State: { Name: instanceStateName } } ] }],
});

LambdaClient.prototype.send = async (command) => {
  invokes.push(JSON.parse(Buffer.from(command.input.Payload).toString("utf8")));
  return {};
};

SSMClient.prototype.send = async (command) => {
  const name = command.constructor.name;
  if (name === "GetParameterCommand") {
    return { Parameter: { Value: rosterValue, LastModifiedDate: new Date() } };
  }
  if (sendCommandThrows) throw new Error("SSM unavailable");
  sentCommands.push(command.input);
  return { Command: { CommandId: "cmd-test" } };
};

// The worker edits the deferred message over HTTP; capture instead of calling Discord.
let edits = [];
globalThis.fetch = async (_url, init) => {
  edits.push(JSON.parse(init.body).content);
  return { ok: true, status: 200, text: async () => "" };
};

const { handler } = await import("../src/index.mjs");

// --- helpers ----------------------------------------------------------------------
function signedEvent(interaction) {
  const body = JSON.stringify(interaction);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = edSign(null, Buffer.concat([Buffer.from(timestamp), Buffer.from(body)]), privateKey).toString("hex");
  return {
    headers: { "x-signature-ed25519": signature, "x-signature-timestamp": timestamp },
    body,
    isBase64Encoded: false,
  };
}

function updateInteraction(modsValue, userId = "allowed-user") {
  return {
    type: 2,
    data: {
      name: "palworld-update",
      options: modsValue === undefined ? [] : [{ name: "mods", type: 3, value: modsValue }],
    },
    member: { user: { id: userId } },
    token: "interaction-token-abc",
  };
}

const workerEvent = (mods) => ({
  __worker: true,
  command: "palworld-update",
  interactionToken: "interaction-token-abc",
  mods,
});

let failures = 0;
function check(name, condition, detail = "") {
  if (condition) {
    console.log(`PASS  ${name}`);
  } else {
    console.log(`FAIL  ${name}  ${detail}`);
    failures++;
  }
}
function resetState() {
  sentCommands = [];
  invokes = [];
  edits = [];
  instanceStateName = "running";
  sendCommandThrows = false;
  rosterValue = JSON.stringify({ count: 0, names: "", updated: Math.floor(Date.now() / 1000) });
}

// Pull the -Mods argument back out of the generated PowerShell.
function modsArgOf(input) {
  const line = input.Parameters.commands.find((entry) => entry.includes("-Mods "));
  return line ? line.split("-Mods ")[1].trim() : null;
}

console.log("--- RED: a non-allowlisted caller cannot trigger an update ---");
{
  resetState();
  const result = await handler(signedEvent(updateInteraction("keep", "stranger")));
  check("stranger -> ephemeral refusal (type 4)", JSON.parse(result.body).type === 4);
  check("stranger -> no worker invoke", invokes.length === 0, `invokes=${invokes.length}`);
  check("stranger -> no SendCommand", sentCommands.length === 0, `sent=${sentCommands.length}`);
}

console.log("\n--- RED: a stopped box must NOT be sent an update (SSM cannot reach it) ---");
{
  resetState();
  instanceStateName = "stopped";
  await handler(workerEvent("keep"));
  check("stopped -> no SendCommand", sentCommands.length === 0, `sent=${sentCommands.length}`);
  check("stopped -> tells the user to start it first", /palworld-start/.test(edits.join(" ")), edits.join(" | "));
}

console.log("\n--- GREEN: a running box gets exactly one SendCommand ---");
{
  resetState();
  await handler(workerEvent("keep"));
  check("running -> exactly one SendCommand", sentCommands.length === 1, `sent=${sentCommands.length}`);
  check("running -> targets the configured instance", sentCommands[0]?.InstanceIds?.[0] === "i-test");
  check("running -> uses AWS-RunPowerShellScript", sentCommands[0]?.DocumentName === "AWS-RunPowerShellScript");
}

console.log("\n--- RED: an unrecognised mods value must NOT reach the SSM command ---");
{
  // This is the injection guard. If a future refactor forwards the raw option, this
  // is the test that goes red rather than a shell metacharacter reaching the box.
  resetState();
  await handler(workerEvent("vanilla; Remove-Item C:\\PalServer -Recurse"));
  check("hostile mods -> still one SendCommand", sentCommands.length === 1, `sent=${sentCommands.length}`);
  check("hostile mods -> coerced to keep", modsArgOf(sentCommands[0]) === "keep", String(modsArgOf(sentCommands[0])));
  const joined = sentCommands[0].Parameters.commands.join("\n");
  check("hostile mods -> no Remove-Item smuggled in", !joined.includes("Remove-Item"), joined);
}

console.log("\n--- GREEN: absent mods defaults to keep; a valid mode is passed through ---");
{
  resetState();
  await handler(workerEvent(undefined));
  check("absent mods -> keep", modsArgOf(sentCommands[0]) === "keep", String(modsArgOf(sentCommands[0])));

  resetState();
  await handler(workerEvent("vanilla"));
  check("mods=vanilla -> vanilla", modsArgOf(sentCommands[0]) === "vanilla", String(modsArgOf(sentCommands[0])));
}

console.log("\n--- RED: the bootstrap must fail closed rather than run a stale script ---");
{
  resetState();
  await handler(workerEvent("keep"));
  const commands = sentCommands[0].Parameters.commands;
  const copyIndex = commands.findIndex((entry) => entry.includes("s3 cp"));
  const guardIndex = commands.findIndex((entry) => entry.includes("$LASTEXITCODE -ne 0") && entry.includes("Test-Path"));
  const runIndex = commands.findIndex((entry) => entry.includes("-File "));
  check("download is guarded before the script runs",
    copyIndex >= 0 && guardIndex > copyIndex && runIndex > guardIndex,
    `copy=${copyIndex} guard=${guardIndex} run=${runIndex}`);
  check("the guard exits non-zero", commands[guardIndex]?.includes("exit 1"), commands[guardIndex] ?? "");
}

console.log("\n--- RED: a SendCommand failure edits a visible error, it does not hang ---");
{
  resetState();
  sendCommandThrows = true;
  await handler(workerEvent("keep"));
  check("SendCommand throws -> user is told", edits.length > 0 && /Couldn't kick off the update/.test(edits.join(" ")), edits.join(" | "));
}

console.log("\n--- GREEN: players online are named to the operator before they are dropped ---");
{
  resetState();
  rosterValue = JSON.stringify({ count: 3, names: "ana, bo, cy", updated: Math.floor(Date.now() / 1000) });
  await handler(workerEvent("keep"));
  const message = edits.join(" | ");
  check("roster count surfaced", /3 online right now/.test(message), message);
  check("roster names surfaced", /ana, bo, cy/.test(message), message);
  check("does NOT claim the result lands in this channel", !/post here/.test(message), message);
}

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
