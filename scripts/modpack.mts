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
  /**
   * Opt-in: this client mod cannot ship in the pack (it is not on Thunderstore) and every
   * player installs it themselves. Without the flag, a missing id is treated as a mistake.
   */
  hand_install?: boolean;
  /**
   * Opt-in: the pack COULD carry this and deliberately does not, because it is operator
   * tooling, not shared gameplay. Distinct from `hand_install`, which covers what the pack
   * can carry; this covers what it should carry.
   */
  admin_only?: boolean;
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
 * one and zero names do. Splitting from the left reads `sinai-dev-UnityExplorer` as the team
 * `sinai` owning `dev-UnityExplorer`, which is a package that does not exist.
 */
export function parsePackageIdentifier(
  identifier: string,
): { namespace: string; name: string } | null {
  const parts = identifier.split("-");
  if (parts.length < 2) return null;
  const namespace = parts.slice(0, -1).join("-");
  const name = parts[parts.length - 1];
  if (!namespace || !name) return null;
  return { namespace, name };
}

export function parseDependency(dependency: string): ParsedDependency | null {
  const parts = dependency.split("-");
  if (parts.length < 3) return null;
  const version = parts[parts.length - 1];
  const owner = parsePackageIdentifier(parts.slice(0, -1).join("-"));
  if (owner === null || !version) return null;
  return { ...owner, version };
}

export function isClientSide(mod: EstateMod): boolean {
  return mod.side === "both" || mod.side === "client";
}

/**
 * A client-side mod that is not on Thunderstore cannot be expressed as a dependency, so it
 * would be silently dropped from the pack and players would be short a mod with nothing
 * reporting it. That stays fatal.
 *
 * `handInstall` is the deliberate exception: a mod we KNOW the pack cannot carry, opted in
 * with `hand_install: true`, which the generated page then tells players to install
 * themselves. The flag exists so the exception has to be written down rather than inferred
 * from a missing id, which is indistinguishable from the mistake.
 *
 * `adminOnly` is the other direction: it HAS an id and the pack could carry it, but it is
 * operator tooling, so shipping it would install something on five machines for one
 * person's benefit. It stays in the manifest because the estate record is meant to list
 * every mod in play, and leaving it out invites the next session to add it to the pack.
 */
export function selectClientMods(manifest: EstateManifest): {
  included: EstateMod[];
  unpackageable: EstateMod[];
  handInstall: EstateMod[];
  adminOnly: EstateMod[];
} {
  // Split on whether the pack CAN carry it first, then on the opt-in flag within each half.
  // Two independent axes rather than four hand-written filters, because four filters that
  // each decide membership alone can overlap, and one that overlapped put admin tooling in
  // the players' install-this-yourself list.
  const clientMods = manifest.mods.filter(isClientSide);
  const packageable = clientMods.filter((mod) => mod.thunderstore !== null);
  const offThunderstore = clientMods.filter((mod) => mod.thunderstore === null);
  return {
    included: packageable.filter((mod) => mod.admin_only !== true),
    adminOnly: packageable.filter((mod) => mod.admin_only === true),
    unpackageable: offThunderstore.filter((mod) => mod.hand_install !== true),
    handInstall: offThunderstore.filter((mod) => mod.hand_install === true),
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
  // The buckets alone cannot catch these: a mod carrying a contradictory pair still lands in
  // exactly one of them, and the one it lands in looks ordinary from the inside. The two
  // checks are scoped differently on purpose. A missing id only matters where the pack
  // could have carried the mod, so that check is client-side. Two flags that deny each
  // other are a confused record on any side, so that check is not client-only.
  for (const mod of manifest.mods) {
    const label = mod.name ?? mod.thunderstore ?? "a mod";
    if (
      mod.admin_only === true &&
      mod.thunderstore === null &&
      isClientSide(mod)
    ) {
      problems.push(
        `${label} is admin_only but has no Thunderstore id. admin_only withholds something the pack COULD carry; a missing id is the other problem and needs hand_install.`,
      );
    }
    if (mod.admin_only === true && mod.hand_install === true) {
      problems.push(
        `${label} sets both hand_install and admin_only, which contradict: one says the pack cannot carry it, the other that it should not.`,
      );
    }
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
  const { included, handInstall } = selectClientMods(manifest);
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

  const handInstallSection = handInstall.length
    ? `\n## You must install these yourself\n\nThe server requires ${handInstall.length === 1 ? "this mod" : "these mods"} and will refuse your connection without ${handInstall.length === 1 ? "it" : "them"}, but ${handInstall.length === 1 ? "it is" : "they are"} not on Thunderstore, so this pack cannot carry ${handInstall.length === 1 ? "it" : "them"}.\n\n${handInstall
        .map(
          (mod) =>
            `- **${displayName(mod)} ${mod.version}**${mod.upstream ? ` (${mod.upstream})` : ""}. Drop the DLL into this profile's \`BepInEx/plugins\` folder.`,
        )
        .join("\n")}\n`
    : "";

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
${handInstallSection}
## What is not in it

${serverSentence}

There is deliberately no ValheimPlus config file in this pack. The server has \`serverSyncsConfig = true\` and pushes its settings to you on connect, so a bundled config would only give you a stale copy to fight with.

## If you get kicked at connect

Almost always a ValheimPlus version mismatch. Check that your manager has this pack up to date, and that you have not bumped ValheimPlus by itself.

Game version ${manifest.game_version}, network version ${manifest.network_version}.
`;
}
