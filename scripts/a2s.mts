#!/usr/bin/env node

import { createSocket } from "node:dgram";
import type { Socket } from "node:dgram";

const A2S_PACKET_HEADER = Buffer.from([0xff, 0xff, 0xff, 0xff]);
const A2S_INFO_REQUEST = Buffer.from("Source Engine Query\0", "ascii");
const A2S_INFO_RESPONSE = 0x49;
const A2S_CHALLENGE_RESPONSE = 0x41;

export interface A2SInfo {
  players: number;
  maxPlayers: number;
  serverName: string;
}

export function buildInfoRequest(challenge?: Buffer): Buffer {
  if (challenge !== undefined && challenge.length !== 4) {
    throw new Error("A2S challenge must contain exactly four bytes");
  }

  const challengeSuffix = challenge === undefined ? Buffer.alloc(0) : challenge;
  return Buffer.concat([A2S_PACKET_HEADER, Buffer.from([0x54]), A2S_INFO_REQUEST, challengeSuffix]);
}

function readNullTerminatedString(buffer: Buffer, startOffset: number): { value: string; nextOffset: number } {
  const terminatorOffset = buffer.indexOf(0, startOffset);
  if (terminatorOffset === -1) {
    throw new Error("A2S_INFO response has an unterminated string");
  }

  return {
    value: buffer.toString("utf8", startOffset, terminatorOffset),
    nextOffset: terminatorOffset + 1,
  };
}

export function parseInfoResponse(buffer: Buffer): A2SInfo {
  if (buffer.length < 6 || !buffer.subarray(0, 4).equals(A2S_PACKET_HEADER)) {
    throw new Error("A2S_INFO response has an invalid packet header");
  }
  if (buffer[4] !== A2S_INFO_RESPONSE) {
    throw new Error(`Unexpected A2S response type: 0x${buffer[4].toString(16)}`);
  }

  let cursor = 6;
  const serverNameField = readNullTerminatedString(buffer, cursor);
  cursor = serverNameField.nextOffset;
  const mapField = readNullTerminatedString(buffer, cursor);
  cursor = mapField.nextOffset;
  const folderField = readNullTerminatedString(buffer, cursor);
  cursor = folderField.nextOffset;
  const gameField = readNullTerminatedString(buffer, cursor);
  cursor = gameField.nextOffset;

  if (cursor + 4 > buffer.length) {
    throw new Error("A2S_INFO response ends before player counts");
  }

  buffer.readInt16LE(cursor);
  cursor += 2;
  const players = buffer[cursor];
  const maxPlayers = buffer[cursor + 1];
  if (players === undefined || maxPlayers === undefined) {
    throw new Error("A2S_INFO response does not contain player counts");
  }

  return { players, maxPlayers, serverName: serverNameField.value };
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function closeSocket(socket: Socket): void {
  try {
    socket.close();
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ERR_SOCKET_DGRAM_NOT_RUNNING")) {
      throw error;
    }
  }
}

export function queryInfo(host: string, port: number, timeoutMs: number): Promise<A2SInfo> {
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return Promise.reject(new Error(`Invalid A2S port: ${port}`));
  }
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return Promise.reject(new Error(`Invalid A2S timeout: ${timeoutMs}`));
  }

  return new Promise((resolve, reject) => {
    const socket = createSocket("udp4");
    let settled = false;
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined;

    const finish = (error: Error | undefined, info: A2SInfo | undefined): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timeoutHandle !== undefined) {
        clearTimeout(timeoutHandle);
      }
      closeSocket(socket);
      if (error !== undefined) {
        reject(error);
      } else if (info !== undefined) {
        resolve(info);
      } else {
        reject(new Error("A2S query completed without a result"));
      }
    };

    const sendRequest = (challenge?: Buffer): void => {
      socket.send(buildInfoRequest(challenge), port, host, (sendError) => {
        if (sendError !== null) {
          finish(asError(sendError), undefined);
        }
      });
    };

    socket.on("error", (socketError) => finish(asError(socketError), undefined));
    socket.on("message", (message) => {
      try {
        if (message.length < 5 || !message.subarray(0, 4).equals(A2S_PACKET_HEADER)) {
          throw new Error("A2S response has an invalid packet header");
        }
        if (message[4] === A2S_CHALLENGE_RESPONSE) {
          if (message.length < 9) {
            throw new Error("A2S challenge response is missing its four-byte challenge");
          }
          sendRequest(message.subarray(5, 9));
          return;
        }
        finish(undefined, parseInfoResponse(message));
      } catch (error) {
        finish(asError(error), undefined);
      }
    });

    timeoutHandle = setTimeout(() => finish(new Error(`A2S query timed out after ${timeoutMs} ms`), undefined), timeoutMs);
    sendRequest();
  });
}
