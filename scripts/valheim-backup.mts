#!/usr/bin/env node

import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { promises as fsPromises } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  chooseKey,
  freshness,
  parseMinBytes,
  parseConf,
  sizeGate,
  sizesMatch,
  tarExitAcceptable,
} from "./backup-gates.mts";
import type { BackupConfig } from "./backup-gates.mts";

const CONFIG_PATH = "/etc/valheim/idle.conf";
const DEFAULT_COMMAND_TIMEOUT_MS = 120_000;
const TAR_COMMAND_TIMEOUT_MS = 300_000;
const PROCESS_KILL_GRACE_MS = 5_000;
const BACKUP_DEADLINE_MS = 240_000;
const FRESHNESS_SLACK_SECONDS = 120;
const OPTIONAL_ARCHIVE_FILES = ["adminlist.txt", "bannedlist.txt", "permittedlist.txt"];

interface CommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  failureReason: string | undefined;
}

interface CommandOptions {
  captureStdout: boolean;
  timeoutMs?: number;
  deadlineAtMs?: number;
}

interface FreshnessScan {
  newestMtimeSeconds: number | null;
  failureReason: string | undefined;
}

interface BackupResult {
  key: string;
  size: number;
  degradedReason: string | undefined;
}

class BackupFailure extends Error {}

let activeChildProcess: ChildProcess | undefined;
let activeTemporaryDirectory: string | undefined;
let shutdownRequested = false;

function describeError(error: unknown): string {
  if (error instanceof Error && error.message !== "") {
    return error.message;
  }

  return String(error);
}

function normalizedReason(reason: string): string {
  return reason.trim().replace(/\s+/g, " ");
}

function hasErrorCode(error: unknown, expectedCode: string): boolean {
  if (typeof error !== "object" || error === null || !("code" in error)) {
    return false;
  }

  return (error as { code?: unknown }).code === expectedCode;
}

function runCommand(
  commandName: string,
  argumentsList: string[],
  options: CommandOptions,
): Promise<CommandResult> {
  const requestedTimeoutMs = options.timeoutMs ?? DEFAULT_COMMAND_TIMEOUT_MS;
  const remainingDeadlineMs = options.deadlineAtMs === undefined
    ? requestedTimeoutMs
    : options.deadlineAtMs - Date.now();
  const timeoutMs = Math.min(requestedTimeoutMs, remainingDeadlineMs);

  if (timeoutMs <= 0) {
    return Promise.resolve({
      exitCode: 124,
      stdout: "",
      stderr: "",
      failureReason: `${commandName} timeout deadline exceeded before start`,
    });
  }

  return new Promise((resolveCommand) => {
    let stdoutText = "";
    let stderrText = "";
    let settled = false;
    let timeoutReason: string | undefined;
    let timeoutTimer: ReturnType<typeof setTimeout> | undefined;
    let killTimer: ReturnType<typeof setTimeout> | undefined;
    let forceResolveTimer: ReturnType<typeof setTimeout> | undefined;
    const childProcess = spawn(commandName, argumentsList, {
      stdio: ["ignore", options.captureStdout ? "pipe" : "ignore", "pipe"],
    });
    activeChildProcess = childProcess;

    const finishCommand = (result: CommandResult): void => {
      if (settled) {
        return;
      }

      settled = true;
      if (timeoutTimer !== undefined) {
        clearTimeout(timeoutTimer);
      }
      if (killTimer !== undefined) {
        clearTimeout(killTimer);
      }
      if (forceResolveTimer !== undefined) {
        clearTimeout(forceResolveTimer);
      }
      if (activeChildProcess === childProcess) {
        activeChildProcess = undefined;
      }
      resolveCommand(result);
    };

    if (options.captureStdout && childProcess.stdout !== null) {
      childProcess.stdout.setEncoding("utf8");
      childProcess.stdout.on("data", (dataChunk: string) => {
        stdoutText += dataChunk;
      });
    }

    if (childProcess.stderr !== null) {
      childProcess.stderr.setEncoding("utf8");
      childProcess.stderr.on("data", (dataChunk: string) => {
        stderrText += dataChunk;
      });
    }

    childProcess.once("error", (error: Error) => {
      stderrText = `${stderrText}${describeError(error)}`;
      finishCommand({
        exitCode: timeoutReason === undefined ? 1 : 124,
        stdout: stdoutText,
        stderr: stderrText,
        failureReason: timeoutReason,
      });
    });

    childProcess.once("close", (exitCode: number | null) => {
      finishCommand({
        exitCode: timeoutReason === undefined ? (exitCode ?? 1) : 124,
        stdout: stdoutText,
        stderr: stderrText,
        failureReason: timeoutReason,
      });
    });

    timeoutTimer = setTimeout(() => {
      timeoutReason = `${commandName} timed out after ${Math.ceil(timeoutMs / 1000)}s`;
      childProcess.kill("SIGTERM");
      killTimer = setTimeout(() => {
        childProcess.kill("SIGKILL");
        forceResolveTimer = setTimeout(() => {
          finishCommand({
            exitCode: 124,
            stdout: stdoutText,
            stderr: stderrText,
            failureReason: timeoutReason,
          });
        }, 1_000);
      }, PROCESS_KILL_GRACE_MS);
    }, timeoutMs);
  });
}

