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

export interface ParsedDependency {
  namespace: string;
  name: string;
  version: string;
}

/**
 * Splits from the RIGHT. A Thunderstore team namespace may contain hyphens while a package
 * name may not: across all 10,898 Valheim packages, three teams (`sinai-dev`, `LVH-IT`) carry
 * one and zero names do. Splitting from the left rejects `sinai-dev-UnityExplorer-4.8.2` as
 * malformed.
 */
export function parseDependency(dependency: string): ParsedDependency | null {
  const parts = dependency.split("-");
  if (parts.length < 3) return null;
  const namespace = parts.slice(0, -2).join("-");
  const name = parts[parts.length - 2];
  const version = parts[parts.length - 1];
  if (!namespace || !name || !version) return null;
  return { namespace, name, version };
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
  const { included, unpackageable } = selectClientMods(manifest);
  if (unpackageable.length > 0) {
    // Throw instead of documenting a precondition: a short pack installs cleanly and leaves
    // players missing a mod, so forgetting to validate must not be able to produce one.
    const names = unpackageable.map((mod) => mod.name ?? "an unnamed mod");
    throw new Error(
      `client-side mods with no Thunderstore id cannot ship in the pack: ${names.join(", ")}`,
    );
  }
  return {
    name: manifest.modpack.name,
    version_number: manifest.modpack.version_number,
    website_url: manifest.modpack.website_url,
    description: manifest.modpack.description,
    dependencies: included.map(dependencyString),
  };
}

const VALID_SIDES: ModSide[] = ["both", "server", "client"];

/**
 * Returns the whole list of problems, so one build run costs one fix round instead of
 * one per attempt. An empty array is the only pass. Takes the manifest alone rather than a
 * built package, because it has to run BEFORE the build: several of these problems make the
 * build itself unsafe.
 */
export function validate(manifest: EstateManifest): string[] {
  const problems: string[] = [];
  const { name, version_number, description, namespace } = manifest.modpack;

  if (namespace === PLACEHOLDER_NAMESPACE) {
    problems.push(
      `modpack.namespace is still ${PLACEHOLDER_NAMESPACE}. Create the team on thunderstore.io and put its name here.`,
    );
  }
  if (!PACKAGE_NAME_PATTERN.test(name)) {
    problems.push(
      `modpack.name "${name}" must be letters, digits and underscores only.`,
    );
  }
  if (!VERSION_PATTERN.test(version_number)) {
    problems.push(
      `modpack.version_number "${version_number}" must be major.minor.patch.`,
    );
  }
  if (description.length > DESCRIPTION_LIMIT) {
    problems.push(
      `modpack.description is ${description.length} characters; Thunderstore allows ${DESCRIPTION_LIMIT}.`,
    );
  }

  // A side the code does not recognise is treated as server-only by `isClientSide`, so a typo
  // would quietly drop a required client mod from the pack. Reject it instead.
  for (const mod of manifest.mods) {
    const label = mod.thunderstore ?? mod.name ?? "an unnamed mod";
    if (!VALID_SIDES.includes(mod.side)) {
      problems.push(
        `${label} has side "${mod.side}", which must be one of ${VALID_SIDES.join(", ")}.`,
      );
    }
  }

  const { included, unpackageable } = selectClientMods(manifest);
  for (const mod of unpackageable) {
    problems.push(
      `${mod.name ?? "a client mod"} is client-side but has no Thunderstore id, so it cannot ship in the pack.`,
    );
  }
  if (included.length === 0) {
    problems.push(
      "no client-side mods resolved, so the pack would install nothing.",
    );
  }

  for (const mod of included) {
    const dependency = dependencyString(mod);
    const parsed = parseDependency(dependency);
    if (parsed === null) {
      problems.push(`dependency "${dependency}" is not Namespace-Name-Version.`);
      continue;
    }
    if (!VERSION_PATTERN.test(parsed.version)) {
      problems.push(
        `dependency "${dependency}" pins version "${parsed.version}", which is not major.minor.patch.`,
      );
    }
  }

  return problems;
}

function displayName(mod: EstateMod): string {
  if (mod.thunderstore === null) return mod.name ?? "an unnamed mod";
  return parseDependency(dependencyString(mod))?.name ?? mod.thunderstore;
}

export function buildReadme(manifest: EstateManifest): string {
  const { included } = selectClientMods(manifest);
  const enforced = included.filter((mod) => mod.enforced);
  const serverOnly = manifest.mods.filter((mod) => mod.side === "server");

  const rows = included
    .map((mod) => `| ${mod.thunderstore} | ${mod.version} | ${mod.why} |`)
    .join("\n");

  const enforcedNote = enforced.length
    ? enforced
        .map(
          (mod) =>
            `**${displayName(mod)} is version-enforced.** The server rejects any client running a different build, so do not update it on its own. Update this pack and everything moves together.`,
        )
        .join("\n\n")
    : "No mod in this pack is version-enforced.";

  // Derived from the manifest rather than written out, so this paragraph cannot drift from
  // the pinned record the way a hand-maintained list would.
  const serverSentence = serverOnly.length
    ? `The server also runs ${serverOnly.map(displayName).join(", ")}. Those are server-side, so you get their behaviour by connecting and have nothing to install. Console players are covered the same way.`
    : "Every mod the server runs is in this pack.";

  return `# ${manifest.modpack.name.replace(/_/g, " ")}

Client mods for the **${manifest.world}** Valheim server, pinned to the exact versions the server runs.

Install this pack in [Gale](https://github.com/Kesomannen/gale) or [r2modman](https://github.com/ebkr/r2modmanPlus) and launch the game through the manager. When the server's mods change, a new version of this pack is published and your manager offers the update.

## What is in it

| Mod | Version | Why |
| --- | --- | --- |
${rows}

${enforcedNote}

## What is not in it

${serverSentence}

There is deliberately no ValheimPlus config file in this pack. The server has \`serverSyncsConfig = true\` and pushes its settings to you on connect, so a bundled config would only give you a stale copy to fight with.

## If you get kicked at connect

Almost always a ValheimPlus version mismatch. Check that your manager has this pack up to date, and that you have not bumped ValheimPlus by itself.

Game version ${manifest.game_version}, network version ${manifest.network_version}.
`;
}
