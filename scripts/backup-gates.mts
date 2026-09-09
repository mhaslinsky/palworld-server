#!/usr/bin/env node

export interface FreshnessInput {
  newestMtimeSeconds: number | null | undefined;
  nowSeconds: number;
  intervalSeconds: number;
  slackSeconds: number;
}

export interface KeyInput {
  degraded: boolean;
  timestamp: Date | number | string;
}

export interface BackupConfig {
  SAVEDIR: string;
  WORLD_NAME: string;
  SAVE_INTERVAL_SECONDS: string;
  BACKUP_BUCKET: string;
  AWS_REGION: string;
  BACKUP_MIN_BYTES: string;
  [keyName: string]: string;
}

export function freshness(input: FreshnessInput): "fresh" | string {
  const {
    newestMtimeSeconds,
    nowSeconds,
    intervalSeconds,
    slackSeconds,
  } = input;

  if (
    !Number.isFinite(nowSeconds) ||
    !Number.isFinite(intervalSeconds) ||
    !Number.isFinite(slackSeconds) ||
    intervalSeconds < 0 ||
    slackSeconds < 0
  ) {
    return "degraded:invalid freshness timing values";
  }

  if (newestMtimeSeconds === null || newestMtimeSeconds === undefined) {
    return "degraded:no regular world files found";
  }

  if (!Number.isFinite(newestMtimeSeconds)) {
    return "degraded:invalid newest world file mtime";
  }

  const ageSeconds = nowSeconds - newestMtimeSeconds;
  const allowedAgeSeconds = intervalSeconds + slackSeconds;

  if (ageSeconds <= allowedAgeSeconds) {
    return "fresh";
  }

  return `degraded:newest world file is ${Math.floor(ageSeconds)}s old, limit is ${allowedAgeSeconds}s`;
}

export function sizeGate(bytes: number, minBytes: number): boolean {
  return Number.isFinite(bytes) && Number.isFinite(minBytes) && minBytes >= 0 && bytes >= minBytes;
}

export function parseMinBytes(rawValue: string | undefined): number {
  const configuredValue = rawValue ?? "200000";
  const minBytes = Number(configuredValue);
  if (configuredValue.trim() === "" || !Number.isFinite(minBytes) || minBytes <= 0) {
    throw new Error("BACKUP_MIN_BYTES must be a positive number");
  }

  return minBytes;
}

export function chooseKey(input: KeyInput): string {
  const timestampDate = input.timestamp instanceof Date
    ? new Date(input.timestamp.getTime())
    : new Date(input.timestamp);

  if (!Number.isFinite(timestampDate.getTime())) {
    throw new Error("timestamp must be a valid date");
  }

  const padNumber = (value: number): string => String(value).padStart(2, "0");
  const timestampText = [
    String(timestampDate.getUTCFullYear()).padStart(4, "0"),
    padNumber(timestampDate.getUTCMonth() + 1),
    padNumber(timestampDate.getUTCDate()),
  ].join("") + "T" + [
    padNumber(timestampDate.getUTCHours()),
    padNumber(timestampDate.getUTCMinutes()),
    padNumber(timestampDate.getUTCSeconds()),
  ].join("") + "Z";

  const prefix = input.degraded ? "world/linux-degraded" : "world/linux";
  return `${prefix}/${timestampText}.tgz`;
}

export function tarExitAcceptable(exitCode: number | null | undefined): boolean {
  return exitCode === 0 || exitCode === 1;
}

export function sizesMatch(localBytes: number, remoteText: string): boolean {
  if (!Number.isFinite(localBytes) || localBytes < 0) {
    return false;
  }

  const normalizedRemoteText = remoteText.trim();
  if (normalizedRemoteText === "" || normalizedRemoteText === "None") {
    return false;
  }

  return normalizedRemoteText === String(localBytes);
}

export function parseConf(text: string): BackupConfig {
  const parsedValues: Record<string, string> = {};
  const configLines = text.split(/\r?\n/);

  for (const [lineIndex, rawLine] of configLines.entries()) {
    const configLine = rawLine.trim();
    if (configLine === "" || configLine.startsWith("#")) {
      continue;
    }

    const assignmentMatch = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']*)'\s*(?:#.*)?$/.exec(configLine);
    if (assignmentMatch === null) {
      throw new Error(`invalid idle.conf line ${lineIndex + 1}`);
    }

    const keyName = assignmentMatch[1];
    const valueText = assignmentMatch[2];
    if (keyName === undefined || valueText === undefined) {
      throw new Error(`invalid idle.conf line ${lineIndex + 1}`);
    }

    parsedValues[keyName] = valueText;
  }

  const requiredKeys = ["SAVEDIR", "WORLD_NAME", "SAVE_INTERVAL_SECONDS", "BACKUP_BUCKET"];
  for (const requiredKey of requiredKeys) {
    if (parsedValues[requiredKey] === undefined || parsedValues[requiredKey] === "") {
      throw new Error(`idle.conf must set ${requiredKey}`);
    }
  }

  const backupConfig: BackupConfig = {
    ...parsedValues,
    AWS_REGION: parsedValues.AWS_REGION ?? "us-east-1",
    BACKUP_MIN_BYTES: parsedValues.BACKUP_MIN_BYTES ?? "200000",
  };

  parseMinBytes(backupConfig.BACKUP_MIN_BYTES);
  return backupConfig;
}