function commandFailure(result: CommandResult, action: string): BackupFailure {
  if (result.failureReason !== undefined) {
    return new BackupFailure(`${action}: ${result.failureReason}`);
  }

  const detailText = normalizedReason(result.stderr);
  const suffix = detailText === "" ? ` (exit ${result.exitCode})` : ` (exit ${result.exitCode}): ${detailText}`;
  return new BackupFailure(`${action}${suffix}`);
}

function numericConfigValue(config: BackupConfig, keyName: keyof BackupConfig, minimumValue: number): number {
  const rawValue = config[keyName];
  const numericValue = Number(rawValue);
  if (rawValue.trim() === "" || !Number.isFinite(numericValue) || numericValue < minimumValue) {
    throw new BackupFailure(`${keyName} must be a number at least ${minimumValue}`);
  }

  return numericValue;
}

function worldRelativePath(worldName: string): string {
  if (
    worldName === "" ||
    worldName === "." ||
    worldName === ".." ||
    worldName.includes("/") ||
    worldName.includes("\\") ||
    worldName.includes("\0")
  ) {
    throw new BackupFailure("WORLD_NAME must be one directory name");
  }

  return join("worlds_local", worldName);
}

async function inspectWorldDirectory(directoryPath: string): Promise<FreshnessScan> {
  const pendingDirectories = [directoryPath];
  let newestMtimeSeconds: number | null = null;
  let failureReason: string | undefined;

  while (pendingDirectories.length > 0) {
    const currentDirectory = pendingDirectories.pop();
    if (currentDirectory === undefined) {
      break;
    }

    let directoryEntries;
    try {
      directoryEntries = await fsPromises.readdir(currentDirectory, { withFileTypes: true });
    } catch (error) {
      failureReason ??= `could not inspect ${currentDirectory}: ${describeError(error)}`;
      continue;
    }

    for (const directoryEntry of directoryEntries) {
      const entryPath = join(currentDirectory, directoryEntry.name);
      if (directoryEntry.isDirectory()) {
        pendingDirectories.push(entryPath);
        continue;
      }

      if (!directoryEntry.isFile()) {
        continue;
      }

      try {
        const fileStats = await fsPromises.stat(entryPath);
        const fileMtimeSeconds = fileStats.mtimeMs / 1000;
        if (!Number.isFinite(fileMtimeSeconds)) {
          failureReason ??= `invalid mtime for ${entryPath}`;
          continue;
        }

        if (newestMtimeSeconds === null || fileMtimeSeconds > newestMtimeSeconds) {
          newestMtimeSeconds = fileMtimeSeconds;
        }
      } catch (error) {
        failureReason ??= `could not stat ${entryPath}: ${describeError(error)}`;
      }
    }
  }

  return { newestMtimeSeconds, failureReason };
}

