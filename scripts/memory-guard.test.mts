#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  bytesFromSize,
  capProblems,
  dropInContent,
  fstabHasSwap,
  MEMORY_SWAP_MAX,
  memoryMaxFor,
  swapIsActive,
} from "./memory-guard.mts";

test("bytesFromSize matches what systemd reports for the configured sizes", () => {
  // Read back from the live box on 2026-09-23 after applying 3400M and 2G.
  assert.equal(bytesFromSize("3400M"), 3565158400);
  assert.equal(bytesFromSize("2G"), 2147483648);
  assert.equal(bytesFromSize("64K"), 65536);
});

test("bytesFromSize rejects sizes it cannot read rather than guessing", () => {
  assert.throws(() => bytesFromSize("3.4G"), /unparseable/);
  assert.throws(() => bytesFromSize("infinity"), /unparseable/);
  assert.throws(() => bytesFromSize("3400"), /unparseable/);
});

test("memoryMaxFor leaves 512 MiB of RAM outside the cap", () => {
  const meminfo = (kib: number) => `MemTotal:       ${kib} kB\nMemFree:          123456 kB\n`;
  assert.equal(memoryMaxFor(meminfo(3928064)), "3324M");
  assert.equal(memoryMaxFor(meminfo(8053064)), "7352M");
});

test("memoryMaxFor refuses meminfo it cannot read and caps too small to run Valheim", () => {
  assert.throws(() => memoryMaxFor("MemFree: 123 kB\n"), /MemTotal not found/);
  assert.throws(() => memoryMaxFor("MemTotal:       1048576 kB\n"), /below 1024M/);
});

test("dropInContent carries both limits under [Service]", () => {
  assert.equal(dropInContent("7352M"), `[Service]\nMemoryMax=7352M\nMemorySwapMax=${MEMORY_SWAP_MAX}\n`);
});

test("fstabHasSwap finds the swapfile entry and ignores lookalikes", () => {
  assert.equal(fstabHasSwap("LABEL=cloudimg-rootfs / ext4 defaults 0 1\n/swapfile none swap sw 0 0\n"), true);
  assert.equal(fstabHasSwap("LABEL=cloudimg-rootfs / ext4 defaults 0 1\n"), false);
  assert.equal(fstabHasSwap("#/swapfile none swap sw 0 0\n/swapfile2 none swap sw 0 0\n"), false);
});

test("swapIsActive finds the swapfile in /proc/swaps and ignores other swap", () => {
  const header = "Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n";
  assert.equal(swapIsActive(`${header}/swapfile                               file\t\t3145724\t\t0\t\t-2\n`), true);
  assert.equal(swapIsActive(header), false);
  assert.equal(swapIsActive(`${header}/dev/nvme0n1p3 partition 1024 0 -2\n`), false);
});

test("capProblems is empty only when both limits match", () => {
  assert.deepEqual(capProblems("3565158400\n", "2147483648", "3400M"), []);
  assert.equal(capProblems("3565158400", "2147483648", "7352M").length, 1);
  assert.equal(capProblems("infinity", "2147483648", "3400M").length, 1);
  assert.equal(capProblems("3565158400", "infinity", "3400M").length, 1);
  assert.equal(capProblems("infinity", "infinity", "3400M").length, 2);
});
