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
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildReadme,
  buildThunderstoreManifest,
  parseDependency,
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
  const parsed = parseDependency(dependency);
  if (parsed === null) {
    // `unreachable`, not `missing`: nothing was looked up, so this says nothing about
    // whether the version exists.
    return {
      dependency,
      status: "unreachable",
      detail: "not in Namespace-Name-Version form, so it was never looked up",
    };
  }
  const { namespace, name, version } = parsed;
  const url = `https://thunderstore.io/api/experimental/package/${namespace}/${name}/${version}/`;

  try {
    const response = await fetch(url, {
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      // A redirect to a landing page answers 200, which would confirm a version nobody
      // looked at. Refuse the redirect rather than following it.
      redirect: "manual",
    });
    if (response.status === 404) {
      return {
        dependency,
        status: "missing",
        detail: "HTTP 404, no such package version",
      };
    }
    if (response.status !== 200) {
      return {
        dependency,
        status: "unreachable",
        detail: `HTTP ${response.status}`,
      };
    }

    // A 200 alone is not the answer: confirm the body describes the package that was asked
    // for, so a challenge page or a generic payload cannot stand in for the version.
    let payload: unknown;
    try {
      payload = await response.json();
    } catch (error) {
      return {
        dependency,
        status: "unreachable",
        detail: `HTTP 200 with a body that is not JSON: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
    const described = payload as {
      namespace?: string;
      name?: string;
      version_number?: string;
    } | null;
    if (
      described?.namespace !== namespace ||
      described?.name !== name ||
      described?.version_number !== version
    ) {
      return {
        dependency,
        status: "unreachable",
        detail: `HTTP 200 describing ${described?.namespace}/${described?.name}/${described?.version_number}, not the package requested`,
      };
    }
    return { dependency, status: "present", detail: "HTTP 200, payload matches" };
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

export const PACKAGE_ENTRIES = ["manifest.json", "README.md", "icon.png"];

/**
 * Reopens the archive rather than trusting the zip process's exit code, because a green
 * return is not evidence that the file on disk is the package. Throws on anything else.
 */
export function verifyArchive(
  zipPath: string,
  listEntries: (path: string) => string[] = defaultListEntries,
): void {
  if (!existsSync(zipPath)) {
    throw new Error(`the archive was not written to ${zipPath}`);
  }
  const { size } = statSync(zipPath);
  if (size === 0) {
    throw new Error(`the archive at ${zipPath} is empty`);
  }
  const entries = listEntries(zipPath).sort();
  const expected = [...PACKAGE_ENTRIES].sort();
  if (entries.join("\n") !== expected.join("\n")) {
    throw new Error(
      `the archive holds [${entries.join(", ")}] at its root, expected [${expected.join(", ")}]`,
    );
  }
}

function defaultListEntries(zipPath: string): string[] {
  // `unzip -Z1` lists entry paths one per line and exits non-zero on a corrupt archive.
  return execFileSync("unzip", ["-Z1", zipPath], { encoding: "utf8" })
    .split("\n")
    .map((entry: string) => entry.trim())
    .filter((entry: string) => entry !== "");
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

  // Validation runs on the manifest and BEFORE the build, because several of the problems it
  // catches make building itself unsafe.
  const problems = validate(manifest);
  if (problems.length > 0) {
    console.error("Refusing to build. Fix mods/manifest.json:");
    for (const problem of problems) console.error(`  - ${problem}`);
    return 1;
  }
  const built: ThunderstoreManifest = buildThunderstoreManifest(manifest);

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

    // Thunderstore refuses a version it already holds, so catching it here turns a failed
    // upload into a failed build.
    const alreadyPublished = await checkDependencyExists(
      `${manifest.modpack.namespace}-${built.name}-${built.version_number}`,
    );
    if (alreadyPublished.status === "present") {
      console.error(
        `Refusing to build. ${manifest.modpack.namespace}/${built.name} ${built.version_number} is already published; bump modpack.version_number.`,
      );
      return 1;
    }
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

  // An offline build names itself, so an unverified pack cannot be mistaken for a checked one
  // on disk or handed to someone as if it had been.
  const zipName = offline
    ? `${built.name}-${built.version_number}-UNVERIFIED.zip`
    : `${built.name}-${built.version_number}.zip`;
  const zipPath = join(distDir, zipName);

  try {
    // Thunderstore reads the three files from the archive root, so paths are junked.
    execFileSync(
      "zip",
      ["-j", "-q", zipPath, "manifest.json", "README.md", "icon.png"],
      { cwd: outputDir, stdio: "inherit" },
    );
    verifyArchive(zipPath);
  } catch (error) {
    // Info-ZIP writes as it goes, so a failure can leave a partial archive that a later
    // upload would happily pick up. Take the whole directory with it.
    rmSync(distDir, { recursive: true, force: true });
    console.error(
      `Refusing to report a build. The archive step failed and dist/ was removed: ${error instanceof Error ? error.message : String(error)}`,
    );
    return 1;
  }

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