async function archiveEntries(savedir: string, worldPath: string): Promise<string[]> {
  const entries = [worldPath];

  for (const optionalFile of OPTIONAL_ARCHIVE_FILES) {
    const optionalPath = join(savedir, optionalFile);
    try {
      const optionalStats = await fsPromises.stat(optionalPath);
      if (!optionalStats.isFile()) {
        throw new BackupFailure(`${optionalFile} exists but is not a regular file`);
      }

      entries.push(optionalFile);
    } catch (error) {
      if (hasErrorCode(error, "ENOENT")) {
        continue;
      }

      throw error;
    }
  }

  return entries;
}

async function createArchive(
  archivePath: string,
  savedir: string,
  entries: string[],
  deadlineAtMs: number,
): Promise<void> {
  const tarResult = await runCommand(
    "tar",
    ["-czf", archivePath, "-C", savedir, "--", ...entries],
    { captureStdout: false, timeoutMs: TAR_COMMAND_TIMEOUT_MS, deadlineAtMs },
  );

  if (!tarExitAcceptable(tarResult.exitCode)) {
    throw commandFailure(tarResult, "tar failed");
  }
}

async function verifyArchive(archivePath: string, deadlineAtMs: number): Promise<void> {
  const integrityResult = await runCommand(
    "tar",
    ["-tzf", archivePath],
    { captureStdout: false, timeoutMs: TAR_COMMAND_TIMEOUT_MS, deadlineAtMs },
  );
  if (integrityResult.exitCode !== 0) {
    throw commandFailure(integrityResult, "archive fails integrity check");
  }
}

async function uploadAndVerify(
  archivePath: string,
  archiveSize: number,
  config: BackupConfig,
  key: string,
  deadlineAtMs: number,
): Promise<void> {
  const destination = `s3://${config.BACKUP_BUCKET}/${key}`;
  const uploadResult = await runCommand(
    "aws",
    [
      "s3",
      "cp",
      archivePath,
      destination,
      "--region",
      config.AWS_REGION,
      "--cli-connect-timeout",
      "10",
      "--cli-read-timeout",
      "60",
      "--only-show-errors",
    ],
    { captureStdout: false, deadlineAtMs },
  );
  if (uploadResult.exitCode !== 0) {
    throw commandFailure(uploadResult, "s3 upload failed");
  }

  const listResult = await runCommand(
    "aws",
    [
      "s3api",
      "list-objects-v2",
      "--bucket",
      config.BACKUP_BUCKET,
      "--prefix",
      key,
      "--region",
      config.AWS_REGION,
      "--query",
      `Contents[?Key=='${key}'].Size | [0]`,
      "--output",
      "text",
      "--cli-connect-timeout",
      "10",
      "--cli-read-timeout",
      "60",
    ],
    { captureStdout: true, deadlineAtMs },
  );
  if (listResult.exitCode !== 0) {
    throw commandFailure(listResult, "could not verify uploaded object");
  }

  if (!sizesMatch(archiveSize, listResult.stdout)) {
    throw new BackupFailure(
      `size mismatch after upload: local=${archiveSize} remote=${normalizedReason(listResult.stdout)}`,
    );
  }
}

