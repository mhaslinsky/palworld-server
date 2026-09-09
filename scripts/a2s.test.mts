import { strict as assert } from "node:assert";
import { createSocket } from "node:dgram";
import test from "node:test";
import { buildInfoRequest, parseInfoResponse, queryInfo } from "./a2s.mts";

function nullTerminated(value: string): Buffer {
  return Buffer.concat([Buffer.from(value, "utf8"), Buffer.from([0])]);
}

function syntheticInfoResponse(serverName: string, players: number, maxPlayers: number): Buffer {
  return Buffer.concat([
    Buffer.from([0xff, 0xff, 0xff, 0xff, 0x49, 1]),
    nullTerminated(serverName),
    nullTerminated("ValheimWorld"),
    nullTerminated("valheim"),
    nullTerminated("Valheim"),
    Buffer.from([0, 0, players, maxPlayers, 0, 100, 108, 0, 0]),
    nullTerminated("1.0.0"),
  ]);
}

test("A2S_INFO response round trip decodes the server name and player counts", () => {
  const response = syntheticInfoResponse("Valheim Friends", 3, 10);
  assert.deepEqual(parseInfoResponse(response), {
    players: 3,
    maxPlayers: 10,
    serverName: "Valheim Friends",
  });
});

test("A2S_INFO requests append a four-byte challenge", () => {
  const challenge = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  const request = buildInfoRequest(challenge);
  assert.deepEqual(request.subarray(-4), challenge);
  assert.deepEqual(request.subarray(0, -4), buildInfoRequest());
});

test("queryInfo retries a challenge with the challenge bytes appended", async () => {
  const server = createSocket("udp4");
  const challenge = Buffer.from([0x12, 0x34, 0x56, 0x78]);
  const receivedPackets: Buffer[] = [];
  const serverReady = new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.bind(0, "127.0.0.1", () => resolve());
  });

  server.on("message", (message, remoteInfo) => {
    receivedPackets.push(Buffer.from(message));
    if (receivedPackets.length === 1) {
      server.send(Buffer.concat([Buffer.from([0xff, 0xff, 0xff, 0xff, 0x41]), challenge]), remoteInfo.port, remoteInfo.address);
      return;
    }
    server.send(syntheticInfoResponse("Challenge Server", 2, 10), remoteInfo.port, remoteInfo.address);
  });

  await serverReady;
  const serverAddress = server.address();
  if (typeof serverAddress !== "object" || serverAddress === null) {
    throw new Error("Test UDP server did not expose an address");
  }

  try {
    const info = await queryInfo("127.0.0.1", serverAddress.port, 1000);
    assert.deepEqual(info, { players: 2, maxPlayers: 10, serverName: "Challenge Server" });
    assert.equal(receivedPackets.length, 2);
    assert.deepEqual(receivedPackets[0], buildInfoRequest());
    assert.deepEqual(receivedPackets[1], buildInfoRequest(challenge));
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((closeError) => {
        if (closeError !== undefined) {
          reject(closeError);
          return;
        }
        resolve();
      });
    });
  }
});
