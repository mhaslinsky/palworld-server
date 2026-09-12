#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  PACKAGE_ENTRIES,
  checkDependencyExists,
  summarize,
  verifyArchive,
  type VersionCheck,
} from "./modpack-build.mts";

// A real non-empty file, so these exercise the entry comparison rather than the existence check.
const existingZip = join(mkdtempSync(join(tmpdir(), "modpack-")), "pack.zip");
writeFileSync(existingZip, "not really a zip, but it exists and is non-empty");

const realFetch = globalThis.fetch;

async function withFetch<TResult>(
  stub: typeof globalThis.fetch,
  body: () => Promise<TResult>,
): Promise<TResult> {
  globalThis.fetch = stub;
  try {
    return await body();
  } finally {
    globalThis.fetch = realFetch;
  }
}

function respondWith(
  status: number,
  body: unknown = null,
): typeof globalThis.fetch {
  return (async () =>
    new Response(body === null ? null : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as typeof globalThis.fetch;
}

function matchingPayload(namespace: string, name: string, version: string) {
  return { namespace, name, version_number: version };
}

test("a version that exists, and says so in its payload, is present", async () => {
  const check = await withFetch(
    respondWith(200, matchingPayload("ValheimModding", "Jotunn", "2.30.0")),
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "present");
});

test("a 200 whose payload describes another package is unreachable, never present", async () => {
  // Test contract corrected because: the previous version asserted an EMPTY 200 proved the
  // version existed. A redirect to a landing page or a challenge page answers exactly that way,
  // so the check was confirming versions nobody had looked at.
  const check = await withFetch(
    respondWith(200, matchingPayload("SomeoneElse", "OtherMod", "9.9.9")),
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "unreachable");
  assert.match(check.detail, /not the package requested/);
});

test("a 200 describing the right package at the wrong version is unreachable", async () => {
  // Each field is checked separately: a payload differing only in version must still fail,
  // or the version arm of the comparison is unguarded.
  const check = await withFetch(
    respondWith(200, matchingPayload("ValheimModding", "Jotunn", "2.29.0")),
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "unreachable");
  assert.match(check.detail, /ValheimModding\/Jotunn\/2\.29\.0/);
});

test("a 200 from the right namespace but the wrong package is unreachable", async () => {
  const check = await withFetch(
    respondWith(200, matchingPayload("ValheimModding", "YamlDotNet", "2.30.0")),
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "unreachable");
});

test("a 200 that is not JSON is unreachable", async () => {
  const check = await withFetch(
    (async () =>
      new Response("<html>Attention Required</html>", {
        status: 200,
      })) as typeof globalThis.fetch,
    () => checkDependencyExists("ValheimModding-Jotunn-2.30.0"),
  );
  assert.equal(check.status, "unreachable");
  assert.match(check.detail, /not JSON/);
});

test("a 404 is missing, not unreachable", async () => {
  const check = await withFetch(respondWith(404), () =>
    checkDependencyExists("ValheimModding-Jotunn-9.9.9"),
  );
  assert.equal(check.status, "missing");
  assert.match(check.detail, /404/);
});

test("a server error is unreachable, never present and never missing", async () => {
  for (const status of [301, 302, 429, 500, 503]) {
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

test("a malformed dependency is unreachable, not missing, and touches no network", async () => {
  // Test contract corrected because: "missing" renders as "not on Thunderstore", which asserts
  // something about the package. Nothing was looked up, so the honest arm is "could not check".
  let called = false;
  const check = await withFetch(
    (async () => {
      called = true;
      return new Response(null, { status: 200 });
    }) as typeof globalThis.fetch,
    () => checkDependencyExists("JustOneWord"),
  );
  assert.equal(check.status, "unreachable");
  assert.match(check.detail, /never looked up/);
  assert.equal(called, false);
});

test("the request targets the namespace, name and version separately", async () => {
  let seen = "";
  await withFetch(
    (async (url: string | URL | Request) => {
      seen = String(url);
      return new Response(
        JSON.stringify(
          matchingPayload(
            "Grantapher",
            "ValheimPlus_Grantapher_Temporary",
            "10.1.0",
          ),
        ),
        { status: 200 },
      );
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

test("an archive holding exactly the three package files verifies", () => {
  assert.doesNotThrow(() =>
    verifyArchive(existingZip, () => [...PACKAGE_ENTRIES].reverse()),
  );
});

test("an archive missing a package file is refused", () => {
  assert.throws(
    () => verifyArchive(existingZip, () => ["manifest.json", "README.md"]),
    /expected \[README\.md, icon\.png, manifest\.json\]/,
  );
});

test("an archive carrying an extra entry is refused", () => {
  assert.throws(
    () => verifyArchive(existingZip, () => [...PACKAGE_ENTRIES, "stowaway.dll"]),
    /the archive holds \[/,
  );
});

test("a missing archive is refused rather than reported as built", () => {
  assert.throws(
    () => verifyArchive(join(tmpdir(), "no-such-pack-9931.zip"), () => []),
    /was not written to/,
  );
});

test("an empty archive is refused, since zip can exit 0 having written nothing usable", () => {
  const emptyPath = join(mkdtempSync(join(tmpdir(), "modpack-")), "empty.zip");
  writeFileSync(emptyPath, "");
  assert.throws(() => verifyArchive(emptyPath, () => []), /is empty/);
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
