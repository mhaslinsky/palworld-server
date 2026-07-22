// Red/green harness for the /ask path of the entry handler (discord-bot/src).
//
//   cd discord-bot && npm install && npm test
//
// Like the backup-monitor harness, the point is to watch each guard FIRE, not to
// chase coverage: a forged signature must 401, a non-allowlisted caller must be
// refused, the cooldown must actually block a second ask, and — the subtle one — a
// cooldown STORE OUTAGE must fail CLOSED (deny), never silently allow an uncooled
// (uncapped-spend) model call.
//
// We sign requests with a real Ed25519 key so the signature check is exercised for
// real rather than stubbed. SDK clients are patched at the prototype before import.

import { generateKeyPairSync, sign as edSign } from "node:crypto";
import { LambdaClient } from "@aws-sdk/client-lambda";
import { DynamoDBClient, ConditionalCheckFailedException } from "@aws-sdk/client-dynamodb";

// --- a real keypair; publish the raw 32-byte public key as the app key ------------
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawPublicKey = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("hex");

process.env.DISCORD_PUBLIC_KEY = rawPublicKey;
process.env.DISCORD_APP_ID = "app-test";
process.env.INSTANCE_ID = "i-test";
process.env.SERVER_ADDRESS = "test:8211";
process.env.ALLOWED_USER_IDS = "allowed-user";
process.env.ROSTER_PARAM = "/palworld-server/roster_windows";
process.env.ASK_WORKER_FUNCTION_NAME = "palworld-server-discord-ask";
process.env.COOLDOWN_TABLE = "palworld-server-ask-cooldown";
process.env.ASK_COOLDOWN_SECONDS = "60";
process.env.ASK_MAX_QUESTION_CHARS = "300";

// --- controllable SDK behaviour ---------------------------------------------------
let invokes = []; // FunctionNames the handler asked Lambda to invoke
let cooldownMode = "ok"; // "ok" | "blocked" | "error"

LambdaClient.prototype.send = async (command) => {
  invokes.push(command.input.FunctionName);
  return {};
};

DynamoDBClient.prototype.send = async () => {
  if (cooldownMode === "ok") return {};
  if (cooldownMode === "blocked") {
    const error = new ConditionalCheckFailedException({ message: "cooldown", $metadata: {} });
    error.Item = { last_ts: { N: String(Math.floor(Date.now() / 1000) - 10) } }; // 10s ago
    throw error;
  }
  throw new Error("DynamoDB unavailable"); // "error" -> fail closed
};

const { handler } = await import("../src/index.mjs");

// --- request builders -------------------------------------------------------------
function signedEvent(interaction, { tamper = false } = {}) {
  const body = JSON.stringify(interaction);
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = edSign(null, Buffer.concat([Buffer.from(timestamp), Buffer.from(body)]), privateKey).toString("hex");
  return {
    headers: {
      "x-signature-ed25519": tamper ? "00".repeat(64) : signature,
      "x-signature-timestamp": timestamp,
    },
    body,
    isBase64Encoded: false,
  };
}

function askInteraction(question, userId = "allowed-user") {
  return {
    type: 2,
    data: { name: "ask", options: question === undefined ? [] : [{ name: "question", type: 3, value: question }] },
    member: { user: { id: userId } },
    token: "interaction-token-abc",
  };
}

let failures = 0;
function check(name, condition, detail = "") {
  if (condition) {
    console.log(`PASS  ${name}`);
  } else {
    console.log(`FAIL  ${name}  ${detail}`);
    failures++;
  }
}
function bodyOf(result) {
  return JSON.parse(result.body);
}

console.log("--- RED: the signature guard must reject a forgery ---");
{
  invokes = [];
  cooldownMode = "ok";
  const result = await handler(signedEvent(askInteraction("where is quartz?"), { tamper: true }));
  check("forged signature -> 401", result.statusCode === 401, `got ${result.statusCode}`);
  check("forged signature -> no invoke", invokes.length === 0, `invokes=${invokes.length}`);
}

console.log("\n--- RED: a non-allowlisted caller must be refused ---");
{
  invokes = [];
  cooldownMode = "ok";
  const result = await handler(signedEvent(askInteraction("hi", "stranger")));
  check("stranger -> refused, no invoke", result.statusCode === 200 && invokes.length === 0, `invokes=${invokes.length}`);
  check("stranger -> ephemeral message (type 4)", bodyOf(result).type === 4);
}

console.log("\n--- GREEN: an allowed, un-cooled ask defers and invokes the worker once ---");
{
  invokes = [];
  cooldownMode = "ok";
  const result = await handler(signedEvent(askInteraction("best mining pal?")));
  check("accepted -> deferred (type 5)", bodyOf(result).type === 5, `type=${bodyOf(result).type}`);
  check("accepted -> ask-worker invoked exactly once", invokes.length === 1 && invokes[0] === "palworld-server-discord-ask", invokes.join(","));
}

console.log("\n--- RED: within the cooldown window the ask is blocked and NOT invoked ---");
{
  invokes = [];
  cooldownMode = "blocked";
  const result = await handler(signedEvent(askInteraction("again already")));
  check("cooled -> ephemeral (type 4), no invoke", bodyOf(result).type === 4 && invokes.length === 0, `invokes=${invokes.length}`);
  check("cooled -> tells the user a remaining wait", /again in \d+s/.test(bodyOf(result).data.content), bodyOf(result).data.content);
}

console.log("\n--- RED: a cooldown STORE OUTAGE must fail CLOSED (deny, never allow) ---");
{
  invokes = [];
  cooldownMode = "error";
  const result = await handler(signedEvent(askInteraction("store is down")));
  check("store error -> no invoke (fail closed)", invokes.length === 0, `invokes=${invokes.length}`);
  check("store error -> ephemeral error, not a defer", bodyOf(result).type === 4);
}

console.log("\n--- RED: an over-long question is rejected before any spend ---");
{
  invokes = [];
  cooldownMode = "ok";
  const result = await handler(signedEvent(askInteraction("x".repeat(301))));
  check("too long -> ephemeral, no invoke", bodyOf(result).type === 4 && invokes.length === 0, `invokes=${invokes.length}`);
}

console.log("\n--- GREEN: an empty question prompts rather than invoking ---");
{
  invokes = [];
  cooldownMode = "ok";
  const result = await handler(signedEvent(askInteraction(undefined)));
  check("empty -> ephemeral prompt, no invoke", bodyOf(result).type === 4 && invokes.length === 0, `invokes=${invokes.length}`);
}

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
