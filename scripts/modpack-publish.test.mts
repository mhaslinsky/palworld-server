#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  buildSubmissionMetadata,
  requireEtag,
  resolveToken,
  sliceParts,
  type UploadPart,
} from "./modpack-publish.mts";
import type { EstateManifest } from "./modpack.mts";

function manifest(): EstateManifest {
  return {
    world: "Utgarde",
    game_version: "1.0.12",
    network_version: 40,
    modpack: {
      namespace: "valheimsquad",
      name: "Utgarde_Client_Pack",
      version_number: "1.0.0",
      website_url: "",
      description: "d",
    },
    verified: {},
    mods: [],
  };
}

function part(overrides: Partial<UploadPart> = {}): UploadPart {
  return {
    part_number: 1,
    url: "https://example.invalid/part-1",
    offset: 0,
    length: 4,
    ...overrides,
  };
}

test("the submission names the team as author and the Valheim community", () => {
  const metadata = buildSubmissionMetadata(manifest(), "abc-123");
  assert.equal(metadata.author_name, "valheimsquad");
  assert.deepEqual(metadata.communities, ["valheim"]);
  assert.deepEqual(metadata.categories, ["modpacks"]);
  assert.equal(metadata.has_nsfw_content, false);
  assert.equal(metadata.upload_uuid, "abc-123");
});

test("parts are sliced at the offsets Thunderstore asked for", () => {
  const archive = Buffer.from("abcdefgh");
  const sliced = sliceParts(archive, [
    part({ part_number: 1, offset: 0, length: 4 }),
    part({ part_number: 2, offset: 4, length: 4 }),
  ]);
  assert.equal(sliced[0].body.toString(), "abcd");
  assert.equal(sliced[1].body.toString(), "efgh");
});

test("a part running past the end of the file is refused, not truncated", () => {
  // Silently uploading the short remainder would produce an archive Thunderstore accepts
  // and no player can install.
  assert.throws(
    () => sliceParts(Buffer.alloc(8), [part({ offset: 4, length: 99 })]),
    /covers bytes 4-103 of a 8 byte file/,
  );
});

test("a negative offset is refused", () => {
  assert.throws(
    () => sliceParts(Buffer.alloc(8), [part({ offset: -1, length: 2 })]),
    /covers bytes -1-1/,
  );
});

test("an empty upload plan is refused rather than publishing nothing", () => {
  assert.throws(() => sliceParts(Buffer.alloc(8), []), /no upload URLs/);
});

test("a part that returns no ETag is refused", () => {
  // S3 answers 200 without an ETag when it has not stored the part.
  assert.throws(() => requireEtag(2, null), /part 2 was uploaded but returned no ETag/);
  assert.throws(() => requireEtag(2, ""), /no ETag/);
  assert.deepEqual(requireEtag(2, '"deadbeef"'), {
    ETag: '"deadbeef"',
    PartNumber: 2,
  });
});

test("the environment token wins and the parameter store is not consulted", () => {
  let consulted = false;
  const token = resolveToken({ THUNDERSTORE_TOKEN: "  tss_from_env  " }, () => {
    consulted = true;
    return "tss_from_ssm";
  });
  assert.equal(token, "tss_from_env");
  assert.equal(consulted, false);
});

test("an empty environment token falls through to the parameter store", () => {
  assert.equal(
    resolveToken({ THUNDERSTORE_TOKEN: "   " }, () => "tss_from_ssm\n"),
    "tss_from_ssm",
  );
  assert.equal(resolveToken({}, () => "tss_from_ssm"), "tss_from_ssm");
});

test("no token anywhere is a loud failure, never an empty-string publish attempt", () => {
  assert.throws(
    () => resolveToken({}, () => "   "),
    /no Thunderstore token/,
  );
});
