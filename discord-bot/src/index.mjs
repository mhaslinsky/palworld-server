// Discord start-bot for the Palworld server.
//
// One function, two entry paths:
//   - HTTP path (Lambda Function URL): verify Ed25519, check the allowlist, ACK
//     Discord with a deferred response, and async-invoke ourselves as a worker.
//   - Worker path (async self-invoke): start the EC2 instance, then edit the
//     deferred message into a real answer.
//
// Discord hard-fails an interaction that is not ACKed within 3s, so no AWS call
// may sit on the HTTP path. The self-invoke keeps that path at signature-verify
// plus one Lambda:Invoke.
//
// Zero dependencies: Ed25519 lives in node:crypto, the AWS SDK v3 and fetch() are
// already present in the nodejs22.x runtime.

import { createPublicKey, verify as verifySignature } from "node:crypto";
import { EC2Client, StartInstancesCommand, DescribeInstancesCommand } from "@aws-sdk/client-ec2";
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";
import { DynamoDBClient, PutItemCommand, ConditionalCheckFailedException } from "@aws-sdk/client-dynamodb";

const DISCORD_PUBLIC_KEY = process.env.DISCORD_PUBLIC_KEY;
const DISCORD_APP_ID = process.env.DISCORD_APP_ID;
const INSTANCE_ID = process.env.INSTANCE_ID;
const SERVER_ADDRESS = process.env.SERVER_ADDRESS;
const ALLOWED_USER_IDS = new Set(
  (process.env.ALLOWED_USER_IDS ?? "").split(",").map((entry) => entry.trim()).filter(Boolean),
);

// Discord rejects an interaction whose timestamp is far from now, to blunt replay.
const MAX_TIMESTAMP_SKEW_SECONDS = 300;

const InteractionType = { PING: 1, APPLICATION_COMMAND: 2 };
const InteractionResponseType = {
  PONG: 1,
  CHANNEL_MESSAGE_WITH_SOURCE: 4,
  DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE: 5,
};
const EPHEMERAL = 1 << 6;

const ROSTER_PARAM = process.env.ROSTER_PARAM;

// How stale a roster may be before we stop believing it. The instance republishes
// every 2 minutes; past this the server is likely mid-shutdown or already gone.
const ROSTER_MAX_AGE_SECONDS = 360;

// --- /ask (Palworld Q&A) config ---
const ASK_WORKER_FUNCTION_NAME = process.env.ASK_WORKER_FUNCTION_NAME;
const COOLDOWN_TABLE = process.env.COOLDOWN_TABLE;
// NaN-safe: a typo in the env var must not silently disable the cap or the cooldown.
const intEnv = (name, fallback) => {
  const parsed = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};
const ASK_COOLDOWN_SECONDS = intEnv("ASK_COOLDOWN_SECONDS", 60);
const ASK_MAX_QUESTION_CHARS = intEnv("ASK_MAX_QUESTION_CHARS", 300);

const ec2 = new EC2Client({});
const lambda = new LambdaClient({});
const ssm = new SSMClient({});
const ddb = new DynamoDBClient({});

// Discord publishes the app's Ed25519 key as raw hex; node:crypto wants SPKI DER.
// The 12-byte prefix is the fixed SubjectPublicKeyInfo header for Ed25519.
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function discordPublicKey() {
  const raw = Buffer.from(DISCORD_PUBLIC_KEY, "hex");
  if (raw.length !== 32) {
    throw new Error(`DISCORD_PUBLIC_KEY must be 32 bytes of hex, got ${raw.length}`);
  }
  return createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, raw]),
    format: "der",
    type: "spki",
  });
}

function isSignatureValid(rawBody, signatureHex, timestamp) {
  if (!signatureHex || !timestamp) return false;

  const signature = Buffer.from(signatureHex, "hex");
  if (signature.length !== 64) return false;

  const skew = Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp));
  if (!Number.isFinite(skew) || skew > MAX_TIMESTAMP_SKEW_SECONDS) return false;

  // The signed payload is the timestamp header concatenated with the exact body
  // bytes Discord sent. Re-serializing the parsed JSON would change them.
  const signedPayload = Buffer.concat([Buffer.from(timestamp, "utf8"), rawBody]);
  return verifySignature(null, signedPayload, discordPublicKey(), signature);
}

function callerId(interaction) {
  // In a guild the caller is member.user; in a DM it is the top-level user.
  return interaction.member?.user?.id ?? interaction.user?.id ?? null;
}

