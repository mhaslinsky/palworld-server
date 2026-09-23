#!/usr/bin/env node

// Keeps swap and a memory cap on valheim.service. Run on the box by the memory-guard SSM
// association (terraform/memory_guard.tf) every 30 minutes, so it must be idempotent.

import { execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const SWAP_PATH = "/swapfile";
export const SWAP_SIZE = "3G";
export const MEMORY_MAX = "3400M";
export const MEMORY_SWAP_MAX = "2G";
export const UNIT = "valheim.service";
export const DROP_IN_DIR = `/etc/systemd/system/${UNIT}.d`;
export const DROP_IN_PATH = `${DROP_IN_DIR}/memory-guard.conf`;
// `systemctl set-property` without --runtime persists here, and this directory outranks
// /etc/systemd/system, so a hand-applied value would silently shadow the repo's.
export const CONTROL_DIR = `/etc/systemd/system.control/${UNIT}.d`;
export const LEGACY_CONTROL_FILES = ["50-MemoryMax.conf", "50-MemorySwapMax.conf"];

export function dropInContent(): string {
  return `[Service]\nMemoryMax=${MEMORY_MAX}\nMemorySwapMax=${MEMORY_SWAP_MAX}\n`;
}

export function bytesFromSize(size: string): number {
  const match = /^(\d+)([KMG])$/.exec(size);
  if (match === null) throw new Error(`unparseable size: ${size}`);
  const multipliers: Record<string, number> = { K: 1024, M: 1024 ** 2, G: 1024 ** 3 };
  return Number(match[1]) * multipliers[match[2]];
}

export function fstabHasSwap(fstab: string): boolean {
  return fstab.split("\n").some((line) => line.trim().split(/\s+/)[0] === SWAP_PATH);
}

/** Takes the text of /proc/swaps, not its path. */
export function swapIsActive(procSwaps: string): boolean {
  return procSwaps.split("\n").some((line) => line.trim().split(/\s+/)[0] === SWAP_PATH);
}

/** Compares cap values read back from systemd or the cgroup against the wanted sizes. */
export function capProblems(memoryMax: string, memorySwapMax: string): string[] {
  const problems: string[] = [];
  const wantMemory = String(bytesFromSize(MEMORY_MAX));
  const wantSwap = String(bytesFromSize(MEMORY_SWAP_MAX));
  if (memoryMax.trim() !== wantMemory) problems.push(`MemoryMax is ${memoryMax.trim()}, want ${wantMemory}`);
  if (memorySwapMax.trim() !== wantSwap) problems.push(`MemorySwapMax is ${memorySwapMax.trim()}, want ${wantSwap}`);
  return problems;
}

function run(command: string, args: string[]): string {
  return execFileSync(command, args, { encoding: "utf8" });
}

function unitShow(property: string): string {
  return run("systemctl", ["show", UNIT, "-p", property, "--value"]).trim();
}

function ensureSwap(): void {
  if (!existsSync(SWAP_PATH)) {
    run("fallocate", ["-l", SWAP_SIZE, SWAP_PATH]);
    chmodSync(SWAP_PATH, 0o600);
    run("mkswap", [SWAP_PATH]);
  }
  if (!swapIsActive(readFileSync("/proc/swaps", "utf8"))) run("swapon", [SWAP_PATH]);
  if (!fstabHasSwap(readFileSync("/etc/fstab", "utf8"))) appendFileSync("/etc/fstab", `${SWAP_PATH} none swap sw 0 0\n`);
  if (!swapIsActive(readFileSync("/proc/swaps", "utf8"))) throw new Error(`${SWAP_PATH} is not active after swapon`);
}

/** Returns true when systemd needs a daemon-reload to see the change. */
function ensureDropIn(): boolean {
  let changed = false;
  mkdirSync(DROP_IN_DIR, { recursive: true });
  const current = existsSync(DROP_IN_PATH) ? readFileSync(DROP_IN_PATH, "utf8") : "";
  if (current !== dropInContent()) {
    writeFileSync(DROP_IN_PATH, dropInContent());
    changed = true;
  }
  for (const fileName of LEGACY_CONTROL_FILES) {
    const legacyPath = `${CONTROL_DIR}/${fileName}`;
    if (existsSync(legacyPath)) {
      rmSync(legacyPath);
      changed = true;
    }
  }
  return changed;
}

function main(): void {
  ensureSwap();
  if (ensureDropIn()) run("systemctl", ["daemon-reload"]);

  if (unitShow("LoadState") !== "loaded") {
    console.log(`MEMORY_GUARD_STAGED: ${UNIT} is not installed yet; the drop-in applies when it is`);
    return;
  }
  const active = unitShow("ActiveState") === "active";
  if (active) {
    // Applies the cap to the running cgroup without a restart; --runtime keeps it out of CONTROL_DIR.
    run("systemctl", ["set-property", "--runtime", UNIT, `MemoryMax=${MEMORY_MAX}`, `MemorySwapMax=${MEMORY_SWAP_MAX}`]);
  }
  const problems = capProblems(unitShow("MemoryMax"), unitShow("MemorySwapMax"));
  if (problems.length > 0) {
    console.error(`MEMORY_GUARD_FAILED: ${problems.join("; ")}`);
    process.exitCode = 1;
    return;
  }
  console.log(`MEMORY_GUARD_OK: swap on, cap ${MEMORY_MAX} + ${MEMORY_SWAP_MAX} swap ${active ? "live" : "configured, unit not running"}`);
}

const invokedScriptPath = process.argv[1];
if (invokedScriptPath !== undefined && import.meta.url === pathToFileURL(resolve(invokedScriptPath)).href) {
  main();
}
