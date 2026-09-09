#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  chooseKey,
  freshness,
  parseConf,
  sizeGate,
  sizesMatch,
  tarExitAcceptable,
} from "./backup-gates.mts";

test("freshness accepts the exact interval and slack boundary", () => {
  assert.equal(
    freshness({
      newestMtimeSeconds: 280,
      nowSeconds: 1000,
      intervalSeconds: 600,
      slackSeconds: 120,
    }),
    "fresh",
  );
});

test("freshness degrades an older world with a reason", () => {
  const result = freshness({
    newestMtimeSeconds: 279,
    nowSeconds: 1000,
    intervalSeconds: 600,
    slackSeconds: 120,
  });

  assert.match(result, /^degraded:/);
});

test("freshness degrades when no regular file mtime is available", () => {
  assert.equal(
    freshness({
      newestMtimeSeconds: null,
      nowSeconds: 1000,
      intervalSeconds: 600,
      slackSeconds: 120,
    }),
    "degraded:no regular world files found",
  );
});

test("size gate accepts the floor and rejects smaller archives", () => {
  assert.equal(sizeGate(200000, 200000), true);
  assert.equal(sizeGate(199999, 200000), false);
});

test("chooseKey selects the healthy and degraded prefixes", () => {
  const timestamp = new Date("2026-09-09T14:16:42.716Z");
  assert.equal(chooseKey({ degraded: false, timestamp }), "world/linux/20260909T141642Z.tgz");
  assert.equal(chooseKey({ degraded: true, timestamp }), "world/linux-degraded/20260909T141642Z.tgz");
});

test("tar exit code one is accepted for files changing during the archive", () => {
  assert.equal(tarExitAcceptable(0), true);
  assert.equal(tarExitAcceptable(1), true);
  assert.equal(tarExitAcceptable(2), false);
});

test("sizesMatch rejects missing list results and accepts matching text", () => {
  assert.equal(sizesMatch(1234, "1234\n"), true);
  assert.equal(sizesMatch(1234, "None"), false);
  assert.equal(sizesMatch(1234, "1235"), false);
});

test("parseConf reads quoted values and applies defaults", () => {
  const config = parseConf([
    "SAVEDIR='/srv/valheim saves'",
    "WORLD_NAME='Friends World'",
    "SAVE_INTERVAL_SECONDS='600'",
    "BACKUP_BUCKET='example-bucket'",
  ].join("\n"));

  assert.equal(config.SAVEDIR, "/srv/valheim saves");
  assert.equal(config.WORLD_NAME, "Friends World");
  assert.equal(config.AWS_REGION, "us-east-1");
  assert.equal(config.BACKUP_MIN_BYTES, "200000");
});

test("parseConf rejects malformed lines and missing required values", () => {
  assert.throws(() => parseConf("SAVEDIR=/srv/valheim"), /invalid idle.conf line 1/);
  assert.throws(() => parseConf("WORLD_NAME='Friends World'"), /idle.conf must set SAVEDIR/);
});
