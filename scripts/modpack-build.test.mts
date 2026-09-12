#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  checkDependencyExists,
  summarize,
  type VersionCheck,
} from "./modpack-build.mts";

const realFetch = globalThis.fetch;

async function withFetch<T>(
  stub: typeof globalThis.fetch,
  body: () => Promise<T>,
): Promise<T> {
  globalThis.fetch = stub;
  try {
    return await body();
  } finally {
    globalThis.fetch = realFetch;
  }
}

function respondWith(status: number): typeof globalThis.fetch {
  return (async () => new Response(null, { status })) as typeof globalThis.fetch;
}

test("a version that exists is present", async () => {
  const check = await withFetch(respondWith(200), () =>
    checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "present");
});

test("a 404 is missing, not unreachable", async () => {
  const check = await withFetch(respondWith(404), () =>
    checkDependencyExists("ValheimModding-Jotunn-9.9.9"),
  );
  assert.equal(check.status, "missing");
  assert.match(check.detail, /404/);
});

test("a server error is unreachable, never present and never missing", async () => {
  for (const status of [429, 500, 503]) {
    const check = await withFetch(respondWith(status), () =>
      checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
    );
    assert.equal(
      check.status,
      "unreachable",
      `HTTP ${status} should read as unreachable`,
    );
  }
});

test("a thrown network error is unreachable and carries the reason", async () => {
  const check = await withFetch(
    (async () => {
      throw new Error("getaddrinfo ENOTFOUND thunderstore.io");
    }) as typeof globalThis.fetch,
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "unreachable");
  assert.match(check.detail, /ENOTFOUND/);
});

test("a malformed dependency is rejected without touching the network", async () => {
  let called = false;
  const check = await withFetch(
    (async () => {
      called = true;
      return new Response(null, { status: 200 });
    }) as typeof globalThis.fetch,
    () => checkDependencyExists("JustOneWord"),
  );
  assert.equal(check.status, "missing");
  assert.equal(called, false);
});

test("the request targets the namespace, name and version separately", async () => {
  let seen = "";
  await withFetch(
    (async (url: string | URL | Request) => {
      seen = String(url);
      return new Response(null, { status: 200 });
    }) as typeof globalThis.fetch,
    () => checkDependencyExists("Grantapher-ValheimPlus_Grantapher_Temporary-10.1.0"),
  );
  assert.equal(
    seen,
    "https://thunderstore.io/api/experimental/package/Grantapher/ValheimPlus_Grantapher_Temporary/10.1.0/",
  );
});

test("summarize reports nothing when every version is present", () => {
  const checks: VersionCheck[] = [
    { dependency: "a-b-1.0.0", status: "present", detail: "HTTP 200" },
    { dependency: "c-d-2.0.0", status: "present", detail: "HTTP 200" },
  ];
  assert.deepEqual(summarize(checks), []);
});

test("summarize distinguishes a missing version from one it could not check", () => {
  const lines = summarize([
    { dependency: "a-b-1.0.0", status: "present", detail: "HTTP 200" },
    { dependency: "c-d-2.0.0", status: "missing", detail: "HTTP 404" },
    { dependency: "e-f-3.0.0", status: "unreachable", detail: "timed out" },
  ]);
  assert.equal(lines.length, 2);
  assert.match(lines[0], /c-d-2\.0\.0: not on Thunderstore/);
  assert.match(lines[1], /e-f-3\.0\.0: could not be checked \(timed out\)/);
});
