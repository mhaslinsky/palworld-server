#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { parseConf, decide, extractNames, parseIdleSince } from "./idle-logic.mts";
import { queryInfo } from "./a2s.mts";
import type { IdleDecision } from "./idle-logic.mts";

const CONFIG_PATH = "/etc/valheim/idle.conf";
const STATE_DIR = "/run/valheim";
const IDLE_SINCE_PATH = `${STATE_DIR}/idle_since`;
const WARNED_PATH = `${STATE_DIR}/warned`;
const ANNOUNCED_UP_PATH = `${STATE_DIR}/announced_up`;
const QUERY_TIMEOUT_MS = 5000;
type LoggedDecision = IdleDecision | "shutdown_cancelled";

type ShutdownOutcome = { status: "shutdown" } | { status: "shutdown_cancelled"; count: number | null };

interface IdleConfig {
  queryPort: number;
  thresholdMin: number;
  warnBeforeMin: number;
  serverLabel: string;
  serverAddress: string;
  awsRegion: string;
  webhookParam: string;
  rosterParam: string;
}

interface IdleState {
  idleSince: number | null;
  warned: boolean;
  announcedUp: boolean;
}

interface CommandResult {
  code: number;
  errorMessage: string;
  signal: string | null;
  stdout: string;
  stderr: string;
}

function positiveInteger(configuration: Record<string, string>, key: string, fallback: number): number {
  const rawValue = configuration[key];
  if (rawValue === undefined || rawValue === "") {
    return fallback;
  }
  const parsedValue = Number(rawValue);
  if (!Number.isInteger(parsedValue) || parsedValue < 1) {
    throw new Error(`${key} must be a positive integer`);
  }
  return parsedValue;
}

function nonNegativeNumber(configuration: Record<string, string>, key: string, fallback: number): number {
  const rawValue = configuration[key];
  if (rawValue === undefined || rawValue === "") {
    return fallback;
  }
  const parsedValue = Number(rawValue);
  if (!Number.isFinite(parsedValue) || parsedValue < 0) {
    throw new Error(`${key} must be a non-negative number`);
  }
  return parsedValue;
}

function loadConfig(): IdleConfig {
  const text = readFileSync(CONFIG_PATH, "utf8");
  const configuration = parseConf(text);
  const queryPort = positiveInteger(configuration, "QUERY_PORT", 2457);
  if (queryPort > 65535) {
    throw new Error("QUERY_PORT must be between 1 and 65535");
  }

  const thresholdMin = nonNegativeNumber(configuration, "THRESHOLD_MIN", 25);
  const warnBeforeMin = nonNegativeNumber(configuration, "WARN_BEFORE_MIN", 5);
  if (warnBeforeMin > thresholdMin) {
    throw new Error("WARN_BEFORE_MIN must not exceed THRESHOLD_MIN");
  }

  return {
    queryPort,
    thresholdMin,
    warnBeforeMin,
    serverLabel: configuration.SERVER_LABEL ?? "Valheim",
    serverAddress: configuration.SERVER_ADDRESS ?? "",
    awsRegion: configuration.AWS_REGION ?? "us-east-1",
    webhookParam: configuration.WEBHOOK_PARAM ?? "",
    rosterParam: configuration.ROSTER_PARAM ?? "",
  };
}

function errorCode(error: unknown): number {
  if (typeof error === "object" && error !== null && "code" in error && typeof error.code === "number") {
    return error.code;
  }
  return 1;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") {
    return error.message;
  }
  return String(error);
}

function errorSignal(error: unknown): string | null {
  if (typeof error === "object" && error !== null && "signal" in error && typeof error.signal === "string") {
    return error.signal;
  }
  return null;
}

function runCommand(command: string, argumentsList: string[], timeoutMs: number): Promise<CommandResult> {
  return new Promise((resolve) => {
    execFile(command, argumentsList, { encoding: "utf8", timeout: timeoutMs }, (error, stdout, stderr) => {
      resolve({
        code: error === null ? 0 : errorCode(error),
        errorMessage: error === null ? "" : errorMessage(error),
        signal: error === null ? null : errorSignal(error),
        stdout: String(stdout),
        stderr: String(stderr),
      });
    });
  });
}

function commandFailureReason(result: CommandResult): string {
  const details = [`exit ${result.code}`];
  if (result.errorMessage !== "") {
    details.push(result.errorMessage);
  }
  if (result.signal !== null) {
    details.push(`signal=${result.signal}`);
  }
  const standardError = result.stderr.trim();
  if (standardError !== "") {
    details.push(standardError);
  }
  return details.join("; ");
}

function readIdleState(): IdleState {
  let idleSince: number | null = null;
  if (existsSync(IDLE_SINCE_PATH)) {
    const rawIdleSince = readFileSync(IDLE_SINCE_PATH, "utf8").trim();
    idleSince = parseIdleSince(rawIdleSince);
    if (idleSince === null) {
      removeStateFile(IDLE_SINCE_PATH);
    }
  }
  return {
    idleSince,
    warned: existsSync(WARNED_PATH),
    announcedUp: existsSync(ANNOUNCED_UP_PATH),
  };
}

function removeStateFile(path: string): void {
  try {
    unlinkSync(path);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) {
      throw error;
    }
  }
}

function resetIdleState(): void {
  removeStateFile(IDLE_SINCE_PATH);
  removeStateFile(WARNED_PATH);
}

function markStateFile(path: string): void {
  writeFileSync(path, "", "utf8");
}

