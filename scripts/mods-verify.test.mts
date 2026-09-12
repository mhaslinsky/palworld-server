#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  compare,
  expectedPluginVersion,
  isClean,
  parseLoadedPlugins,
  report,
} from "./mods-verify.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

const SAMPLE_LOG = `[Message:   BepInEx] BepInEx 5.4.23.5 - valheim (9/12/2026 5:40:11 AM)
[Info   :   BepInEx] Running under Unity v2022.3.54.8993681
[Info   :   BepInEx] 9 plugins to load
[Info   :   BepInEx] Loading [ValheimPlus 0.10.1.0]
[Info   :   BepInEx] Loading [Jotunn 2.30.0]
[Info   :   BepInEx] Loading [ServersideQoL 2.0.7]
[Info   :   BepInEx] Loading [ServersideQoL.PortalProgression 2.0.0]
[Info   :   BepInEx] Loading [PlantEverything 1.21.1]
[Info   :    Jotunn] Initializing Jotunn
`;

function mod(overrides: Partial<EstateMod> = {}): EstateMod {
  return {
    thunderstore: "Someone-SomeMod",
    version: "1.0.0",
    side: "server",
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
      namespace: "Team",
      name: "Pack",
      version_number: "1.0.0",
      website_url: "",
      description: "d",
    },
    verified: {},
    mods,
  };
}

test("plugin names and versions are read out of the load lines", () => {
  const loaded = parseLoadedPlugins(SAMPLE_LOG);
  assert.equal(loaded.get("ValheimPlus"), "0.10.1.0");
  assert.equal(loaded.get("Jotunn"), "2.30.0");
  assert.equal(loaded.get("ServersideQoL.PortalProgression"), "2.0.0");
});

test("the loader's own version comes from its banner, not a load line", () => {
  assert.equal(parseLoadedPlugins(SAMPLE_LOG).get("BepInEx"), "5.4.23.5");
});

test("lines that are not plugin loads are ignored", () => {
  const loaded = parseLoadedPlugins(SAMPLE_LOG);
  assert.equal(loaded.has("Initializing Jotunn"), false);
  assert.equal(loaded.size, 6, "five plugins plus the loader");
});

test("a log spanning two boots reports the later one", () => {
  const twoBoots = `[Info   :   BepInEx] Loading [ServersideQoL 2.0.4]
[Info   :   BepInEx] Loading [ServersideQoL 2.0.7]`;
  assert.equal(parseLoadedPlugins(twoBoots).get("ServersideQoL"), "2.0.7");
});

test("an empty log parses to nothing", () => {
  assert.equal(parseLoadedPlugins("").size, 0);
});

test("the expected version falls back to the Thunderstore version when they agree", () => {
  assert.equal(expectedPluginVersion(mod({ version: "2.30.0" })), "2.30.0");
  assert.equal(
    expectedPluginVersion(
      mod({ version: "5.4.2350", plugin_version: "5.4.23.5" }),
    ),
    "5.4.23.5",
  );
});

test("a matching box is clean", () => {
  const input = manifest([
    mod({ plugin_name: "Jotunn", version: "2.30.0" }),
    mod({
      plugin_name: "BepInEx",
      version: "5.4.2350",
      plugin_version: "5.4.23.5",
    }),
  ]);
  const comparison = compare(
    input,
    new Map([
      ["Jotunn", "2.30.0"],
      ["BepInEx", "5.4.23.5"],
    ]),
  );
  assert.deepEqual(comparison.matched, ["Jotunn 2.30.0", "BepInEx 5.4.23.5"]);
  assert.equal(isClean(comparison), true);
});

test("the packaged version is never compared against the logged one", () => {
  // The loader ships as 5.4.2350 and logs 5.4.23.5; comparing them would always fail.
  const input = manifest([
    mod({
      plugin_name: "BepInEx",
      version: "5.4.2350",
      plugin_version: "5.4.23.5",
    }),
  ]);
  assert.equal(
    isClean(compare(input, new Map([["BepInEx", "5.4.23.5"]]))),
    true,
  );
});

test("a version drift is reported as a mismatch with both sides named", () => {
  const input = manifest([mod({ plugin_name: "ServersideQoL", version: "2.0.7" })]);
  const comparison = compare(input, new Map([["ServersideQoL", "2.0.4"]]));
  assert.deepEqual(comparison.mismatched, [
    { plugin: "ServersideQoL", expected: "2.0.7", found: "2.0.4" },
  ]);
  assert.equal(isClean(comparison), false);
});

test("a manifest mod the box never loaded is reported", () => {
  const input = manifest([mod({ plugin_name: "PortalProgression", version: "2.0.0" })]);
  const comparison = compare(input, new Map([["Jotunn", "2.30.0"]]));
  assert.deepEqual(comparison.notLoaded, ["PortalProgression"]);
  assert.equal(isClean(comparison), false);
});

test("a plugin on the box that nobody recorded is reported", () => {
  const input = manifest([mod({ plugin_name: "Jotunn", version: "2.30.0" })]);
  const comparison = compare(
    input,
    new Map([
      ["Jotunn", "2.30.0"],
      ["MysteryMod", "1.0.0"],
    ]),
  );
  assert.deepEqual(comparison.unexpected, [
    { plugin: "MysteryMod", version: "1.0.0" },
  ]);
  assert.equal(isClean(comparison), false);
});

test("an entry with no plugin name is unchecked, and excluded from the verdict", () => {
  const input = manifest([
    mod({ plugin_name: "Jotunn", version: "2.30.0" }),
    mod({
      thunderstore: null,
      name: "Animal Feeding Trough",
      plugin_name: null,
      plugin_name_note: "log name not read off the box yet",
    }),
  ]);
  const comparison = compare(input, new Map([["Jotunn", "2.30.0"]]));
  assert.deepEqual(comparison.unverifiable, [
    {
      label: "Animal Feeding Trough",
      reason: "log name not read off the box yet",
    },
  ]);
  assert.equal(isClean(comparison), true, "unchecked entries do not fail it");
  assert.match(report(comparison), /are NOT covered by the verdict above/);
});

test("zero matches is never clean, however empty the discrepancy lists are", () => {
  const comparison = compare(manifest([]), new Map());
  assert.deepEqual(comparison.matched, []);
  assert.deepEqual(comparison.mismatched, []);
  assert.equal(
    isClean(comparison),
    false,
    "an empty comparison must not read as a pass",
  );
  assert.match(report(comparison), /DRIFT/);
});

test("the report names the drift rather than only counting it", () => {
  const input = manifest([mod({ plugin_name: "ServersideQoL", version: "2.0.7" })]);
  const text = report(compare(input, new Map([["ServersideQoL", "2.0.4"]])));
  assert.match(
    text,
    /MISMATCH {2}ServersideQoL: manifest says 2\.0\.7, box loaded 2\.0\.4/,
  );
});
