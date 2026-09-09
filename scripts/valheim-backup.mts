#!/usr/bin/env node

import { spawn } from "node:child_process";
import { promises as fsPromises } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  chooseKey,
  freshness,
  parseConf,
  sizeGate,
  sizesMatch,
  tarExitAcceptable,
} from "./backup-gates.mts";
import type { BackupConfig } from "./backup-gates.mts";

const CONFIG_PATH = "/etc/valheim/idle.conf";
const FRESHNESS_SLACK_SECONDS = 120;
const OPTIONAL_ARCHIVE_FILES = ["adminlist.txt", "bannedlist.txt", "permittedlist.txt"];

interface CommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
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

function runCommand(commandName: string, argumentsList: string[], captureStdout: boolean): Promise<CommandResult> {
  return new Promise((resolveCommand) => {
    let stdoutText = "";
    let stderrText = "";
    let settled = false;
    const childProcess = spawn(commandName, argumentsList, {
      stdio: ["ignore", captureStdout ? "pipe" : "ignore", "pipe"],
    });

    if (captureStdout && childProcess.stdout !== null) {
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
      if (!settled) {
        settled = true;
        resolveCommand({ exitCode: 1, stdout: stdoutText, stderr: stderrText });
      }
    });

    childProcess.once("close", (exitCode: number | null) => {
      if (!settled) {
        settled = true;
        resolveCommand({
          exitCode: exitCode ?? 1,
          stdout: stdoutText,
          stderr: stderrText,
        });
      }
    });
  });
}

function commandFailure(result: CommandResult, action: string): BackupFailure {
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

async function createArchive(archivePath: string, savedir: string, entries: string[]): Promise<void> {
  const tarResult = await runCommand(
    "tar",
    ["-czf", archivePath, "-C", savedir, "--", ...entries],
    false,
  );

  if (!tarExitAcceptable(tarResult.exitCode)) {
    throw commandFailure(tarResult, `tar failed`);
  }
}

async function verifyArchive(archivePath: string): Promise<void> {
  const integrityResult = await runCommand("tar", ["-tzf", archivePath], false);
  if (integrityResult.exitCode !== 0) {
    throw commandFailure(integrityResult, "archive fails integrity check");
  }
}

async function uploadAndVerify(
  archivePath: string,
  archiveSize: number,
  config: BackupConfig,
  key: string,
): Promise<void> {
  const destination = `s3://${config.BACKUP_BUCKET}/${key}`;
  const uploadResult = await runCommand(
    "aws",
    ["s3", "cp", archivePath, destination, "--region", config.AWS_REGION, "--only-show-errors"],
    false,
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
      "Contents[0].Size",
      "--output",
      "text",
    ],
    true,
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
  const minimumBytes = numericConfigValue(config, "BACKUP_MIN_BYTES", 0);
  const relativeWorldPath = worldRelativePath(config.WORLD_NAME);
  const worldDirectory = join(config.SAVEDIR, relativeWorldPath);
  const worldStats = await fsPromises.stat(worldDirectory);
  if (!worldStats.isDirectory()) {
    throw new BackupFailure(`${worldDirectory} is not a directory`);
  }

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
  const archivePath = join(temporaryDirectory, basename(key));

  try {
    const entries = await archiveEntries(config.SAVEDIR, relativeWorldPath);
    await createArchive(archivePath, config.SAVEDIR, entries);
    await verifyArchive(archivePath);

    const archiveStats = await fsPromises.stat(archivePath);
    if (!sizeGate(archiveStats.size, minimumBytes)) {
      throw new BackupFailure(
        `archive only ${archiveStats.size}B, below ${minimumBytes}B floor, refusing to publish a suspect backup`,
      );
    }

    await uploadAndVerify(archivePath, archiveStats.size, config, key);
    return { key, size: archiveStats.size, degradedReason };
  } finally {
    await fsPromises.rm(temporaryDirectory, { recursive: true, force: true });
  }
}

async function main(): Promise<void> {
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
  }
}

const invokedScriptPath = process.argv[1];
if (invokedScriptPath !== undefined && import.meta.url === pathToFileURL(resolve(invokedScriptPath)).href) {
  await main();
}
