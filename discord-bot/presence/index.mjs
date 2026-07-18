// Discord Gateway presence daemon for the Palworld server.
//
// Shows "Playing Palworld · 3 online" (or "sleeping") under the bot's name in the
// member list. Discord only renders presence for a bot holding an open Gateway
// WebSocket, which is why this cannot live in the Lambda: a Lambda is invoked,
// responds, and dies, and its 15-minute ceiling forbids a long-lived socket.
//
// This process never talks to the game server. It reads the same two facts the
// slash commands read — the EC2 instance state, and the roster the game box
// publishes to SSM — so the Palworld REST port stays bound to localhost.
//
// Zero dependencies: Node 22 provides a global WebSocket and fetch, and the AWS
// SDK v3 is installed alongside. No discord.js, no ws.

import { EC2Client, DescribeInstancesCommand } from "@aws-sdk/client-ec2";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const INSTANCE_ID = process.env.INSTANCE_ID;
const ROSTER_PARAM = process.env.ROSTER_PARAM;
const TOKEN_PARAM = process.env.TOKEN_PARAM;
const SERVER_ADDRESS = process.env.SERVER_ADDRESS ?? "";
const AWS_REGION = process.env.AWS_REGION ?? "us-east-1";

// Discord rejects a custom-status `state` longer than this.
const MAX_STATE_LENGTH = 128;

const GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json";
const REFRESH_INTERVAL_MS = 30_000;

// A roster older than this means the game box stopped publishing (shutting down,
// or the watcher died). Report the instance state alone rather than a stale count.
const ROSTER_MAX_AGE_SECONDS = 360;

// Discord gateway opcodes (https://discord.com/developers/docs/topics/gateway-events)
const Op = {
  DISPATCH: 0,
  HEARTBEAT: 1,
  IDENTIFY: 2,
  PRESENCE_UPDATE: 3,
  RESUME: 6,
  RECONNECT: 7,
  INVALID_SESSION: 9,
  HELLO: 10,
  HEARTBEAT_ACK: 11,
};

// Custom status (4) is the only activity type whose text renders verbatim. GAME
// prefixes "Playing", WATCHING prefixes a "Watching" line that is easy to miss and
// pushes the real text underneath it. The `name` must literally be "Custom Status";
// Discord displays the `state` field.
const CUSTOM_STATUS = 4;
const customStatus = (state) => [
  {
    name: "Custom Status",
    type: CUSTOM_STATUS,
    state: state.length > MAX_STATE_LENGTH ? `${state.slice(0, MAX_STATE_LENGTH - 1)}…` : state,
  },
];

const ec2 = new EC2Client({ region: AWS_REGION });
const ssm = new SSMClient({ region: AWS_REGION });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function readToken() {
  const result = await ssm.send(new GetParameterCommand({ Name: TOKEN_PARAM, WithDecryption: true }));
  const token = result.Parameter?.Value;
  if (!token || token === "None") throw new Error(`${TOKEN_PARAM} is unset`);
  return token;
}

async function instanceState() {
  try {
    const described = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [INSTANCE_ID] }));
    return described.Reservations?.[0]?.Instances?.[0]?.State?.Name ?? "unknown";
  } catch (error) {
    console.error("DescribeInstances failed", error?.name ?? error);
    return "unknown";
  }
}

async function readRoster() {
  try {
    const result = await ssm.send(new GetParameterCommand({ Name: ROSTER_PARAM }));
    const roster = JSON.parse(result.Parameter?.Value ?? "{}");
    if (typeof roster.count !== "number" || typeof roster.updated !== "number") return null;
    if (Math.floor(Date.now() / 1000) - roster.updated > ROSTER_MAX_AGE_SECONDS) return null;
    return roster;
  } catch (error) {
    console.error("roster read failed", error?.name ?? error);
    return null;
  }
}