export async function runBackup(): Promise<BackupResult> {
  const configText = await fsPromises.readFile(CONFIG_PATH, "utf8");
  const config = parseConf(configText);
  const saveIntervalSeconds = numericConfigValue(config, "SAVE_INTERVAL_SECONDS", 0);
  const minimumBytes = parseMinBytes(config.BACKUP_MIN_BYTES);
  const relativeWorldPath = worldRelativePath(config.WORLD_NAME);
  const worldDirectory = join(config.SAVEDIR, relativeWorldPath);
  let worldStats;
  try {
    worldStats = await fsPromises.stat(worldDirectory);
  } catch (error) {
    if (hasErrorCode(error, "ENOENT")) {
      throw new BackupFailure(`world directory not found: ${worldDirectory}`);
    }

    throw error;
  }
  if (!worldStats.isDirectory()) {
    throw new BackupFailure(`${worldDirectory} is not a directory`);
  }

  const deadlineAtMs = Date.now() + BACKUP_DEADLINE_MS;
  const backupTimestamp = new Date();
  const freshnessScan = await inspectWorldDirectory(worldDirectory);
  const freshnessDecision = freshnessScan.failureReason === undefined
    ? freshness({
      newestMtimeSeconds: freshnessScan.newestMtimeSeconds,
      nowSeconds: backupTimestamp.getTime() / 1000,
      intervalSeconds: saveIntervalSeconds,
      slackSeconds: FRESHNESS_SLACK_SECONDS,
    })
    : `degraded:${freshnessScan.failureReason}`;
  const degradedReason = freshnessDecision.startsWith("degraded:")
    ? freshnessDecision.slice("degraded:".length)
    : undefined;
  const key = chooseKey({ degraded: degradedReason !== undefined, timestamp: backupTimestamp });

  const temporaryDirectory = await fsPromises.mkdtemp(join(tmpdir(), "valheim-backup-"));
  activeTemporaryDirectory = temporaryDirectory;
  const archivePath = join(temporaryDirectory, basename(key));
  let operationFailed = false;

  try {
    const entries = await archiveEntries(config.SAVEDIR, relativeWorldPath);
    await createArchive(archivePath, config.SAVEDIR, entries, deadlineAtMs);
    await verifyArchive(archivePath, deadlineAtMs);

    const archiveStats = await fsPromises.stat(archivePath);
    if (!sizeGate(archiveStats.size, minimumBytes)) {
      throw new BackupFailure(
        `archive only ${archiveStats.size}B, below ${minimumBytes}B floor, refusing to publish a suspect backup`,
      );
    }

    await uploadAndVerify(archivePath, archiveStats.size, config, key, deadlineAtMs);
    return { key, size: archiveStats.size, degradedReason };
  } catch (error) {
    operationFailed = true;
    throw error;
  } finally {
    try {
      await fsPromises.rm(temporaryDirectory, { recursive: true, force: true });
      if (activeTemporaryDirectory === temporaryDirectory) {
        activeTemporaryDirectory = undefined;
      }
    } catch (error) {
      console.error(`BACKUP_CLEANUP_FAILED: ${normalizedReason(describeError(error))}`);
      if (!operationFailed) {
        throw new BackupFailure(`temporary directory cleanup failed: ${describeError(error)}`);
      }
    }
  }
}

function installSignalHandlers(): () => void {
  const handleSignal = (signalName: "SIGTERM" | "SIGINT"): void => {
    if (shutdownRequested) {
      return;
    }

    shutdownRequested = true;
    activeChildProcess?.kill("SIGTERM");
    void (async () => {
      if (activeTemporaryDirectory !== undefined) {
        try {
          await fsPromises.rm(activeTemporaryDirectory, { recursive: true, force: true });
          activeTemporaryDirectory = undefined;
        } catch (error) {
          console.error(`BACKUP_CLEANUP_FAILED: ${normalizedReason(describeError(error))}`);
        }
      }

      console.error(`BACKUP_FAILED: received ${signalName}`);
      process.exit(1);
    })();
  };

  const handleSigterm = (): void => handleSignal("SIGTERM");
  const handleSigint = (): void => handleSignal("SIGINT");
  process.once("SIGTERM", handleSigterm);
  process.once("SIGINT", handleSigint);

  return () => {
    process.off("SIGTERM", handleSigterm);
    process.off("SIGINT", handleSigint);
  };
}

async function main(): Promise<void> {
  const removeSignalHandlers = installSignalHandlers();
  try {
    const backupResult = await runBackup();
    if (backupResult.degradedReason === undefined) {
      console.log(`BACKUP_VERIFIED ${backupResult.key} ${backupResult.size}`);
      return;
    }

    console.error(`BACKUP_DEGRADED ${backupResult.key} ${backupResult.size} - ${backupResult.degradedReason}`);
    process.exitCode = 1;
  } catch (error) {
    const reason = error instanceof BackupFailure ? error.message : describeError(error);
    console.error(`BACKUP_FAILED: ${normalizedReason(reason)}`);
    process.exitCode = 1;
  } finally {
    removeSignalHandlers();
  }
}

const invokedScriptPath = process.argv[1];
if (invokedScriptPath !== undefined && import.meta.url === pathToFileURL(resolve(invokedScriptPath)).href) {
  await main();
}