function ephemeral(content) {
  return {
    type: InteractionResponseType.CHANNEL_MESSAGE_WITH_SOURCE,
    data: { content, flags: EPHEMERAL },
  };
}

function httpResponse(statusCode, body) {
  return { statusCode, headers: { "content-type": "application/json" }, body: JSON.stringify(body) };
}

async function instanceState() {
  const described = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [INSTANCE_ID] }));
  return described.Reservations?.[0]?.Instances?.[0]?.State?.Name ?? "unknown";
}

// The roster is pushed here by the instance; the REST API it comes from is bound to
// localhost and unreachable from Lambda by design. A stale or unreadable roster
// degrades the reply rather than failing it.
async function readRoster() {
  if (!ROSTER_PARAM) return null;
  try {
    const result = await ssm.send(new GetParameterCommand({ Name: ROSTER_PARAM }));
    const roster = JSON.parse(result.Parameter?.Value ?? "{}");
    if (typeof roster.count !== "number" || typeof roster.updated !== "number") return null;

    const ageSeconds = Math.floor(Date.now() / 1000) - roster.updated;
    if (ageSeconds > ROSTER_MAX_AGE_SECONDS) return null;
    return roster;
  } catch (error) {
    console.warn("roster unavailable", error?.name ?? error);
    return null;
  }
}

function describePlayers(roster) {
  if (!roster) return ""; // no roster => say nothing rather than claim "0 online"
  if (roster.count === 0) return " — nobody online";
  const plural = roster.count === 1 ? "player" : "players";
  return roster.names ? ` — ${roster.count} ${plural}: ${roster.names}` : ` — ${roster.count} ${plural}`;
}

// Replace the deferred placeholder with the real outcome.
async function editDeferredMessage(interactionToken, content) {
  const url = `https://discord.com/api/v10/webhooks/${DISCORD_APP_ID}/${interactionToken}/messages/@original`;
  const response = await fetch(url, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ content }),
  });
  if (!response.ok) {
    console.error("failed to edit deferred message", response.status, await response.text());
  }
}

async function runWorker({ command, interactionToken }) {
  try {
    const state = await instanceState();

    if (command === "palworld-status") {
      let detail;
      if (state === "running") {
        const roster = await readRoster();
        detail = `🟢 **running**${describePlayers(roster)}\njoin at \`${SERVER_ADDRESS}\``;
      } else {
        detail = `⚪ **${state}** — run \`/palworld-start\` to bring it up.`;
      }
      await editDeferredMessage(interactionToken, detail);
      return;
    }

    if (state === "running") {
      await editDeferredMessage(interactionToken, `🟢 Already running — join at \`${SERVER_ADDRESS}\`.`);
      return;
    }
    if (state === "pending") {
      await editDeferredMessage(interactionToken, "⏳ Already starting — give it a minute.");
      return;
    }
    // 'stopping' is a real state and StartInstances rejects it; say so rather than fail opaquely.
    if (state !== "stopped") {
      await editDeferredMessage(interactionToken, `⚠️ Can't start from state \`${state}\`. Try again shortly.`);
      return;
    }

    await ec2.send(new StartInstancesCommand({ InstanceIds: [INSTANCE_ID] }));
    await editDeferredMessage(
      interactionToken,
      `🚀 Starting **Palworld** — ready in ~2 min at \`${SERVER_ADDRESS}\`.\n` +
        "It shuts itself down automatically once everyone leaves.",
    );
  } catch (error) {
    console.error("worker failed", error);
    await editDeferredMessage(interactionToken, "❌ Something went wrong starting the server. Check the logs.");
  }
}

function optionValue(interaction, name) {
  const option = (interaction.data?.options ?? []).find((entry) => entry.name === name);
  return typeof option?.value === "string" ? option.value : null;
}