function startIdleClock(nowSeconds: number): void {
  writeFileSync(IDLE_SINCE_PATH, String(nowSeconds), "utf8");
  removeStateFile(WARNED_PATH);
}

async function webhookUrl(config: IdleConfig): Promise<string | null> {
  if (config.webhookParam === "") {
    return null;
  }
  const result = await runCommand(
    "aws",
    [
      "ssm",
      "get-parameter",
      "--name",
      config.webhookParam,
      "--with-decryption",
      "--region",
      config.awsRegion,
      "--query",
      "Parameter.Value",
      "--output",
      "text",
    ],
    QUERY_TIMEOUT_MS,
  );
  if (result.code !== 0) {
    console.error(`webhook lookup failed: ${commandFailureReason(result)}`);
    return null;
  }
  const value = result.stdout.trim();
  return value === "" || value === "None" ? null : value;
}

async function createNotifier(config: IdleConfig): Promise<(content: string) => Promise<void>> {
  let loaded = false;
  let cachedUrl: string | null = null;
  return async (content: string): Promise<void> => {
    if (!loaded) {
      cachedUrl = await webhookUrl(config);
      loaded = true;
    }
    if (cachedUrl === null) {
      return;
    }
    try {
      const response = await fetch(cachedUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content }),
        signal: AbortSignal.timeout(QUERY_TIMEOUT_MS),
      });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Discord notification failed: ${reason}`);
    }
  };
}

async function publishRoster(config: IdleConfig, count: number, names: string, updated: number): Promise<void> {
  if (config.rosterParam === "") {
    return;
  }
  const roster = JSON.stringify({ count, names, updated });
  const result = await runCommand(
    "aws",
    [
      "ssm",
      "put-parameter",
      "--name",
      config.rosterParam,
      "--type",
      "String",
      "--overwrite",
      "--value",
      roster,
      "--region",
      config.awsRegion,
    ],
    QUERY_TIMEOUT_MS,
  );
  if (result.code !== 0) {
    console.error(`roster publish failed: ${commandFailureReason(result)}`);
  }
}

function logDecision(decision: LoggedDecision, count: number | null): void {
  console.log(`decision=${decision} players=${count === null ? "unknown" : count}`);
}

async function shutdown(config: IdleConfig, notifier: (content: string) => Promise<void>): Promise<ShutdownOutcome> {
  await notifier(
    `🛑 **${config.serverLabel}** has been empty for ${config.thresholdMin} min, shutting down to save money. Start it again with \`/valheim-start\`.`,
  );
  let latestCount: number | null = null;
  try {
    latestCount = (await queryInfo("127.0.0.1", config.queryPort, QUERY_TIMEOUT_MS)).players;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`A2S shutdown recheck failed: ${reason}`);
  }
  if (latestCount === null || latestCount !== 0) {
    return { status: "shutdown_cancelled", count: latestCount };
  }

  const result = await runCommand("/sbin/shutdown", ["-h", "now", "valheim idle shutdown"], QUERY_TIMEOUT_MS);
  if (result.code !== 0) {
    throw new Error(`shutdown failed: ${commandFailureReason(result)}`);
  }
  return { status: "shutdown" };
}

export async function main(): Promise<void> {
  const config = loadConfig();
  mkdirSync(STATE_DIR, { recursive: true });
  const state = readIdleState();
  const nowSeconds = Math.floor(Date.now() / 1000);
  const notifier = await createNotifier(config);

  let playerCount: number | null = null;
  try {
    const info = await queryInfo("127.0.0.1", config.queryPort, QUERY_TIMEOUT_MS);
    playerCount = info.players;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`A2S query failed: ${reason}`);
  }

  if (playerCount === null) {
    resetIdleState();
    logDecision("unknown", null);
    process.exitCode = 1;
    return;
  }

  const journalResult = await runCommand(
    "journalctl",
    ["-u", "valheim", "-o", "cat", "--since", "-3 min"],
    QUERY_TIMEOUT_MS,
  );
  const names = journalResult.code === 0 ? extractNames(journalResult.stdout) : "";
  if (journalResult.code !== 0) {
    console.error(`journal lookup failed: ${commandFailureReason(journalResult)}`);
  }
  await publishRoster(config, playerCount, names, nowSeconds);

  if (!state.announcedUp) {
    markStateFile(ANNOUNCED_UP_PATH);
    await notifier(`🟢 **${config.serverLabel}** is up, join at \`${config.serverAddress}\``);
  }

  const decision = decide({
    count: playerCount,
    nowSeconds,
    idleSince: state.idleSince,
    warned: state.warned,
    thresholdMin: config.thresholdMin,
    warnBeforeMin: config.warnBeforeMin,
  });

  if (decision === "reset") {
    resetIdleState();
  } else if (decision === "start_clock") {
    startIdleClock(nowSeconds);
  } else if (decision === "warn") {
    markStateFile(WARNED_PATH);
    await notifier(
      `⏰ **${config.serverLabel}** is empty, shutting down in about ${config.thresholdMin - Math.floor((nowSeconds - (state.idleSince ?? nowSeconds)) / 60)} min. Join now to keep it alive.`,
    );
  } else if (decision === "shutdown") {
    const shutdownOutcome = await shutdown(config, notifier);
    if (shutdownOutcome.status === "shutdown_cancelled") {
      resetIdleState();
      logDecision("shutdown_cancelled", shutdownOutcome.count);
      return;
    }
  }

  logDecision(decision, playerCount);
}

if (import.meta.main) {
  main().catch((error: unknown) => {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`idle watcher failed: ${reason}`);
    process.exitCode = 1;
  });
}
