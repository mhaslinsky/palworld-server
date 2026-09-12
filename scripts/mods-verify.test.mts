#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  compare,
  expectedPluginVersion,
  findSelfDisabled,
  isClean,
  parseLoadedPlugins,
  report,
} from "./mods-verify.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

// Copied from the real box on 2026-09-12. The names matter: ValheimPlus logs with a space,
// YamlDotNet's shim logs two words, and a first-token parser would pass a fixture without them.
const SAMPLE_LOG = `[Message:   BepInEx] BepInEx 5.4.23.5 - valheim_server (09/10/2026 00:08:00)
[Info   :   BepInEx] Running under Unity v2022.3.54.8993681
[Info   :   BepInEx] 9 plugins to load
[Info   :   BepInEx] Loading [Valheim Plus 0.10.1.0]
[Info   :   BepInEx] Loading [Jotunn 2.30.0]
[Info   :   BepInEx] Loading [ServersideQoL 2.0.7]
[Info   :   BepInEx] Loading [ServersideQoL.PortalProgression 2.0.0]
[Info   :   BepInEx] Loading [PlantEverything 1.21.1]
[Info   :   BepInEx] Loading [YamlDotNet Detector 1.0.0]
[Info   :   BepInEx] Loading [Animal Feeding Trough 1.0.3]
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
  assert.equal(loaded.get("Valheim Plus"), "0.10.1.0");
  assert.equal(loaded.get("Jotunn"), "2.30.0");
  assert.equal(loaded.get("ServersideQoL.PortalProgression"), "2.0.0");
});

test("the loader's own version comes from its banner, not a load line", () => {
  assert.equal(parseLoadedPlugins(SAMPLE_LOG).get("BepInEx"), "5.4.23.5");
});

test("lines that are not plugin loads are ignored", () => {
  const loaded = parseLoadedPlugins(SAMPLE_LOG);
  assert.equal(loaded.has("Initializing Jotunn"), false);
  assert.equal(loaded.size, 8, "seven plugins plus the loader");
});

test("a later load line within one boot wins", () => {
  const oneBoot = `[Info   :   BepInEx] Loading [ServersideQoL 2.0.4]
[Info   :   BepInEx] Loading [ServersideQoL 2.0.7]`;
  assert.equal(parseLoadedPlugins(oneBoot).get("ServersideQoL"), "2.0.7");
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

test("an entry with no plugin name is unchecked, and that is not a pass", () => {
  // Test contract corrected because: the previous version asserted isClean stayed true with an
  // unchecked entry. Leaving it out of `matched` does not prevent a pass, it lets the entry ride
  // along on someone else's match, so "I could not check this" was rendering as a clean exit 0.
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
  assert.equal(isClean(comparison), false, "an unchecked entry must not pass");
  assert.match(report(comparison), /could not be checked from the log/);
});

test("a client-only mod is not sought in the server's log", () => {
  const input = manifest([
    mod({ plugin_name: "Jotunn", version: "2.30.0" }),
    mod({ plugin_name: "ClientOnlyThing", version: "1.0.0", side: "client" }),
  ]);
  const comparison = compare(input, new Map([["Jotunn", "2.30.0"]]));
  assert.deepEqual(comparison.notLoaded, []);
  assert.equal(isClean(comparison), true);
});

test("a plugin from an earlier boot does not satisfy the newest one", () => {
  const twoBoots = `[Message:   BepInEx] BepInEx 5.4.23.5 - valheim_server (09/10/2026 00:08:00)
[Info   :   BepInEx] Loading [ServersideQoL 2.0.7]
[Info   :   BepInEx] Loading [Jotunn 2.30.0]
[Message:   BepInEx] BepInEx 5.4.23.5 - valheim_server (09/11/2026 00:08:00)
[Info   :   BepInEx] Loading [Jotunn 2.30.0]`;
  const loaded = parseLoadedPlugins(twoBoots);
  assert.equal(loaded.has("ServersideQoL"), false, "dropped with its boot");
  assert.equal(loaded.get("Jotunn"), "2.30.0");

  const input = manifest([
    mod({ plugin_name: "ServersideQoL", version: "2.0.7" }),
    mod({ plugin_name: "Jotunn", version: "2.30.0" }),
  ]);
  const comparison = compare(input, loaded);
  assert.deepEqual(comparison.notLoaded, ["ServersideQoL"]);
  assert.equal(isClean(comparison), false);
});

test("a Loading line from a mod's own output is not counted as a plugin", () => {
  const noisy = `[Info   :   BepInEx] Loading [Jotunn 2.30.0]
[Info   :SomeOtherMod] Loading [PretendPlugin 9.9.9]`;
  const loaded = parseLoadedPlugins(noisy);
  assert.equal(loaded.has("PretendPlugin"), false);
  assert.equal(loaded.get("Jotunn"), "2.30.0");
});

test("a plugin that loaded and then stopped acting fails the verdict", () => {
  // The ServersideQoL 2.0.4 outage: the load line appears and the version matches, while the
  // plugin does nothing. Version matching alone cannot see this.
  const disabledLog = `[Info   :   BepInEx] Loading [ServersideQoL 2.0.4]
[Error  :ServersideQoL] Unsupported network version: 40, expected: 39
[Error  :ServersideQoL] Version checks failed. Mod execution is stopped`;
  const hits = findSelfDisabled(disabledLog);
  assert.equal(hits.length, 2);

  const input = manifest([mod({ plugin_name: "ServersideQoL", version: "2.0.4" })]);
  const comparison = compare(
    input,
    parseLoadedPlugins(disabledLog),
    hits,
  );
  assert.deepEqual(comparison.mismatched, [], "the version genuinely matches");
  assert.equal(isClean(comparison), false, "and it still must not pass");
  assert.match(report(comparison), /SELF-DISABLED/);
});

test("a healthy log reports nothing self-disabled", () => {
  assert.deepEqual(findSelfDisabled(SAMPLE_LOG), []);
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
