#!/usr/bin/env node

/**
 * Compares mods/manifest.json against what BepInEx actually loaded, so the pinned
 * versions are checkable rather than asserted.
 *
 *   ssh <box> 'cat /home/steam/valheim/BepInEx/LogOutput.log' | node scripts/mods-verify.mts
 *   node scripts/mods-verify.mts path/to/LogOutput.log
 *
 * Reads the load log rather than listing the plugins folder, because a DLL on disk that
 * failed to load looks identical to one that worked.
 *
 * A load line is NOT proof the plugin is working. BepInEx prints it when it constructs the
 * plugin, before that plugin's own Awake runs, so one that loads and then disables itself
 * still appears. ServersideQoL 2.0.4 did exactly that on the 1.0.12 network-version bump:
 * it logged a load, then refused to act while ore flowed through portals. Version matching
 * alone cannot see that, which is why `SELF_DISABLED_PATTERNS` is scanned separately.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { EstateManifest, EstateMod } from "./modpack.mts";

// Anchored on BepInEx's own logger tag so a mod printing "Loading [...]" in its own output
// cannot be mistaken for a loaded plugin.
const LOADING_PATTERN = /:\s*BepInEx\]\s*Loading \[(.+) ([0-9]+(?:\.[0-9]+)+)\]/;
const LOADER_PATTERN = /BepInEx ([0-9]+(?:\.[0-9]+)+) - /;
// A new banner means a new boot, so anything gathered before it belongs to a previous run.
const BOOT_BANNER_PATTERN = /BepInEx ([0-9]+(?:\.[0-9]+)+) - \S+ \(/;

/** Phrases a plugin prints when it has loaded and then stopped acting. */
const SELF_DISABLED_PATTERNS: { pattern: RegExp; meaning: string }[] = [
  {
    pattern: /Unsupported network version/i,
    meaning: "a plugin refused the game's network version",
  },
  {
    pattern: /Version checks? failed/i,
    meaning: "a plugin's version check failed",
  },
  {
    pattern: /Mod execution is stopped/i,
    meaning: "a plugin stopped executing after loading",
  },
];

/**
 * Reports the newest boot only. A boot banner CLEARS what came before rather than letting
 * later lines overwrite it: a plugin present in an earlier boot and absent from the newest
 * one would otherwise survive in the map and satisfy the manifest, which is a false pass.
 */
export function parseLoadedPlugins(logText: string): Map<string, string> {
  let loaded = new Map<string, string>();
  for (const line of logText.split(/\r?\n/)) {
    const banner = BOOT_BANNER_PATTERN.exec(line);
    if (banner) {
      loaded = new Map<string, string>();
      loaded.set("BepInEx", banner[1]);
      continue;
    }
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

/** Lines showing a plugin that loaded and then stopped acting, which version matching cannot see. */
export function findSelfDisabled(logText: string): string[] {
  const hits: string[] = [];
  for (const line of logText.split(/\r?\n/)) {
    for (const { pattern, meaning } of SELF_DISABLED_PATTERNS) {
      if (pattern.test(line)) {
        hits.push(`${meaning}: ${line.trim()}`);
        break;
      }
    }
  }
  return hits;
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
  selfDisabled: string[];
}

export function compare(
  manifest: EstateManifest,
  loaded: Map<string, string>,
  selfDisabled: string[] = [],
): Comparison {
  const comparison: Comparison = {
    matched: [],
    mismatched: [],
    notLoaded: [],
    unverifiable: [],
    unexpected: [],
    selfDisabled,
  };
  const accountedFor = new Set<string>();

  // A client-only mod is absent from a server's log by design, so checking for it here would
  // fail a verification that is actually correct.
  const onTheServer = manifest.mods.filter((mod) => mod.side !== "client");

  for (const mod of onTheServer) {
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
 * An empty log yields no matches and no mismatches, which must not read as a pass. An entry
 * that could not be checked is not a pass either: leaving it out of `matched` would otherwise
 * let it ride along on someone else's match, which is the opposite of reporting it.
 */
export function isClean(comparison: Comparison): boolean {
  return (
    comparison.matched.length > 0 &&
    comparison.mismatched.length === 0 &&
    comparison.notLoaded.length === 0 &&
    comparison.unexpected.length === 0 &&
    comparison.unverifiable.length === 0 &&
    comparison.selfDisabled.length === 0
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
    lines.push(`  UNCHECKED ${entry.label}: ${entry.reason}`);
  }
  for (const entry of comparison.selfDisabled) {
    lines.push(`  SELF-DISABLED ${entry}`);
  }

  lines.push("");
  if (isClean(comparison)) {
    lines.push(
      `CLEAN: ${comparison.matched.length} plugins match the manifest, and none reported stopping after load.`,
    );
    return lines.join("\n");
  }

  lines.push(
    "DRIFT: the box and mods/manifest.json disagree. Neither is automatically right; decide which, then fix the other.",
  );
  if (comparison.unverifiable.length > 0) {
    lines.push(
      `${comparison.unverifiable.length} manifest entries could not be checked from the log. Fill in their plugin_name.`,
    );
  }
  if (comparison.selfDisabled.length > 0) {
    lines.push(
      `${comparison.selfDisabled.length} log lines show a plugin that loaded and then stopped acting. A matching version does not mean it is working.`,
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

  const comparison = compare(
    manifest,
    parseLoadedPlugins(logText),
    findSelfDisabled(logText),
  );
  console.log(report(comparison));
  return isClean(comparison) ? 0 : 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
