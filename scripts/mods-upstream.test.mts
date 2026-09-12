#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  buildReport,
  classify,
  classifyPack,
  exitCode,
  fetchLatestVersion,
  latestVersionFrom,
  report,
  summarize,
  type PackageState,
  type UpstreamReport,
} from "./mods-upstream.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

function state(overrides: Partial<PackageState> = {}): PackageState {
  return {
    identifier: "Someone-SomeMod",
    pinned: "1.0.0",
    latest: "1.0.0",
    error: null,
    ...overrides,
  };
}

function upstream(overrides: Partial<UpstreamReport> = {}): UpstreamReport {
  return {
    current: [],
    behind: [],
    unknown: [],
    pack: {
      identifier: "team-Pack",
      manifestVersion: "1.0.0",
      publishedVersion: "1.0.0",
      status: "published",
      detail: "the published pack matches the manifest",
    },
    ...overrides,
  };
}

function respondWith(status: number, body?: unknown): typeof globalThis.fetch {
  return (async () =>
    new Response(body === undefined ? null : JSON.stringify(body), {
      status,
    })) as typeof globalThis.fetch;
}

test("the latest version is read from the listing's latest entry", () => {
  assert.equal(
    latestVersionFrom({ latest: { version_number: "2.30.0" } }),
    "2.30.0",
  );
  assert.equal(latestVersionFrom({ latest: {} }), null);
  assert.equal(latestVersionFrom({}), null);
  assert.equal(latestVersionFrom(null), null);
  assert.equal(latestVersionFrom({ latest: { version_number: "" } }), null);
});

test("a hyphenated team namespace is split from the right, not the left", async () => {
  // Test contract corrected because: the first version asserted the URL a left-split
  // produces, /package/sinai/dev-UnityExplorer/, which is a package that does not exist.
  // The team is sinai-dev and the package is UnityExplorer.
  let seen = "";
  await fetchLatestVersion("sinai-dev-UnityExplorer", (async (url) => {
    seen = String(url);
    return new Response(JSON.stringify({ latest: { version_number: "4.8.2" } }), {
      status: 200,
    });
  }) as typeof globalThis.fetch);
  assert.equal(
    seen,
    "https://thunderstore.io/api/experimental/package/sinai-dev/UnityExplorer/",
  );
});

test("an ordinary two-part identifier is unaffected", async () => {
  let seen = "";
  await fetchLatestVersion("ValheimModding-Jotunn", (async (url) => {
    seen = String(url);
    return new Response(JSON.stringify({ latest: { version_number: "2.30.0" } }), {
      status: 200,
    });
  }) as typeof globalThis.fetch);
  assert.equal(
    seen,
    "https://thunderstore.io/api/experimental/package/ValheimModding/Jotunn/",
  );
});

test("an identifier with no hyphen at all is refused", async () => {
  const result = await fetchLatestVersion("JustOneWord", (async () => {
    throw new Error("the network must not be touched");
  }) as typeof globalThis.fetch);
  assert.equal(result.latest, null);
  assert.match(result.error ?? "", /is not Namespace-Name/);
});

test("a non-200 is an error rather than a null latest that reads as current", async () => {
  const result = await fetchLatestVersion("A-B", respondWith(503));
  assert.equal(result.latest, null);
  assert.equal(result.error, "HTTP 503");
});

test("a thrown lookup carries its reason", async () => {
  const result = await fetchLatestVersion("A-B", (async () => {
    throw new Error("ENOTFOUND thunderstore.io");
  }) as typeof globalThis.fetch);
  assert.match(result.error ?? "", /ENOTFOUND/);
});

test("classify separates current, behind and unknown without overlap", () => {
  const states = [
    state({ identifier: "A-Current", pinned: "1.0.0", latest: "1.0.0" }),
    state({ identifier: "A-Behind", pinned: "1.0.0", latest: "1.1.0" }),
    state({ identifier: "A-Unknown", latest: null, error: "HTTP 500" }),
  ];
  const grouped = classify(states);
  assert.deepEqual(grouped.current.map((entry) => entry.identifier), ["A-Current"]);
  assert.deepEqual(grouped.behind.map((entry) => entry.identifier), ["A-Behind"]);
  assert.deepEqual(grouped.unknown.map((entry) => entry.identifier), ["A-Unknown"]);
});

test("a failed lookup is never counted as current", () => {
  const grouped = classify([
    state({ pinned: "1.0.0", latest: null, error: "HTTP 500" }),
  ]);
  assert.deepEqual(grouped.current, []);
  assert.equal(grouped.unknown.length, 1);
});

