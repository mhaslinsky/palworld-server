#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import { bucket, label, render } from "./mods-list.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

function mod(overrides: Partial<EstateMod> = {}): EstateMod {
  return {
    thunderstore: "Someone-SomeMod",
    version: "1.0.0",
    side: "both",
    why: "because",
    ...overrides,
  };
}

function manifest(mods: EstateMod[]): EstateManifest {
  return {
    world: "Utgarde",
    game_version: "1.0.12",
    network_version: 40,
    modpack: {
      namespace: "valheimsquad",
      name: "Utgarde_Client_Pack",
      version_number: "1.1.0",
      website_url: "",
      description: "d",
    },
    verified: {},
    mods,
  };
}

const SAMPLE = manifest([
  mod({ thunderstore: "A-InPack" }),
  mod({ thunderstore: "B-Enforced", enforced: true }),
  mod({ thunderstore: "C-ServerOnly", side: "server" }),
  mod({ thunderstore: null, name: "Nexus Server Thing", side: "server", source: "nexus" }),
  mod({ thunderstore: null, name: "Nexus Client Thing", side: "client", source: "nexus" }),
]);

test("every mod lands in exactly one bucket", () => {
  const { serverOnly, inPack, clientByHand } = bucket(SAMPLE);
  const placed = [...serverOnly, ...inPack, ...clientByHand].map(label);
  assert.equal(placed.length, SAMPLE.mods.length, "none dropped, none double-counted");
  assert.equal(new Set(placed).size, placed.length, "no mod in two buckets");
});

test("a client mod with no Thunderstore id is its own bucket, not quietly in the pack", () => {
  // This is the case that currently has no real example, and the one that matters: the
  // pack cannot carry it, so somebody has to install it by hand on every client.
  const { inPack, clientByHand } = bucket(SAMPLE);
  assert.deepEqual(clientByHand.map(label), ["Nexus Client Thing"]);
  assert.equal(
    inPack.some((entry) => entry.thunderstore === null),
    false,
    "the pack never lists something it cannot deliver",
  );
});

test("a Nexus mod that is server-side stays in the server bucket", () => {
  assert.deepEqual(bucket(SAMPLE).serverOnly.map(label), [
    "C-ServerOnly",
    "Nexus Server Thing",
  ]);
});

test("flipping a server mod to client-side moves it into the by-hand bucket", () => {
  // The live question about the feeding trough: if it turns out clients need it, this is
  // what the list should start saying without anyone editing the renderer.
  const flipped = manifest([
    mod({ thunderstore: null, name: "Animal Feeding Trough", side: "both", source: "nexus" }),
  ]);
  assert.deepEqual(bucket(flipped).clientByHand.map(label), ["Animal Feeding Trough"]);
  assert.deepEqual(bucket(flipped).serverOnly, []);
});

test("the enforced mod is called out, since it is the one that kicks people", () => {
  assert.match(render(SAMPLE, false), /B-Enforced.*VERSION ENFORCED/);
});

test("the by-hand section appears only when something is in it", () => {
  assert.match(render(SAMPLE, false), /NOT deliverable by the pack \(1\)/);
  const noneByHand = manifest([mod({ thunderstore: "A-InPack" })]);
  assert.doesNotMatch(render(noneByHand, false), /NOT deliverable by the pack/);
});

test("markdown mode emits tables and plain mode does not", () => {
  assert.match(render(SAMPLE, true), /\| Mod \| Version \|/);
  assert.doesNotMatch(render(SAMPLE, false), /\| Mod \| Version \|/);
});

test("the unmanaged caveat is always present in both modes", () => {
  for (const markdown of [true, false]) {
    assert.match(render(SAMPLE, markdown), /theirs and unmanaged/);
  }
});
