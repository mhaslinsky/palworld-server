#!/usr/bin/env node

/**
 * Publishes the built pack to Thunderstore, so an upgrade does not depend on somebody
 * remembering to drag a zip into a browser.
 *
 *   node scripts/modpack-publish.mts [--dry-run]
 *
 * Four calls, in this order: initiate the upload, PUT each part, finish the upload, submit.
 * Shapes are taken from Thunderstore's own CLI (ThunderstoreCLI/Models/PublishModels.cs)
 * rather than inferred from the endpoints, which only answer 401 without a token.
 *
 * The token is a Thunderstore SERVICE ACCOUNT token belonging to the team, created in team
 * settings. It belongs to the team rather than a person, so revoking it costs one reissue.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { EstateManifest } from "./modpack.mts";
import { checkDependencyExists } from "./modpack-build.mts";

const API = "https://thunderstore.io/api/experimental";
const COMMUNITY = "valheim";
// Slugs, not display names: the API matches "deep-north-update", never "Deep North Update".
// "deep-north-update" is a game-version category and states that the pack targets Valheim 1.0;
// "modpacks" is the content category people filter on to find a pack at all.
const CATEGORIES = ["modpacks", "deep-north-update"];
const TOKEN_PARAMETER = "/palworld-server/thunderstore_token";
const REQUEST_TIMEOUT_MS = 60_000;

export interface UploadPart {
  part_number: number;
  url: string;
  offset: number;
  length: number;
}

export interface CompletedPart {
  ETag: string;
  PartNumber: number;
}

export interface SubmissionMetadata {
  author_name: string;
  categories: string[];
  communities: string[];
  community_categories: Record<string, string[]>;
  has_nsfw_content: boolean;
  upload_uuid: string;
}

/**
 * `community_categories` is what actually assigns categories; the flat `categories` is
 * not keyed by community and did not stick. Measured 2026-09-13: 1.2.0 was submitted with
 * `categories: ["modpacks"]` alone and the listing came back carrying only "Deep North
 * Update", so the pack was missing the one category people filter on to find a modpack.
 * Both are sent because the API accepts both and only one of them is the documented
 * per-community mapping.
 */
export function buildSubmissionMetadata(
  manifest: EstateManifest,
  uploadUuid: string,
): SubmissionMetadata {
  return {
    author_name: manifest.modpack.namespace,
    categories: CATEGORIES,
    communities: [COMMUNITY],
    community_categories: { [COMMUNITY]: CATEGORIES },
    has_nsfw_content: false,
    upload_uuid: uploadUuid,
  };
}

/**
 * A part whose slice would run past the end of the file means the plan and the file
 * disagree, and uploading the truncated remainder would produce a corrupt archive that
 * Thunderstore accepts.
 */
export function sliceParts(
  archive: Buffer,
  parts: UploadPart[],
): { part: UploadPart; body: Buffer }[] {
  if (parts.length === 0) {
    throw new Error("Thunderstore returned no upload URLs");
  }
  return parts.map((part) => {
    const end = part.offset + part.length;
    if (part.offset < 0 || end > archive.length) {
      throw new Error(
        `upload part ${part.part_number} covers bytes ${part.offset}-${end} of a ${archive.length} byte file`,
      );
    }
    return { part, body: archive.subarray(part.offset, end) };
  });
}

/** An S3 part upload that answers without an ETag has not stored the part. */
export function requireEtag(partNumber: number, etag: string | null): CompletedPart {
  if (etag === null || etag === "") {
    throw new Error(`part ${partNumber} was uploaded but returned no ETag`);
  }
  return { ETag: etag, PartNumber: partNumber };
}

export function resolveToken(
  env: Record<string, string | undefined>,
  readParameter: () => string,
): string {
  const fromEnv = env.THUNDERSTORE_TOKEN;
  if (fromEnv && fromEnv.trim() !== "") return fromEnv.trim();
  const fromParameterStore = readParameter().trim();
  if (fromParameterStore === "") {
    throw new Error(
      `no Thunderstore token. Set THUNDERSTORE_TOKEN, or put a team service account token in SSM at ${TOKEN_PARAMETER}.`,
    );
  }
  return fromParameterStore;
}