// Atomically claim the per-user cooldown BEFORE deferring, so a rejected request
// never reaches the model. A conditional PutItem is the whole rate limiter: it writes
// only if the user has no record, or their last accepted ask is older than the window.
// ReturnValuesOnConditionCheckFailure gives us the existing timestamp on rejection in
// the same call, so we can tell the user how long to wait without a second read.
// Fail CLOSED: a store outage denies the request rather than letting an uncapped
// (uncooled) model call through — the guarded resource here is spend.
async function claimCooldown(userId) {
  const now = Math.floor(Date.now() / 1000);
  try {
    await ddb.send(
      new PutItemCommand({
        TableName: COOLDOWN_TABLE,
        Item: {
          user_id: { S: userId },
          last_ts: { N: String(now) },
          ttl: { N: String(now + ASK_COOLDOWN_SECONDS) },
        },
        ConditionExpression: "attribute_not_exists(user_id) OR last_ts < :threshold",
        ExpressionAttributeValues: { ":threshold": { N: String(now - ASK_COOLDOWN_SECONDS) } },
        ReturnValuesOnConditionCheckFailure: "ALL_OLD",
      }),
    );
    return { ok: true };
  } catch (error) {
    if (error instanceof ConditionalCheckFailedException) {
      const lastTs = Number(error.Item?.last_ts?.N ?? now);
      const remaining = Math.max(1, ASK_COOLDOWN_SECONDS - (now - lastTs));
      return { ok: false, message: `⏳ Hang on — you can ask again in ${remaining}s.` };
    }
    console.error("cooldown store error", error?.name ?? error);
    return { ok: false, message: "⚠️ Couldn't check the cooldown just now — try again in a moment." };
  }
}

// The /ask HTTP path: validate + gate + claim cooldown, then hand off to the
// ask-worker. We AWAIT the async invoke before returning the deferred ACK — returning
// first can let the frozen Lambda environment drop the in-flight invoke. If the invoke
// fails we have not deferred yet, so we answer with an ephemeral error rather than
// leaving a permanent "thinking…".
async function handleAsk(interaction, userId) {
  const question = optionValue(interaction, "question");
  if (!question || !question.trim()) {
    return httpResponse(200, ephemeral("Ask me something: `/ask <your Palworld question>`"));
  }
  if (question.length > ASK_MAX_QUESTION_CHARS) {
    return httpResponse(200, ephemeral(`⚠️ That question is too long (max ${ASK_MAX_QUESTION_CHARS} characters).`));
  }

  const cooldown = await claimCooldown(userId);
  if (!cooldown.ok) return httpResponse(200, ephemeral(cooldown.message));

  try {
    await lambda.send(
      new InvokeCommand({
        FunctionName: ASK_WORKER_FUNCTION_NAME,
        InvocationType: "Event",
        Payload: Buffer.from(JSON.stringify({ question: question.trim(), interactionToken: interaction.token })),
      }),
    );
  } catch (error) {
    console.error("ask-worker invoke failed", error?.name ?? error);
    return httpResponse(200, ephemeral("❌ Couldn't start answering just now — try again in a moment."));
  }

  return httpResponse(200, { type: InteractionResponseType.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE });
}

export async function handler(event) {
  // Async self-invoke: no HTTP envelope, just our own payload.
  if (event?.__worker === true) {
    await runWorker(event);
    return;
  }

  const headers = event.headers ?? {};
  const rawBody = Buffer.from(event.body ?? "", event.isBase64Encoded ? "base64" : "utf8");

  // Discord probes the endpoint with a deliberately bad signature and requires a
  // 401; returning 200 here means it refuses to save the Interactions URL.
  if (!isSignatureValid(rawBody, headers["x-signature-ed25519"], headers["x-signature-timestamp"])) {
    return httpResponse(401, { error: "invalid request signature" });
  }

  const interaction = JSON.parse(rawBody.toString("utf8"));

  if (interaction.type === InteractionType.PING) {
    return httpResponse(200, { type: InteractionResponseType.PONG });
  }

  if (interaction.type !== InteractionType.APPLICATION_COMMAND) {
    return httpResponse(200, ephemeral("Unsupported interaction."));
  }

  const userId = callerId(interaction);
  if (!userId || !ALLOWED_USER_IDS.has(userId)) {
    console.warn("rejected non-allowlisted caller", userId);
    return httpResponse(200, ephemeral("⛔ You're not on the allowlist for this server."));
  }

  const command = interaction.data?.name;

  // /ask has its own worker (Bedrock + web search) and its own cooldown gate.
  if (command === "ask") {
    return await handleAsk(interaction, userId);
  }

  if (command !== "palworld-start" && command !== "palworld-status") {
    return httpResponse(200, ephemeral(`Unknown command \`${command}\`.`));
  }

  // Hand the slow work to ourselves so the ACK below is never late.
  await lambda.send(
    new InvokeCommand({
      FunctionName: process.env.AWS_LAMBDA_FUNCTION_NAME,
      InvocationType: "Event",
      Payload: Buffer.from(JSON.stringify({ __worker: true, command, interactionToken: interaction.token })),
    }),
  );

  return httpResponse(200, { type: InteractionResponseType.DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE });
}