test("an error outranks a matching version, so a stale reading cannot read as current", () => {
  // The dangerous shape: the versions compare equal AND the lookup failed. Without the
  // error check this lands in `current`, which is the whole silent-success failure. A
  // caller holding a cached version alongside a fresh failure produces exactly this.
  const grouped = classify([
    state({ pinned: "1.0.0", latest: "1.0.0", error: "HTTP 500" }),
  ]);
  assert.deepEqual(grouped.current, [], "an errored state must never be current");
  assert.deepEqual(grouped.behind, [], "and it is not a known drift either");
  assert.equal(grouped.unknown.length, 1);
});

test("a pack matching the manifest is published", () => {
  const pack = classifyPack("team-Pack", "1.0.0", {
    latest: "1.0.0",
    error: null,
  });
  assert.equal(pack.status, "published");
});

test("a pack behind the manifest names both versions", () => {
  const pack = classifyPack("team-Pack", "1.1.0", {
    latest: "1.0.0",
    error: null,
  });
  assert.equal(pack.status, "behind");
  assert.match(pack.detail, /manifest names 1\.1\.0 but 1\.0\.0 is published/);
});

test("a 404 means never published, which is different from a failed lookup", () => {
  assert.equal(
    classifyPack("team-Pack", "1.0.0", { latest: null, error: "HTTP 404" })
      .status,
    "unpublished",
  );
  assert.equal(
    classifyPack("team-Pack", "1.0.0", { latest: null, error: "HTTP 500" })
      .status,
    "unknown",
  );
});

test("everything current summarizes as current", () => {
  const input = upstream({ current: [state()] });
  assert.match(summarize(input), /^CURRENT:/);
  assert.equal(exitCode(input), 0);
});

test("a mod behind upstream exits 1 and says so", () => {
  const input = upstream({ behind: [state({ latest: "1.1.0" })] });
  assert.match(summarize(input), /1 mod behind upstream/);
  assert.equal(exitCode(input), 1);
});

test("an unpublished or behind pack exits 1 even when every mod is current", () => {
  for (const status of ["behind", "unpublished"] as const) {
    const input = upstream({
      current: [state()],
      pack: { ...upstream().pack, status, detail: "d" },
    });
    assert.equal(exitCode(input), 1, `${status} pack must not exit 0`);
    assert.match(summarize(input), new RegExp(`client pack is ${status}`));
  }
});

test("a failed lookup exits 2, distinct from a known drift", () => {
  const input = upstream({ unknown: [state({ error: "HTTP 500" })] });
  assert.equal(exitCode(input), 2);
  assert.match(summarize(input), /unknown rather than fine/);
});

test("an unknown pack state also exits 2", () => {
  const input = upstream({
    current: [state()],
    pack: { ...upstream().pack, status: "unknown", detail: "HTTP 500" },
  });
  assert.equal(exitCode(input), 2);
});

test("the report names each drift rather than only counting it", () => {
  const text = report(
    upstream({
      behind: [
        state({ identifier: "Grantapher-VPlus", pinned: "10.1.0", latest: "10.1.1" }),
      ],
    }),
  );
  assert.match(text, /BEHIND {4}Grantapher-VPlus: pinned 10\.1\.0, Thunderstore has 10\.1\.1/);
});

test("buildReport skips mods that are not on Thunderstore", async () => {
  const manifest: EstateManifest = {
    world: "Utgarde",
    game_version: "1.0.12",
    network_version: 40,
    modpack: {
      namespace: "team",
      name: "Pack",
      version_number: "1.0.0",
      website_url: "",
      description: "d",
    },
    verified: {},
    mods: [
      {
        thunderstore: "A-Mod",
        version: "1.0.0",
        side: "both",
        why: "w",
      } as EstateMod,
      {
        thunderstore: null,
        name: "Nexus Only",
        version: "1.0.3",
        side: "server",
        why: "w",
      } as EstateMod,
    ],
  };

  const asked: string[] = [];
  const built = await buildReport(manifest, (async (url) => {
    asked.push(String(url));
    return new Response(JSON.stringify({ latest: { version_number: "1.0.0" } }), {
      status: 200,
    });
  }) as typeof globalThis.fetch);

  assert.equal(asked.length, 2, "one Thunderstore mod plus the pack itself");
  assert.equal(built.current.length, 1);
  assert.equal(built.pack.status, "published");
});
