// Red/green harness for the mod-monitor handler.
//
//   cd discord-bot && npm install && npm test
//
// Same standard as backup-monitor.test.mjs: every alarm is exercised in its FIRING
// state, not just its quiet one. The specific thing being guarded against here is a
// monitor that goes quiet while blind, so the cases that matter most are the ones where
// a lookup FAILED and the run must still alert.

import assert from "node:assert/strict";
import test from "node:test";

process.env.WEBHOOK_PARAM = "/test/webhook";
process.env.PINS_JSON = JSON.stringify([
  {identifier: "ValheimModding-Jotunn", version: "2.30.0"},
]);
process.env.PACK_IDENTIFIER = "valheimsquad-Utgarde_Client_Pack";
process.env.PACK_VERSION = "1.0.0";

const {classify, describe, needsAlert, splitIdentifier} = await import(
  "../mod-monitor/index.mjs"
);

const realFetch = globalThis.fetch;

function row(overrides = {}) {
  return {
    identifier: "A-Mod",
    pinned: "1.0.0",
    state: "current",
    detail: "1.0.0",
    ...overrides,
  };
}

function pack(overrides = {}) {
  return {
    identifier: "team-Pack",
    pinned: "1.0.0",
    state: "current",
    detail: "1.0.0",
    ...overrides,
  };
}

test("a hyphenated team namespace splits from the right", () => {
  assert.deepEqual(splitIdentifier("sinai-dev-UnityExplorer"), {
    namespace: "sinai-dev",
    name: "UnityExplorer",
  });
  assert.deepEqual(splitIdentifier("ValheimModding-Jotunn"), {
    namespace: "ValheimModding",
    name: "Jotunn",
  });
  assert.equal(splitIdentifier("JustOneWord"), null);
});

test("a failed lookup is unknown, never current, even when the versions match", () => {
  // The shape that matters: an error alongside a version that compares equal.
  assert.equal(classify("1.0.0", {latest: "1.0.0", error: "HTTP 500"}).state, "unknown");
  assert.equal(classify("1.0.0", {latest: "1.0.0", error: null}).state, "current");
  assert.equal(classify("1.0.0", {latest: "1.1.0", error: null}).state, "behind");
});

test("an all-current estate raises nothing", () => {
  assert.equal(needsAlert([row()], pack()), false);
});

test("every non-current state raises an alert", () => {
  for (const state of ["behind", "unknown"]) {
    assert.equal(needsAlert([row({state})], pack()), true, `mod ${state}`);
  }
  for (const state of ["behind", "unknown", "unpublished"]) {
    assert.equal(needsAlert([row()], pack({state})), true, `pack ${state}`);
  }
});

test("the message names the drift rather than only counting it", () => {
  const text = describe(
    [row({identifier: "Grantapher-VPlus", pinned: "10.1.0", state: "behind", detail: "10.1.1"})],
    pack({state: "behind", detail: "0.9.0", pinned: "1.0.0"}),
  );
  assert.match(text, /Grantapher-VPlus` pinned 10\.1\.0, latest 10\.1\.1/);
  assert.match(text, /published pack is stale/);
  assert.match(text, /0\.9\.0 published, the manifest names 1\.0\.0/);
});

test("a failed lookup is reported as not an all-clear", () => {
  const text = describe([row({state: "unknown", detail: "HTTP 500"})], pack());
  assert.match(text, /Could not be checked.*not an all-clear/s);
  assert.match(text, /HTTP 500/);
});

test("an empty pin list throws rather than reporting a clean estate", async () => {
  const saved = process.env.PINS_JSON;
  process.env.PINS_JSON = "[]";
  const fresh = await import(`../mod-monitor/index.mjs?empty=${Date.now()}`);
  await assert.rejects(fresh.handler(), /carried no pins; nothing was checked/);
  process.env.PINS_JSON = saved;
});

test("a current estate returns without alerting", async () => {
  // Answer per package: the mod is pinned at 2.30.0 and the pack at 1.0.0, so a stub
  // returning one version for everything would make the pack look stale and alert.
  globalThis.fetch = async (url) =>
    new Response(
      JSON.stringify({
        latest: {
          version_number: String(url).includes("Utgarde_Client_Pack")
            ? "1.0.0"
            : "2.30.0",
        },
      }),
      {status: 200},
    );
  try {
    const fresh = await import(`../mod-monitor/index.mjs?current=${Date.now()}`);
    const result = await fresh.handler();
    assert.equal(result.alerted, false);
    assert.equal(result.checked, 2);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("a webhook that rejects the post throws, so the alarm fires", async () => {
  // The guard this repo has shipped broken twice: an alert path inside a bare catch.
  const {SSMClient} = await import("@aws-sdk/client-ssm");
  const savedSend = SSMClient.prototype.send;
  SSMClient.prototype.send = async () => ({Parameter: {Value: "https://discord.invalid/hook"}});
  globalThis.fetch = async (url) =>
    String(url).includes("discord.invalid")
      ? new Response("nope", {status: 404, statusText: "Not Found"})
      : new Response(JSON.stringify({latest: {version_number: "9.9.9"}}), {status: 200});
  try {
    const fresh = await import(`../mod-monitor/index.mjs?webhook=${Date.now()}`);
    await assert.rejects(fresh.handler(), /alert NOT delivered/);
  } finally {
    globalThis.fetch = realFetch;
    SSMClient.prototype.send = savedSend;
  }
});

test("an unreachable Thunderstore still alerts rather than passing quietly", async () => {
  const {SSMClient} = await import("@aws-sdk/client-ssm");
  const savedSend = SSMClient.prototype.send;
  SSMClient.prototype.send = async () => ({Parameter: {Value: "https://discord.invalid/hook"}});
  let posted = "";
  globalThis.fetch = async (url, init) => {
    if (String(url).includes("discord.invalid")) {
      posted = JSON.parse(init.body).content;
      return new Response(null, {status: 204});
    }
    throw new Error("ENOTFOUND thunderstore.io");
  };
  try {
    const fresh = await import(`../mod-monitor/index.mjs?down=${Date.now()}`);
    const result = await fresh.handler();
    assert.equal(result.alerted, true);
    assert.match(posted, /Could not be checked/);
    assert.match(posted, /ENOTFOUND/);
  } finally {
    globalThis.fetch = realFetch;
    SSMClient.prototype.send = savedSend;
  }
});
