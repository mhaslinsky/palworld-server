#!/usr/bin/env node

/**
 * Builds the publishable Thunderstore modpack from mods/manifest.json.
 *
 *   node scripts/modpack-build.mts [--offline]
 *
 * Writes mods/modpack/{manifest.json,README.md,icon.png} and zips them into
 * mods/modpack/dist/. Exits non-zero on any problem, including a pinned version that
 * does not exist on Thunderstore, because publishing that pack would hand every player
 * a resolve failure.
 */

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildReadme,
  buildThunderstoreManifest,
  validate,
  type EstateManifest,
  type ThunderstoreManifest,
} from "./modpack.mts";
import { encodePng, renderAlgizIcon } from "./png.mts";

const ICON_SIZE = 256;
const REQUEST_TIMEOUT_MS = 15_000;

export interface VersionCheck {
  dependency: string;
  status: "present" | "missing" | "unreachable";
  detail: string;
}

/**
 * `unreachable` is distinct from `missing`: a network failure must never read as "that
 * version is fine", nor as "that version is gone". The caller fails the build on both
 * and says which it was.
 */
export async function checkDependencyExists(
  dependency: string,
): Promise<VersionCheck> {
  const parts = dependency.split("-");
  if (parts.length !== 3) {
    return {
      dependency,
      status: "missing",
      detail: "not in Namespace-Name-Version form",
    };
  }
  const [namespace, name, version] = parts;
  const url = `https://thunderstore.io/api/experimental/package/${namespace}/${name}/${version}/`;

  try {
    const response = await fetch(url, {
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      redirect: "follow",
    });
    if (response.status === 200) {
      return { dependency, status: "present", detail: "HTTP 200" };
    }
    if (response.status === 404) {
      return {
        dependency,
        status: "missing",
        detail: "HTTP 404, no such package version",
      };
    }
    return {
      dependency,
      status: "unreachable",
      detail: `HTTP ${response.status}`,
    };
  } catch (error) {
    return {
      dependency,
      status: "unreachable",
      detail: error instanceof Error ? error.message : String(error),
    };
  }
}

export function summarize(checks: VersionCheck[]): string[] {
  return checks
    .filter((check) => check.status !== "present")
    .map(
      (check) =>
        `${check.dependency}: ${check.status === "missing" ? "not on Thunderstore" : "could not be checked"} (${check.detail})`,
    );
}

function repoRoot(): string {
  return dirname(dirname(fileURLToPath(import.meta.url)));
}

async function main(): Promise<number> {
  const offline = process.argv.includes("--offline");
  const root = repoRoot();
  const manifestPath = join(root, "mods", "manifest.json");
  const outputDir = join(root, "mods", "modpack");
  const distDir = join(outputDir, "dist");

  const manifest = JSON.parse(
    readFileSync(manifestPath, "utf8"),
  ) as EstateManifest;
  const built: ThunderstoreManifest = buildThunderstoreManifest(manifest);

  const problems = validate(manifest, built);
  if (problems.length > 0) {
    console.error("Refusing to build. Fix mods/manifest.json:");
    for (const problem of problems) console.error(`  - ${problem}`);
    return 1;
  }

  if (offline) {
    console.warn(
      "SKIPPED the Thunderstore existence check (--offline). The pinned versions have NOT been confirmed to exist.",
    );
  } else {
    const checks = await Promise.all(
      built.dependencies.map(checkDependencyExists),
    );
    const failures = summarize(checks);
    if (failures.length > 0) {
      console.error("Refusing to build. Pinned versions failed their check:");
      for (const failure of failures) console.error(`  - ${failure}`);
      return 1;
    }
    console.log(
      `Confirmed all ${checks.length} pinned versions exist on Thunderstore.`,
    );
  }

  rmSync(distDir, { recursive: true, force: true });
  mkdirSync(distDir, { recursive: true });

  writeFileSync(
    join(outputDir, "manifest.json"),
    `${JSON.stringify(built, null, 2)}\n`,
  );
  writeFileSync(join(outputDir, "README.md"), buildReadme(manifest));
  writeFileSync(
    join(outputDir, "icon.png"),
    encodePng(ICON_SIZE, ICON_SIZE, renderAlgizIcon(ICON_SIZE)),
  );

  const zipName = `${built.name}-${built.version_number}.zip`;
  // Thunderstore reads the three files from the archive root, so paths are junked.
  execFileSync(
    "zip",
    ["-j", "-q", join(distDir, zipName), "manifest.json", "README.md", "icon.png"],
    { cwd: outputDir, stdio: "inherit" },
  );

  console.log(`Built mods/modpack/dist/${zipName}`);
  console.log(`  ${built.name} ${built.version_number}`);
  for (const dependency of built.dependencies) {
    console.log(`  depends on ${dependency}`);
  }
  console.log(
    `\nUpload it at https://thunderstore.io/c/valheim/create/ under the "${manifest.modpack.namespace}" team.`,
  );
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main()
    .then((code) => process.exit(code))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
