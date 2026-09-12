#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  PLACEHOLDER_NAMESPACE,
  buildReadme,
  buildThunderstoreManifest,
  dependencyString,
  isClientSide,
  parseDependency,
  selectClientMods,
  validate,
  type EstateManifest,
  type EstateMod,
} from "./modpack.mts";

function mod(overrides: Partial<EstateMod> = {}): EstateMod {
  return {
    thunderstore: "Someone-SomeMod",
    version: "1.0.0",
    side: "both",
    why: "because",
    ...overrides,
  };
}

function manifest(overrides: Partial<EstateManifest> = {}): EstateManifest {
  return {
    world: "Utgarde",
    game_version: "1.0.12",
    network_version: 40,
    modpack: {
      namespace: "SomeTeam",
      name: "Utgarde_Client_Pack",
      version_number: "1.0.0",
      website_url: "https://example.invalid",
      description: "a pack",
    },
    verified: {},
    mods: [
      mod({ thunderstore: "denikson-BepInExPack_Valheim", version: "5.4.2350" }),
      mod({
        thunderstore: "Grantapher-ValheimPlus_Grantapher_Temporary",
        version: "10.1.0",
        enforced: true,
      }),
      mod({ thunderstore: "ArgusMagnus-ServersideQoL", side: "server" }),
    ],
    ...overrides,
  };
}

test("both and client count as client-side, server does not", () => {
  assert.equal(isClientSide(mod({ side: "both" })), true);
  assert.equal(isClientSide(mod({ side: "client" })), true);
  assert.equal(isClientSide(mod({ side: "server" })), false);
});

test("server-only mods are left out of the pack", () => {
  const { included, unpackageable } = selectClientMods(manifest());
  assert.deepEqual(
    included.map((entry) => entry.thunderstore),
    [
      "denikson-BepInExPack_Valheim",
      "Grantapher-ValheimPlus_Grantapher_Temporary",
    ],
  );
  assert.deepEqual(unpackageable, []);
});

test("a client mod with no Thunderstore id is reported, never silently dropped", () => {
  const withNexusClientMod = manifest({
    mods: [
      mod({ thunderstore: "denikson-BepInExPack_Valheim" }),
      mod({ thunderstore: null, name: "Animal Feeding Trough", side: "both" }),
    ],
  });
  const { included, unpackageable } = selectClientMods(withNexusClientMod);
  assert.equal(included.length, 1);
  assert.deepEqual(
    unpackageable.map((entry) => entry.name),
    ["Animal Feeding Trough"],
  );
  assert.match(
    validate(withNexusClientMod).join("\n"),
    /Animal Feeding Trough is client-side but has no Thunderstore id/,
  );
  // Test contract corrected because: the pure builder previously returned a short pack and
  // relied on the caller having validated first, so a future caller could ship players a pack
  // missing a required mod. It now refuses instead.
  assert.throws(
    () => buildThunderstoreManifest(withNexusClientMod),
    /cannot ship in the pack: Animal Feeding Trough/,
  );
});

test("a hyphenated team namespace parses, because only the namespace may contain one", () => {
  // sinai-dev-UnityExplorer and LVH-IT-UseEquipmentInWater are real Valheim packages.
  assert.deepEqual(parseDependency("sinai-dev-UnityExplorer-4.8.2"), {
    namespace: "sinai-dev",
    name: "UnityExplorer",
    version: "4.8.2",
  });
  assert.deepEqual(parseDependency("ValheimModding-Jotunn-2.30.0"), {
    namespace: "ValheimModding",
    name: "Jotunn",
    version: "2.30.0",
  });
  assert.equal(parseDependency("JustTwo-Parts"), null);
  assert.equal(parseDependency("JustOneWord"), null);
});

test("a hyphenated namespace is accepted by validate rather than called malformed", () => {
  const input = manifest({
    mods: [mod({ thunderstore: "sinai-dev-UnityExplorer", version: "4.8.2" })],
  });
  assert.deepEqual(validate(input), []);
});

test("an unrecognised side is rejected instead of reading as server-only", () => {
  const input = manifest({
    mods: [
      mod({ thunderstore: "denikson-BepInExPack_Valheim" }),
      mod({ thunderstore: "Someone-Typo", side: "clinet" as never }),
    ],
  });
  assert.match(
    validate(input).join("\n"),
    /Someone-Typo has side "clinet", which must be one of both, server, client/,
  );
});

test("dependency strings are Namespace-Name-Version", () => {
  assert.equal(
    dependencyString(
      mod({ thunderstore: "ValheimModding-Jotunn", version: "2.30.0" }),
    ),
    "ValheimModding-Jotunn-2.30.0",
  );
});

