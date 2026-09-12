#!/usr/bin/env node

/**
 * Turns the estate's pinned mod manifest (mods/manifest.json) into a Thunderstore
 * modpack: a package containing only a pinned dependency list, so a player's mod
 * manager tracks one thing and moves all four client mods together.
 *
 * Pure transformations only. The file, network and zip work lives in modpack-build.mts.
 */

export const PLACEHOLDER_NAMESPACE = "REPLACE_WITH_THUNDERSTORE_TEAM";

const PACKAGE_NAME_PATTERN = /^[a-zA-Z0-9_]+$/;
const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;
const DESCRIPTION_LIMIT = 250;

export type ModSide = "both" | "server" | "client";

export interface EstateMod {
  thunderstore: string | null;
  name?: string;
  version: string;
  upstream_version?: string;
  upstream?: string;
  side: ModSide;
  enforced?: boolean;
  source?: string;
  why: string;
  artifact_sha256?: Record<string, string>;
  /** What BepInEx prints in LogOutput.log. Null where it is not known or not a plugin. */
  plugin_name?: string | null;
  /** Only when the logged version differs from `version`, as it does for the loader. */
  plugin_version?: string;
  plugin_name_note?: string;
}

export interface ModpackSettings {
  namespace: string;
  name: string;
  version_number: string;
  website_url: string;
  description: string;
}

export interface EstateManifest {
  world: string;
  game_version: string;
  network_version: number;
  modpack: ModpackSettings;
  verified: Record<string, { at: string; method: string; note?: string }>;
  mods: EstateMod[];
}

export interface ThunderstoreManifest {
  name: string;
  version_number: string;
  website_url: string;
  description: string;
  dependencies: string[];
}

export function isClientSide(mod: EstateMod): boolean {
  return mod.side === "both" || mod.side === "client";
}

/**
 * A client-side mod that is not on Thunderstore cannot be expressed as a dependency,
 * so it would be silently dropped from the pack and players would be short a mod with
 * nothing reporting it. Callers must treat a non-empty `unpackageable` as fatal.
 */
export function selectClientMods(manifest: EstateManifest): {
  included: EstateMod[];
  unpackageable: EstateMod[];
} {
  const clientMods = manifest.mods.filter(isClientSide);
  return {
    included: clientMods.filter((mod) => mod.thunderstore !== null),
    unpackageable: clientMods.filter((mod) => mod.thunderstore === null),
  };
}

export function dependencyString(mod: EstateMod): string {
  if (mod.thunderstore === null) {
    throw new Error(
      `${mod.name ?? "a mod"} has no Thunderstore id and cannot be a dependency`,
    );
  }
  return `${mod.thunderstore}-${mod.version}`;
}

export function buildThunderstoreManifest(
  manifest: EstateManifest,
): ThunderstoreManifest {
  const { included } = selectClientMods(manifest);
  return {
    name: manifest.modpack.name,
    version_number: manifest.modpack.version_number,
    website_url: manifest.modpack.website_url,
    description: manifest.modpack.description,
    dependencies: included.map(dependencyString),
  };
}

/**
 * Returns the whole list of problems, so one build run costs one fix round instead of
 * one per attempt. An empty array is the only pass.
 */
export function validate(
  manifest: EstateManifest,
  built: ThunderstoreManifest,
): string[] {
  const problems: string[] = [];

  if (manifest.modpack.namespace === PLACEHOLDER_NAMESPACE) {
    problems.push(
      `modpack.namespace is still ${PLACEHOLDER_NAMESPACE}. Create the team on thunderstore.io and put its name here.`,
    );
  }
  if (!PACKAGE_NAME_PATTERN.test(built.name)) {
    problems.push(
      `modpack.name "${built.name}" must be letters, digits and underscores only.`,
    );
  }
  if (!VERSION_PATTERN.test(built.version_number)) {
    problems.push(
      `modpack.version_number "${built.version_number}" must be major.minor.patch.`,
    );
  }
  if (built.description.length > DESCRIPTION_LIMIT) {
    problems.push(
      `modpack.description is ${built.description.length} characters; Thunderstore allows ${DESCRIPTION_LIMIT}.`,
    );
  }
  if (built.dependencies.length === 0) {
    problems.push(
      "no client-side mods resolved, so the pack would install nothing.",
    );
  }

  for (const dependency of built.dependencies) {
    const parts = dependency.split("-");
    if (parts.length !== 3) {
      problems.push(
        `dependency "${dependency}" is not Namespace-Name-Version.`,
      );
      continue;
    }
    if (!VERSION_PATTERN.test(parts[2])) {
      problems.push(
        `dependency "${dependency}" pins version "${parts[2]}", which is not major.minor.patch.`,
      );
    }
  }

  const { unpackageable } = selectClientMods(manifest);
  for (const mod of unpackageable) {
    problems.push(
      `${mod.name ?? "a client mod"} is client-side but has no Thunderstore id, so it cannot ship in the pack.`,
    );
  }

  return problems;
}

export function buildReadme(manifest: EstateManifest): string {
  const { included } = selectClientMods(manifest);
  const enforced = included.filter((mod) => mod.enforced);

  const rows = included
    .map((mod) => `| ${mod.thunderstore} | ${mod.version} | ${mod.why} |`)
    .join("\n");

  const enforcedNote = enforced.length
    ? enforced
        .map(
          (mod) =>
            `**${mod.thunderstore?.split("-")[1]} is version-enforced.** The server rejects any client running a different build, so do not update it on its own. Update this pack and everything moves together.`,
        )
        .join("\n\n")
    : "No mod in this pack is version-enforced.";

  return `# ${manifest.modpack.name.replace(/_/g, " ")}

Client mods for the **${manifest.world}** Valheim server, pinned to the exact versions the server runs.

Install this pack in [Gale](https://github.com/Kesomannen/gale) or [r2modman](https://github.com/ebkr/r2modmanPlus) and launch the game through the manager. When the server's mods change, a new version of this pack is published and your manager offers the update.

## What is in it

| Mod | Version | Why |
| --- | --- | --- |
${rows}

${enforcedNote}

## What is not in it

The server also runs ServersideQoL and its modules, plus Animal Feeding Trough. Those are server-side, so you get their behaviour by connecting and have nothing to install. Console players are covered the same way.

There is deliberately no ValheimPlus config file in this pack. The server has \`serverSyncsConfig = true\` and pushes its settings to you on connect, so a bundled config would only give you a stale copy to fight with.

## If you get kicked at connect

Almost always a ValheimPlus version mismatch. Check that your manager has this pack up to date, and that you have not bumped ValheimPlus by itself.

Game version ${manifest.game_version}, network version ${manifest.network_version}.
`;
}