// Presence is the ONLY thing this daemon exists to produce. Keep the mapping honest:
// never imply players are online from a roster we don't trust.
async function buildPresence() {
  const state = await instanceState();

  if (state === "pending") {
    return { status: "idle", activities: customStatus("⏳ Server starting — ready in ~2 min") };
  }
  if (state !== "running") {
    return { status: "idle", activities: customStatus("💤 Server offline — /palworld-start to wake it") };
  }

  const roster = await readRoster();
  if (!roster) {
    // Instance is up but the box isn't publishing: booting, or the watcher is down.
    // Don't invent a player count.
    return { status: "online", activities: customStatus(`🟢 Server up — ${SERVER_ADDRESS}`) };
  }
  if (roster.count === 0) {
    return { status: "online", activities: customStatus(`🟢 Server up, nobody online — ${SERVER_ADDRESS}`) };
  }

  const plural = roster.count === 1 ? "player" : "players";
  return {
    status: "online",
    activities: customStatus(`🎮 ${roster.count} ${plural} online — ${roster.names}`),
  };
}

function connect(token) {
  return new Promise((resolve) => {
    const socket = new WebSocket(GATEWAY_URL);

    let heartbeatTimer = null;
    let refreshTimer = null;
    let lastSequence = null;
    let acked = true;

    const shutdown = (why) => {
      clearInterval(heartbeatTimer);
      clearInterval(refreshTimer);
      try {
        socket.close();
      } catch {}
      resolve(why);
    };

    const send = (payload) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
    };

    const pushPresence = async () => {
      try {
        const presence = await buildPresence();
        send({ op: Op.PRESENCE_UPDATE, d: { since: null, afk: false, ...presence } });
        console.log("presence ->", presence.activities[0].name, `(${presence.status})`);
      } catch (error) {
        console.error("presence build failed", error);
      }
    };

    socket.addEventListener("open", () => console.log("gateway connected"));

    socket.addEventListener("message", async (event) => {
      const payload = JSON.parse(event.data);
      if (payload.s !== null && payload.s !== undefined) lastSequence = payload.s;

      switch (payload.op) {
        case Op.HELLO: {
          const interval = payload.d.heartbeat_interval;
          // A missed ACK means the socket is a zombie: reconnect rather than sit silent.
          heartbeatTimer = setInterval(() => {
            if (!acked) return shutdown("heartbeat not acked");
            acked = false;
            send({ op: Op.HEARTBEAT, d: lastSequence });
          }, interval);

          send({
            op: Op.IDENTIFY,
            d: {
              token,
              // Zero intents: this bot receives nothing. It only publishes presence.
              intents: 0,
              properties: { os: "linux", browser: "palworld-presence", device: "palworld-presence" },
              presence: await buildPresence(),
            },
          });
          break;
        }

        case Op.HEARTBEAT:
          send({ op: Op.HEARTBEAT, d: lastSequence });
          break;

        case Op.HEARTBEAT_ACK:
          acked = true;
          break;

        case Op.DISPATCH:
          if (payload.t === "READY") {
            console.log(`identified as ${payload.d?.user?.username}`);
            refreshTimer = setInterval(pushPresence, REFRESH_INTERVAL_MS);
          }
          break;

        case Op.RECONNECT:
          return shutdown("gateway asked us to reconnect");

        case Op.INVALID_SESSION:
          return shutdown("invalid session");
      }
    });

    socket.addEventListener("error", (event) => console.error("socket error", event?.message ?? event));
    socket.addEventListener("close", (event) => shutdown(`socket closed ${event.code} ${event.reason}`));
  });
}

// Reconnect forever with capped exponential backoff. systemd would restart us anyway,
// but staying up avoids losing presence for a service-restart interval.
async function main() {
  const token = await readToken();
  let backoffMs = 1_000;

  for (;;) {
    const why = await connect(token);
    console.error(`disconnected: ${why}; reconnecting in ${backoffMs}ms`);
    await sleep(backoffMs);
    backoffMs = Math.min(backoffMs * 2, 60_000);
    // A connection that lived long enough to be healthy shouldn't inherit old backoff.
    if (why === "gateway asked us to reconnect") backoffMs = 1_000;
  }
}

main().catch((error) => {
  console.error("fatal", error);
  process.exit(1);
});