test("a mod with no Thunderstore id throws rather than producing a broken dependency", () => {
  assert.throws(
    () => dependencyString(mod({ thunderstore: null, name: "Trough" })),
    /Trough has no Thunderstore id/,
  );
});

test("a well-formed manifest validates clean", () => {
  const input = manifest();
  assert.deepEqual(validate(input), []);
});

test("the placeholder namespace blocks the build", () => {
  const input = manifest({
    modpack: { ...manifest().modpack, namespace: PLACEHOLDER_NAMESPACE },
  });
  assert.match(
    validate(input).join("\n"),
    /still REPLACE_WITH_THUNDERSTORE_TEAM/,
  );
});

test("a pack name with a dash or space is rejected", () => {
  for (const badName of ["Utgarde-Client-Pack", "Utgarde Client Pack"]) {
    const input = manifest({
      modpack: { ...manifest().modpack, name: badName },
    });
    assert.match(
      validate(input).join("\n"),
      /must be letters, digits and underscores only/,
      `expected ${badName} to be rejected`,
    );
  }
});

test("a four-part pack version is rejected", () => {
  const input = manifest({
    modpack: { ...manifest().modpack, version_number: "0.10.1.0" },
  });
  assert.match(
    validate(input).join("\n"),
    /must be major\.minor\.patch/,
  );
});

test("a description over the Thunderstore limit is rejected", () => {
  const input = manifest({
    modpack: { ...manifest().modpack, description: "x".repeat(251) },
  });
  assert.match(
    validate(input).join("\n"),
    /251 characters; Thunderstore allows 250/,
  );
  const atLimit = manifest({
    modpack: { ...manifest().modpack, description: "x".repeat(250) },
  });
  assert.deepEqual(validate(atLimit), []);
});

test("a pack that would install nothing is rejected", () => {
  const input = manifest({
    mods: [mod({ side: "server" })],
  });
  assert.match(
    validate(input).join("\n"),
    /would install nothing/,
  );
});

test("a four-part mod version is rejected in a dependency", () => {
  const input = manifest({
    mods: [mod({ thunderstore: "Grantapher-ValheimPlus", version: "0.10.1.0" })],
  });
  assert.match(
    validate(input).join("\n"),
    /pins version "0\.10\.1\.0"/,
  );
});

test("validate reports every problem at once, not just the first", () => {
  const input = manifest({
    modpack: {
      namespace: PLACEHOLDER_NAMESPACE,
      name: "bad name",
      version_number: "1.0",
      website_url: "",
      description: "x".repeat(300),
    },
  });
  assert.equal(validate(input).length, 4);
});

test("the readme lists client mods, omits server mods, and warns about the enforced one", () => {
  const readme = buildReadme(manifest());
  assert.match(readme, /denikson-BepInExPack_Valheim \| 5\.4\.2350/);
  assert.doesNotMatch(readme, /ServersideQoL \|/);
  assert.match(readme, /ValheimPlus_Grantapher_Temporary is version-enforced/);
  assert.match(readme, /Utgarde/);
});

test("the readme names server-side mods from the manifest rather than a fixed list", () => {
  const input = manifest({
    mods: [
      mod({ thunderstore: "denikson-BepInExPack_Valheim" }),
      mod({ thunderstore: "ArgusMagnus-ServersideQoL_AutoStore", side: "server" }),
      mod({ thunderstore: null, name: "Animal Feeding Trough", side: "server" }),
    ],
  });
  const readme = buildReadme(input);
  assert.match(readme, /The server also runs ServersideQoL_AutoStore, Animal Feeding Trough\./);

  const clientOnly = manifest({
    mods: [mod({ thunderstore: "denikson-BepInExPack_Valheim" })],
  });
  assert.match(
    buildReadme(clientOnly),
    /Every mod the server runs is in this pack\./,
  );
});

test("the enforced note uses the package name, not the first hyphen segment", () => {
  const input = manifest({
    mods: [
      mod({
        thunderstore: "sinai-dev-UnityExplorer",
        version: "4.8.2",
        enforced: true,
      }),
    ],
  });
  assert.match(buildReadme(input), /\*\*UnityExplorer is version-enforced\.\*\*/);
});

test("the readme says so when nothing is version-enforced", () => {
  const input = manifest({
    mods: [mod({ thunderstore: "denikson-BepInExPack_Valheim" })],
  });
  assert.match(buildReadme(input), /No mod in this pack is version-enforced/);
});
