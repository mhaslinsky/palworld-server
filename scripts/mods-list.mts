#!/usr/bin/env node

/**
 * Renders mods/manifest.json into the three buckets people actually ask about: what runs
 * only on the server, what every player installs through the pack, and what is neither.
 *
 *   node scripts/mods-list.mts            # readable
 *   node scripts/mods-list.mts --markdown # paste into Discord or a README
 *
 * A rendering rather than a second list, so it cannot drift from the manifest.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { selectClientMods } from "./modpack.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

export interface Buckets {
  serverOnly: EstateMod[];
  inPack: EstateMod[];
  /** In the pack's reach but not deliverable through it, so somebody installs it by hand. */
  clientByHand: EstateMod[];
}

export function bucket(manifest: EstateManifest): Buckets {
  // Delegated rather than re-filtered: pack membership has exceptions now (hand installs,
  // admin tooling), and a second copy of the rule is how this rendering starts lying.
  const { included, unpackageable, handInstall } = selectClientMods(manifest);
  return {
    serverOnly: manifest.mods.filter((mod) => mod.side === "server"),
    inPack: included,
    clientByHand: [...unpackageable, ...handInstall],
  };
}


export function label(mod: EstateMod): string {
  return mod.thunderstore ?? mod.name ?? "an unnamed mod";
}

function source(mod: EstateMod): string {
  if (mod.thunderstore !== null) return "Thunderstore";
  return mod.source === "nexus" ? "Nexus, by hand" : "by hand";
}

export function render(manifest: EstateManifest, markdown: boolean): string {
  const { serverOnly, inPack, clientByHand } = bucket(manifest);
  const lines: string[] = [];
  const heading = (text: string) =>
    lines.push(markdown ? `\n### ${text}\n` : `\n${text}\n${"-".repeat(text.length)}`);

  const row = (mod: EstateMod, extra: string) =>
    lines.push(
      markdown
        ? `| ${label(mod)} | ${mod.version} | ${extra} |`
        : `  ${label(mod).padEnd(46)} ${mod.version.padEnd(10)} ${extra}`,
    );
  const tableHead = (last: string) => {
    if (markdown) lines.push(`| Mod | Version | ${last} |`, "| --- | --- | --- |");
  };

  lines.push(
    markdown
      ? `## ${manifest.world} mods\n\nPack **${manifest.modpack.namespace}-${manifest.modpack.name} ${manifest.modpack.version_number}**, Valheim ${manifest.game_version}.`
      : `${manifest.world} mods. Pack ${manifest.modpack.name} ${manifest.modpack.version_number}, Valheim ${manifest.game_version}.`,
  );

  heading(`In the client pack (${inPack.length}), everyone installs these`);
  tableHead("Notes");
  for (const mod of inPack) {
    row(mod, mod.enforced ? "VERSION ENFORCED: a mismatch is kicked at connect" : "");
  }

  heading(`Server only (${serverOnly.length}), nobody installs these`);
  tableHead("Source");
  for (const mod of serverOnly) row(mod, source(mod));

  if (clientByHand.length > 0) {
    heading(`Client-side but NOT deliverable by the pack (${clientByHand.length})`);
    tableHead("Source");
    for (const mod of clientByHand) row(mod, source(mod));
    lines.push(
      markdown
        ? "\nThese have to be installed by hand on every client, because the pack can only carry Thunderstore packages."
        : "\n  These need a manual install on every client: the pack can only carry Thunderstore packages.",
    );
  }

  heading("Outside all of the above");
  lines.push(
    markdown
      ? "Anything a player installs beyond the pack is theirs and unmanaged. It is not tracked here and it is the first thing to suspect when one person has a problem nobody else has."
      : "  Anything a player adds beyond the pack is theirs and unmanaged. Not tracked here,\n  and the first thing to suspect when one person has a problem nobody else has.",
  );

  return lines.join("\n");
}

function main(): number {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const manifest = JSON.parse(
    readFileSync(join(root, "mods", "manifest.json"), "utf8"),
  ) as EstateManifest;
  console.log(render(manifest, process.argv.includes("--markdown")));
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