function readTokenFromParameterStore(): string {
  try {
    return execFileSync(
      "aws",
      [
        "ssm",
        "get-parameter",
        "--name",
        TOKEN_PARAMETER,
        "--with-decryption",
        "--query",
        "Parameter.Value",
        "--output",
        "text",
        "--profile",
        "aidb-personal",
        "--region",
        "us-east-1",
      ],
      { encoding: "utf8" },
    );
  } catch (error) {
    throw new Error(
      `could not read ${TOKEN_PARAMETER} from SSM (${error instanceof Error ? error.message : String(error)}). Set THUNDERSTORE_TOKEN instead, or refresh SSO.`,
    );
  }
}

async function postJson(
  path: string,
  token: string,
  body: unknown,
): Promise<unknown> {
  const response = await fetch(`${API}/${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  const text = await response.text();
  if (response.status < 200 || response.status >= 300) {
    throw new Error(`POST ${path} answered HTTP ${response.status}: ${text}`);
  }
  return text === "" ? null : JSON.parse(text);
}

async function main(): Promise<number> {
  const dryRun = process.argv.includes("--dry-run");
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const manifest = JSON.parse(
    readFileSync(join(root, "mods", "manifest.json"), "utf8"),
  ) as EstateManifest;

  const { namespace, name, version_number: version } = manifest.modpack;
  const archivePath = join(
    root,
    "mods",
    "modpack",
    "dist",
    `${name}-${version}.zip`,
  );
  if (!existsSync(archivePath)) {
    console.error(
      `No archive at ${archivePath}. Run scripts/modpack-build.mts first.`,
    );
    return 1;
  }

  // Ask whether THIS version already exists rather than whether it is the newest: the
  // listing's `latest` lags a fresh publish, so a newest-check misses a version that is
  // already there and the upload fails at submit with a 400 instead.
  const published = await checkDependencyExists(`${namespace}-${name}-${version}`);
  if (published.status === "present") {
    console.error(
      `${namespace}/${name} ${version} is already published. Bump modpack.version_number and rebuild.`,
    );
    return 1;
  }

  const archive = readFileSync(archivePath);
  console.log(
    `Publishing ${namespace}/${name} ${version} (${statSync(archivePath).size} bytes)`,
  );
  if (dryRun) {
    console.log("--dry-run: stopping before the first write. Nothing was uploaded.");
    return 0;
  }

  const token = resolveToken(process.env, readTokenFromParameterStore);

  const initiated = (await postJson("usermedia/initiate-upload/", token, {
    filename: basename(archivePath),
    file_size_bytes: archive.length,
  })) as { user_media: { uuid: string }; upload_urls: UploadPart[] };
  const uploadUuid = initiated.user_media.uuid;

  try {
    const completed: CompletedPart[] = [];
    for (const { part, body } of sliceParts(archive, initiated.upload_urls)) {
      const response = await fetch(part.url, {
        method: "PUT",
        body: new Uint8Array(body),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      if (!response.ok) {
        throw new Error(
          `part ${part.part_number} answered HTTP ${response.status}`,
        );
      }
      completed.push(
        requireEtag(part.part_number, response.headers.get("etag")),
      );
    }

    await postJson(`usermedia/${uploadUuid}/finish-upload/`, token, {
      parts: completed,
    });
    const submitted = await postJson(
      "submission/submit/",
      token,
      buildSubmissionMetadata(manifest, uploadUuid),
    );
    // Print what Thunderstore said. A 2xx here does not mean the version is live, and
    // discarding this response is what made the first failure unexplainable.
    console.log(`submit response: ${JSON.stringify(submitted)?.slice(0, 600)}`);
  } catch (error) {
    // Leaving a half-uploaded media behind would sit in the team's storage doing nothing.
    await postJson(`usermedia/${uploadUuid}/abort-upload/`, token, {}).catch(
      () => undefined,
    );
    console.error(
      `Publish failed and the upload was aborted: ${error instanceof Error ? error.message : String(error)}`,
    );
    return 1;
  }

  // Ask whether THIS VERSION exists, not whether it is the newest. The package listing's
  // `latest` field lags behind a fresh publish, so checking it reported a successful upload
  // as a failure (observed 2026-09-12, on the very first real run).
  const confirmed = await checkDependencyExists(
    `${namespace}-${name}-${version}`,
  );
  if (confirmed.status !== "present") {
    console.error(
      `Submitted, but Thunderstore does not yet report ${namespace}/${name} ${version} as present (${confirmed.status}: ${confirmed.detail}). Check the package page before telling anyone it shipped.`,
    );
    return 1;
  }

  console.log(
    `Published. https://thunderstore.io/c/${COMMUNITY}/p/${namespace}/${name}/`,
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
