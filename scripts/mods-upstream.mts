#!/usr/bin/env node

/**
 * Answers two questions the verifier cannot, because both are about the outside world
 * rather than the box:
 *
 *   1. Has any pinned mod shipped a newer version on Thunderstore?
 *   2. Is the published client pack still the version the manifest names?
 *
 * The second is the one that bites quietly. A manifest bumped without a publish leaves
 * players on the old pack until somebody is kicked by ValheimPlus with a message that
 * does not explain itself.
 *
 *   node scripts/mods-upstream.mts
 *
 * Exit 0 when everything is current, 1 when something has drifted, 2 when a lookup failed
 * and the answer is therefore unknown.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parsePackageIdentifier } from "./modpack.mts";
import type { EstateManifest, EstateMod } from "./modpack.mts";

const REQUEST_TIMEOUT_MS = 15_000;

export interface PackageState {
  identifier: string;
  pinned: string;
  latest: string | null;
  /** Set when the lookup itself failed, so "unknown" never renders as "current". */
  error: string | null;
}

export interface UpstreamReport {
  current: PackageState[];
  behind: PackageState[];
  unknown: PackageState[];
  pack: PackState;
}

export interface PackState {
  identifier: string;
  manifestVersion: string;
  publishedVersion: string | null;
  status: "published" | "unpublished" | "behind" | "unknown";
  detail: string;
}

/** Thunderstore lists versions newest first, so the latest is the head of the list. */
export function latestVersionFrom(payload: unknown): string | null {
  const listing = payload as { latest?: { version_number?: string } } | null;
  const version = listing?.latest?.version_number;
  return typeof version === "string" && version !== "" ? version : null;
}

export async function fetchLatestVersion(
  identifier: string,
  fetchImpl: typeof globalThis.fetch = globalThis.fetch,
): Promise<{ latest: string | null; error: string | null }> {
  const parsed = parsePackageIdentifier(identifier);
  if (parsed === null) {
    return { latest: null, error: `"${identifier}" is not Namespace-Name` };
  }
  const { namespace, name } = parsed;
  const url = `https://thunderstore.io/api/experimental/package/${namespace}/${name}/`;
  try {
    const response = await fetchImpl(url, {
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      redirect: "manual",
    });
    if (response.status !== 200) {
      return { latest: null, error: `HTTP ${response.status}` };
    }
    const latest = latestVersionFrom(await response.json());
    return latest === null
      ? { latest: null, error: "the payload carried no latest version" }
      : { latest, error: null };
  } catch (error) {
    return {
      latest: null,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export function classify(states: PackageState[]): {
  current: PackageState[];
  behind: PackageState[];
  unknown: PackageState[];
} {
  return {
    current: states.filter(
      (state) => state.error === null && state.latest === state.pinned,
    ),
    behind: states.filter(
      (state) => state.error === null && state.latest !== state.pinned,
    ),
    unknown: states.filter((state) => state.error !== null),
  };
}

/**
 * The manifest pins what SHOULD be published. Anything other than an exact match means
 * players are not running what the manifest says they are.
 */
export function classifyPack(
  identifier: string,
  manifestVersion: string,
  published: { latest: string | null; error: string | null },
): PackState {
  if (published.error !== null) {
    // A 404 here is the specific, expected case of "never published", not a failed lookup.
    if (published.error === "HTTP 404") {
      return {
        identifier,
        manifestVersion,
        publishedVersion: null,
        status: "unpublished",
        detail: "no version of this pack has been published yet",
      };
    }
    return {
      identifier,
      manifestVersion,
      publishedVersion: null,
      status: "unknown",
      detail: published.error,
    };
  }
  if (published.latest === manifestVersion) {
    return {
      identifier,
      manifestVersion,
      publishedVersion: published.latest,
      status: "published",
      detail: "the published pack matches the manifest",
    };
  }
  return {
    identifier,
    manifestVersion,
    publishedVersion: published.latest,
    status: "behind",
    detail: `the manifest names ${manifestVersion} but ${published.latest} is published`,
  };
}

export function report(upstream: UpstreamReport): string {
  const lines: string[] = [];

  for (const state of upstream.current) {
    lines.push(`  ok        ${state.identifier} ${state.pinned}`);
  }
  for (const state of upstream.behind) {
    lines.push(
      `  BEHIND    ${state.identifier}: pinned ${state.pinned}, Thunderstore has ${state.latest}`,
    );
  }
  for (const state of upstream.unknown) {
    lines.push(`  UNKNOWN   ${state.identifier}: ${state.error}`);
  }

  const { pack } = upstream;
  lines.push(
    pack.status === "published"
      ? `  ok        ${pack.identifier} ${pack.manifestVersion} is published`
      : `  PACK ${pack.status.toUpperCase()} ${pack.identifier}: ${pack.detail}`,
  );

  lines.push("");
  lines.push(summarize(upstream));
  return lines.join("\n");
}

export function summarize(upstream: UpstreamReport): string {
  const parts: string[] = [];
  if (upstream.behind.length > 0) {
    parts.push(
      `${upstream.behind.length} mod${upstream.behind.length === 1 ? "" : "s"} behind upstream`,
    );
  }
  if (upstream.pack.status === "behind" || upstream.pack.status === "unpublished") {
    parts.push(`the client pack is ${upstream.pack.status}`);
  }
  if (upstream.unknown.length > 0 || upstream.pack.status === "unknown") {
    parts.push(
      `${upstream.unknown.length + (upstream.pack.status === "unknown" ? 1 : 0)} lookups failed, so their state is unknown rather than fine`,
    );
  }
  return parts.length === 0
    ? "CURRENT: every pin matches Thunderstore and the published pack matches the manifest."
    : `ATTENTION: ${parts.join("; ")}.`;
}

export function exitCode(upstream: UpstreamReport): number {
  if (upstream.unknown.length > 0 || upstream.pack.status === "unknown") return 2;
  if (upstream.behind.length > 0) return 1;
  if (upstream.pack.status !== "published") return 1;
  return 0;
}

export async function buildReport(
  manifest: EstateManifest,
  fetchImpl: typeof globalThis.fetch = globalThis.fetch,
): Promise<UpstreamReport> {
  const onThunderstore = manifest.mods.filter(
    (mod: EstateMod) => mod.thunderstore !== null,
  );
  const states = await Promise.all(
    onThunderstore.map(async (mod: EstateMod): Promise<PackageState> => {
      const identifier = mod.thunderstore as string;
      const { latest, error } = await fetchLatestVersion(identifier, fetchImpl);
      return { identifier, pinned: mod.version, latest, error };
    }),
  );

  const packIdentifier = `${manifest.modpack.namespace}-${manifest.modpack.name}`;
  const pack = classifyPack(
    packIdentifier,
    manifest.modpack.version_number,
    await fetchLatestVersion(packIdentifier, fetchImpl),
  );

  return { ...classify(states), pack };
}

async function main(): Promise<number> {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const manifest = JSON.parse(
    readFileSync(join(root, "mods", "manifest.json"), "utf8"),
  ) as EstateManifest;

  const upstream = await buildReport(manifest);
  console.log(report(upstream));
  return exitCode(upstream);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main()
    .then((code) => process.exit(code))
    .catch((error) => {
      console.error(error);
      process.exit(2);
    });
}
