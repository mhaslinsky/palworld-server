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
import { fetchLatestVersion } from "./mods-upstream.mts";

const API = "https://thunderstore.io/api/experimental";
const COMMUNITY = "valheim";
const CATEGORIES = ["modpacks"];
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
  has_nsfw_content: boolean;
  upload_uuid: string;
}

export function buildSubmissionMetadata(
  manifest: EstateManifest,
  uploadUuid: string,
): SubmissionMetadata {
  return {
    author_name: manifest.modpack.namespace,
    categories: CATEGORIES,
    communities: [COMMUNITY],
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

  // Thunderstore rejects a version it already holds, and finding that out here costs one
  // request instead of a failed upload.
  const published = await fetchLatestVersion(`${namespace}-${name}`);
  if (published.latest === version) {
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
    await postJson(
      "submission/submit/",
      token,
      buildSubmissionMetadata(manifest, uploadUuid),
    );
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

  // Ask Thunderstore what it actually holds. A 2xx on submit is not the same as the
  // version being live and resolvable for a player's mod manager.
  const confirmed = await fetchLatestVersion(`${namespace}-${name}`);
  if (confirmed.latest !== version) {
    console.error(
      `Submitted, but Thunderstore reports ${confirmed.latest ?? confirmed.error} as latest rather than ${version}. Check the package page before telling anyone it shipped.`,
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
