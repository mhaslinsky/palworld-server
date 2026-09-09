#!/usr/bin/env node

export type IdleDecision = "reset" | "start_clock" | "warn" | "shutdown" | "wait";

export interface DecideInput {
  count: number | null;
  nowSeconds: number;
  idleSince: number | null;
  warned: boolean;
  thresholdMin: number;
  warnBeforeMin: number;
}

const DEFAULT_NAME_PATTERNS = [/Got character ZDOID from ([^:\r\n]+?)\s*:/g];

export function decide(input: DecideInput): IdleDecision {
  if (input.count === null || input.count !== 0) {
    return "reset";
  }
  if (input.idleSince === null) {
    return "start_clock";
  }

  const elapsedSeconds = input.nowSeconds - input.idleSince;
  const thresholdSeconds = input.thresholdMin * 60;
  const warningSeconds = (input.thresholdMin - input.warnBeforeMin) * 60;
  if (elapsedSeconds >= thresholdSeconds) {
    return "shutdown";
  }
  if (elapsedSeconds >= warningSeconds && !input.warned) {
    return "warn";
  }
  return "wait";
}

export function parseConf(text: string): Record<string, string> {
  const configuration: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    const trimmedLine = line.trim();
    if (trimmedLine === "" || trimmedLine.startsWith("#")) {
      continue;
    }

    const match = trimmedLine.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']*)'\s*$/);
    if (match === null) {
      throw new Error(`Invalid idle config line: ${line}`);
    }
    const key = match[1];
    const value = match[2];
    if (key === undefined || value === undefined) {
      throw new Error(`Invalid idle config line: ${line}`);
    }
    configuration[key] = value;
  }
  return configuration;
}

function namesFromPattern(logText: string, pattern: RegExp): string[] {
  const globalFlags = pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`;
  const globalPattern = new RegExp(pattern.source, globalFlags);
  const names: string[] = [];
  for (const match of logText.matchAll(globalPattern)) {
    const capturedName = match[1] ?? match[0];
    const name = capturedName.trim();
    if (name !== "" && !names.includes(name)) {
      names.push(name);
    }
  }
  return names;
}

// Journal names are best-effort because A2S_INFO supplies the authoritative count.
export function extractNames(logText: string, patterns: readonly RegExp[] = DEFAULT_NAME_PATTERNS): string {
  const names: string[] = [];
  for (const pattern of patterns) {
    for (const name of namesFromPattern(logText, pattern)) {
      if (!names.includes(name)) {
        names.push(name);
      }
    }
  }
  return names.join(", ");
}
