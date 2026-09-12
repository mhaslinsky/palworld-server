#!/usr/bin/env node

/**
 * Compares mods/manifest.json against what BepInEx actually loaded, so the pinned
 * versions are checkable rather than asserted.
 *
 *   ssh <box> 'cat /home/steam/valheim/BepInEx/LogOutput.log' | node scripts/mods-verify.mts
 *   node scripts/mods-verify.mts path/to/LogOutput.log
 *
 * Reads the load log rather than listing the plugins folder, because a DLL on disk that
 * failed to load looks identical to one that worked, and this estate has already been
 * bitten by exactly that (ServersideQoL 2.0.4 sat in the folder logging a version-check
 * failure every five seconds while PortalProgression silently did nothing).
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { EstateManifest, EstateMod } from "./modpack.mts";

const LOADING_PATTERN = /Loading \[(.+) ([0-9]+(?:\.[0-9]+)+)\]/;
const LOADER_PATTERN = /BepInEx ([0-9]+(?:\.[0-9]+)+) - /;

/**
 * Later entries win, so a log spanning two boots reports the most recent entry rather
 * than a stale line from before a restart.
 */
export function parseLoadedPlugins(logText: string): Map<string, string> {
  const loaded = new Map<string, string>();
  for (const line of logText.split(/\r?\n/)) {
    const loading = LOADING_PATTERN.exec(line);
    if (loading) {
      loaded.set(loading[1].trim(), loading[2]);
      continue;
    }
    const loader = LOADER_PATTERN.exec(line);
    if (loader) {
      loaded.set("BepInEx", loader[1]);
    }
  }
  return loaded;
}

export function expectedPluginVersion(mod: EstateMod): string {
  return mod.plugin_version ?? mod.version;
}

export interface Comparison {
  matched: string[];
  mismatched: { plugin: string; expected: string; found: string }[];
  notLoaded: string[];
  unverifiable: { label: string; reason: string }[];
  unexpected: { plugin: string; version: string }[];
}

export function compare(
  manifest: EstateManifest,
  loaded: Map<string, string>,
): Comparison {
  const comparison: Comparison = {
    matched: [],
    mismatched: [],
    notLoaded: [],
    unverifiable: [],
    unexpected: [],
  };
  const accountedFor = new Set<string>();

  for (const mod of manifest.mods) {
    const label = mod.thunderstore ?? mod.name ?? "an unnamed mod";
    if (!mod.plugin_name) {
      comparison.unverifiable.push({
        label,
        reason: mod.plugin_name_note ?? "no plugin_name in the manifest",
      });
      continue;
    }
    accountedFor.add(mod.plugin_name);

    const found = loaded.get(mod.plugin_name);
    if (found === undefined) {
      comparison.notLoaded.push(mod.plugin_name);
      continue;
    }
    const expected = expectedPluginVersion(mod);
    if (found === expected) {
      comparison.matched.push(`${mod.plugin_name} ${found}`);
    } else {
      comparison.mismatched.push({ plugin: mod.plugin_name, expected, found });
    }
  }

  for (const [plugin, version] of loaded) {
    if (!accountedFor.has(plugin)) {
      comparison.unexpected.push({ plugin, version });
    }
  }

  return comparison;
}

/**
 * An empty log yields no matches and no mismatches, which must not read as a pass.
 * Anything other than at least one match plus zero discrepancies is a failure.
 */
export function isClean(comparison: Comparison): boolean {
  return (
    comparison.matched.length > 0 &&
    comparison.mismatched.length === 0 &&
    comparison.notLoaded.length === 0 &&
    comparison.unexpected.length === 0
  );
}

export function report(comparison: Comparison): string {
  const lines: string[] = [];

  for (const entry of comparison.matched) lines.push(`  ok        ${entry}`);
  for (const entry of comparison.mismatched) {
    lines.push(
      `  MISMATCH  ${entry.plugin}: manifest says ${entry.expected}, box loaded ${entry.found}`,
    );
  }
  for (const plugin of comparison.notLoaded) {
    lines.push(`  NOT LOADED ${plugin}: in the manifest, absent from the log`);
  }
  for (const entry of comparison.unexpected) {
    lines.push(
      `  UNEXPECTED ${entry.plugin} ${entry.version}: loaded on the box, not in the manifest`,
    );
  }
  for (const entry of comparison.unverifiable) {
    lines.push(`  unchecked ${entry.label}: ${entry.reason}`);
  }

  lines.push("");
  lines.push(
    isClean(comparison)
      ? `CLEAN: ${comparison.matched.length} plugins match the manifest.`
      : "DRIFT: the box and mods/manifest.json disagree. Neither is automatically right; decide which, then fix the other.",
  );
  if (comparison.unverifiable.length > 0) {
    lines.push(
      `${comparison.unverifiable.length} entries could not be checked from the log and are NOT covered by the verdict above.`,
    );
  }
  return lines.join("\n");
}

function readLogText(): string {
  const pathArgument = process.argv[2];
  if (pathArgument) return readFileSync(pathArgument, "utf8");
  return readFileSync(0, "utf8");
}

function main(): number {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const manifest = JSON.parse(
    readFileSync(join(root, "mods", "manifest.json"), "utf8"),
  ) as EstateManifest;

  const logText = readLogText();
  if (logText.trim() === "") {
    console.error(
      "The log was empty. Nothing was checked, which is not the same as nothing being wrong.",
    );
    return 2;
  }

  const comparison = compare(manifest, parseLoadedPlugins(logText));
  console.log(report(comparison));
  return isClean(comparison) ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
