#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  PLACEHOLDER_NAMESPACE,
  buildReadme,
  buildThunderstoreManifest,
  dependencyString,
  isClientSide,
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
    validate(withNexusClientMod, buildThunderstoreManifest(withNexusClientMod))
      .join("\n"),
    /Animal Feeding Trough is client-side but has no Thunderstore id/,
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
  assert.deepEqual(validate(input, buildThunderstoreManifest(input)), []);
});

test("the placeholder namespace blocks the build", () => {
  const input = manifest({
    modpack: { ...manifest().modpack, namespace: PLACEHOLDER_NAMESPACE },
  });
  assert.match(
    validate(input, buildThunderstoreManifest(input)).join("\n"),
    /still REPLACE_WITH_THUNDERSTORE_TEAM/,
  );
});

test("a pack name with a dash or space is rejected", () => {
  for (const badName of ["Utgarde-Client-Pack", "Utgarde Client Pack"]) {
    const input = manifest({
      modpack: { ...manifest().modpack, name: badName },
    });
    assert.match(
      validate(input, buildThunderstoreManifest(input)).join("\n"),
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
    validate(input, buildThunderstoreManifest(input)).join("\n"),
    /must be major\.minor\.patch/,
  );
});

test("a description over the Thunderstore limit is rejected", () => {
  const input = manifest({
    modpack: { ...manifest().modpack, description: "x".repeat(251) },
  });
  assert.match(
    validate(input, buildThunderstoreManifest(input)).join("\n"),
    /251 characters; Thunderstore allows 250/,
  );
  const atLimit = manifest({
    modpack: { ...manifest().modpack, description: "x".repeat(250) },
  });
  assert.deepEqual(validate(atLimit, buildThunderstoreManifest(atLimit)), []);
});

test("a pack that would install nothing is rejected", () => {
  const input = manifest({
    mods: [mod({ side: "server" })],
  });
  assert.match(
    validate(input, buildThunderstoreManifest(input)).join("\n"),
    /would install nothing/,
  );
});

test("a four-part mod version is rejected in a dependency", () => {
  const input = manifest({
    mods: [mod({ thunderstore: "Grantapher-ValheimPlus", version: "0.10.1.0" })],
  });
  assert.match(
    validate(input, buildThunderstoreManifest(input)).join("\n"),
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
  assert.equal(validate(input, buildThunderstoreManifest(input)).length, 4);
});

test("the readme lists client mods, omits server mods, and warns about the enforced one", () => {
  const readme = buildReadme(manifest());
  assert.match(readme, /denikson-BepInExPack_Valheim \| 5\.4\.2350/);
  assert.doesNotMatch(readme, /ServersideQoL \|/);
  assert.match(readme, /ValheimPlus_Grantapher_Temporary is version-enforced/);
  assert.match(readme, /Utgarde/);
});

test("the readme says so when nothing is version-enforced", () => {
  const input = manifest({
    mods: [mod({ thunderstore: "denikson-BepInExPack_Valheim" })],
  });
  assert.match(buildReadme(input), /No mod in this pack is version-enforced/);
});
