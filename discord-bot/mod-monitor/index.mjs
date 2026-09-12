// ---------------------------------------------------------------------------
// Off-box watcher for the two mod drifts that nothing else can see.
//
// scripts/mods-verify.mts answers whether the BOX matches mods/manifest.json, but it
// needs the box running and a human to run it. Two other things drift silently:
//
//   1. A pinned mod ships a new version on Thunderstore. That is what starts an
//      upgrade, and nothing announces it.
//   2. The published client pack falls behind the manifest. That one is quiet and
//      mean: ValheimPlus runs enforceMod, so players keep the old pack until one of
//      them is kicked by a message that does not say why.
//
// The pins arrive as an env var that Terraform renders FROM mods/manifest.json, so the
// monitor cannot hold an opinion the committed manifest does not. Only the string
// comparison lives here; the manifest stays the single record.
//
// Deliberately ignores instance state. The box sleeps most of the time, and a mod that
// shipped while it slept still matters before the next start.
// ---------------------------------------------------------------------------

import {SSMClient, GetParameterCommand} from "@aws-sdk/client-ssm";

const REGION = process.env.AWS_REGION || "us-east-1";
const WEBHOOK_PARAM = process.env.WEBHOOK_PARAM;
const PINS_JSON = process.env.PINS_JSON || "[]";
const PACK_IDENTIFIER = process.env.PACK_IDENTIFIER || "";
const PACK_VERSION = process.env.PACK_VERSION || "";
const API = "https://thunderstore.io/api/experimental/package";
const REQUEST_TIMEOUT_MS = 10000;

const ssm = new SSMClient({region: REGION});

/**
 * Splits from the RIGHT: a Thunderstore team namespace may contain hyphens while a
 * package name may not, so `sinai-dev-UnityExplorer` is the team `sinai-dev`.
 */
export function splitIdentifier(identifier) {
  const parts = String(identifier).split("-");
  if (parts.length < 2) return null;
  const name = parts[parts.length - 1];
  const namespace = parts.slice(0, -1).join("-");
  if (!namespace || !name) return null;
  return {namespace, name};
}

/**
 * `unknown` is a third state on purpose. A lookup that failed says nothing about the
 * version, and collapsing it into "current" is how a monitor goes quiet while blind.
 */
export function classify(pinned, lookup) {
  if (lookup.error) return {state: "unknown", detail: lookup.error};
  if (lookup.latest === pinned) return {state: "current", detail: pinned};
  return {state: "behind", detail: lookup.latest};
}

export function describe(rows, pack) {
  const behind = rows.filter((row) => row.state === "behind");
  const unknown = rows.filter((row) => row.state === "unknown");
  const lines = [];

  if (behind.length > 0) {
    lines.push("**Mods behind Thunderstore**");
    for (const row of behind) {
      lines.push(`- \`${row.identifier}\` pinned ${row.pinned}, latest ${row.detail}`);
    }
  }
  if (pack.state === "behind") {
    lines.push(
      `**The published pack is stale.** \`${pack.identifier}\` has ${pack.detail} published, the manifest names ${pack.pinned}. Players are not running what the manifest says. Build and publish.`,
    );
  }
  if (pack.state === "unpublished") {
    lines.push(
      `**The pack has never been published.** \`${pack.identifier}\` ${pack.pinned} exists only in the manifest.`,
    );
  }
  if (unknown.length > 0 || pack.state === "unknown") {
    lines.push("**Could not be checked** (this is not an all-clear)");
    for (const row of unknown) {
      lines.push(`- \`${row.identifier}\`: ${row.detail}`);
    }
    if (pack.state === "unknown") {
      lines.push(`- \`${pack.identifier}\` (the pack): ${pack.detail}`);
    }
  }
  return lines.join("\n");
}

export function needsAlert(rows, pack) {
  return (
    rows.some((row) => row.state !== "current") || pack.state !== "current"
  );
}

async function latestVersion(identifier) {
  const split = splitIdentifier(identifier);
  if (!split) return {latest: null, error: `"${identifier}" is not Namespace-Name`};
  try {
    const response = await fetch(
      `${API}/${split.namespace}/${split.name}/`,
      {signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS), redirect: "manual"},
    );
    if (response.status === 404) return {latest: null, error: "HTTP 404"};
    if (response.status !== 200) {
      return {latest: null, error: `HTTP ${response.status}`};
    }
    const payload = await response.json();
    const latest = payload?.latest?.version_number;
    return typeof latest === "string" && latest
      ? {latest, error: null}
      : {latest: null, error: "the payload carried no latest version"};
  } catch (error) {
    return {latest: null, error: error?.message || String(error)};
  }
}

// Throws rather than logging, so a failed delivery surfaces as a Lambda error and the
// CloudWatch alarm on this function fires. A monitor that cannot reach Discord and says
// nothing is indistinguishable from a quiet estate.
async function notify(content) {
  if (!WEBHOOK_PARAM) {
    throw new Error(`WEBHOOK_PARAM not set: alert NOT delivered: ${content}`);
  }
  const parameter = await ssm.send(
    new GetParameterCommand({Name: WEBHOOK_PARAM, WithDecryption: true}),
  );
  const url = parameter?.Parameter?.Value;
  if (!url) {
    throw new Error(
      `no webhook configured at ${WEBHOOK_PARAM}: alert NOT delivered: ${content}`,
    );
  }
  const response = await fetch(url, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({content}),
  });
  if (!response.ok) {
    throw new Error(
      `webhook returned ${response.status} ${response.statusText}: alert NOT delivered`,
    );
  }
}

export const handler = async () => {
  const pins = JSON.parse(PINS_JSON);
  if (!Array.isArray(pins) || pins.length === 0) {
    // An empty pin list would check nothing and report a clean estate forever.
    throw new Error("PINS_JSON carried no pins; nothing was checked");
  }

  const rows = await Promise.all(
    pins.map(async (pin) => ({
      identifier: pin.identifier,
      pinned: pin.version,
      ...classify(pin.version, await latestVersion(pin.identifier)),
    })),
  );

  const packLookup = await latestVersion(PACK_IDENTIFIER);
  const packClassified =
    packLookup.error === "HTTP 404"
      ? {state: "unpublished", detail: "never published"}
      : classify(PACK_VERSION, packLookup);
  const pack = {
    identifier: PACK_IDENTIFIER,
    pinned: PACK_VERSION,
    ...packClassified,
  };

  if (!needsAlert(rows, pack)) {
    return {ok: true, checked: rows.length + 1, alerted: false};
  }

  await notify(
    `Valheim mod drift, checked ${rows.length + 1} packages\n${describe(rows, pack)}`,
  );
  return {ok: true, checked: rows.length + 1, alerted: true};
};
