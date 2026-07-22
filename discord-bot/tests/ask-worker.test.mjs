// Red/green harness for the ask-worker (discord-bot/ask-worker).
//
//   cd discord-bot && npm install && npm test
//
// Guards to watch fire: the model can answer WITHOUT searching; a search-backed
// answer runs exactly one search; a model that loops forever is STOPPED at the turn
// bound and still posts prose (never a bare tool-result); a failed search degrades
// (the answer still lands); the outbound edit neutralizes mass mentions; a Bedrock
// failure produces a visible error edit WITHOUT the handler throwing (a throw would
// let Lambda retry re-run the paid loop).

import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { SSMClient } from "@aws-sdk/client-ssm";

process.env.MODEL_ID = "us.anthropic.claude-haiku-4-5-test";
process.env.DISCORD_APP_ID = "app-test";
process.env.PARALLEL_KEY_PARAM = "/palworld-server/parallel_api_key";
process.env.ASK_MAX_TOOL_TURNS = "3";
process.env.ASK_MAX_SEARCHES = "2";
process.env.ASK_MAX_TOKENS = "700";
process.env.ASK_MAX_RESULT_BYTES = "6000";
process.env.ASK_PARALLEL_TIMEOUT_MS = "8000";

// --- controllable backends --------------------------------------------------------
let bedrockReplies = []; // consumed in order per invoke
let bedrockError = false;
let parallelMode = "ok"; // "ok" | "fail" | "throw" | "nokey"
let searchCalls = 0;
let edits = []; // { content, body } captured from the Discord PATCH

const encode = (object) => ({ body: new TextEncoder().encode(JSON.stringify(object)) });

let bedrockHangs = false;

BedrockRuntimeClient.prototype.send = async () => {
  if (bedrockHangs) return new Promise(() => {}); // never settles — simulates a slow model
  if (bedrockError) throw new Error("Bedrock unavailable");
  const next = bedrockReplies.shift();
  if (!next) throw new Error("test error: ran out of scripted Bedrock replies");
  return encode(next);
};

SSMClient.prototype.send = async () => ({
  Parameter: { Value: parallelMode === "nokey" ? "None" : "secret-key" },
});

global.fetch = async (url, options) => {
  if (String(url).includes("parallel.ai")) {
    searchCalls++;
    if (parallelMode === "throw") throw new Error("network down");
    if (parallelMode === "fail") return { ok: false, status: 500, statusText: "err", text: async () => "err" };
    return {
      ok: true,
      status: 200,
      json: async () => ({ results: [{ title: "Palwiki", url: "https://x", excerpts: ["Quartz is in the desert."] }] }),
    };
  }
  // Discord edit
  edits.push({ body: JSON.parse(options.body), content: JSON.parse(options.body).content });
  return { ok: true, status: 200, text: async () => "" };
};

// Reset module state per scenario via a query-string specifier (fresh module + caches).
let moduleCounter = 0;
async function freshHandler() {
  return (await import(`../ask-worker/index.mjs?run=${moduleCounter++}`)).handler;
}

const text = (value) => ({ stop_reason: "end_turn", content: [{ type: "text", text: value }] });
const toolUse = (query) => ({
  stop_reason: "tool_use",
  content: [{ type: "tool_use", id: "tool-1", name: "parallel_search", input: { query } }],
});

let failures = 0;
function check(name, condition, detail = "") {
  if (condition) console.log(`PASS  ${name}`);
  else { console.log(`FAIL  ${name}  ${detail}`); failures++; }
}
function reset({ replies, error = false, parallel = "ok", hangs = false }) {
  bedrockReplies = replies;
  bedrockError = error;
  bedrockHangs = hangs;
  parallelMode = parallel;
  searchCalls = 0;
  edits = [];
}

console.log("--- GREEN: answer without searching ---");
{
  reset({ replies: [text("Grizzbolt is a solid early pick.")] });
  const handler = await freshHandler();
  await handler({ question: "good starter pal?", interactionToken: "tok" });
  check("no search performed", searchCalls === 0, `searchCalls=${searchCalls}`);
  check("answer edited into the message", edits.length === 1 && edits[0].content.includes("Grizzbolt"));
}

console.log("\n--- GREEN: search-backed answer runs exactly one search ---");
{
  reset({ replies: [toolUse("Palworld quartz location"), text("Pure quartz spawns in the desert biome.")] });
  const handler = await freshHandler();
  await handler({ question: "where is quartz?", interactionToken: "tok" });
  check("exactly one search", searchCalls === 1, `searchCalls=${searchCalls}`);
  check("final answer edited (not a tool result)", edits.length === 1 && edits[0].content.includes("desert"));
}

console.log("\n--- RED: a runaway tool-loop is STOPPED at the turn bound and still posts prose ---");
{
  // Model asks to search every turn. After MAX_TOOL_TURNS the worker forces a final
  // no-tool call. Provide 3 tool_use turns + 1 forced text answer.
  reset({ replies: [toolUse("q1"), toolUse("q2"), toolUse("q3"), text("Here is my best answer.")] });
  const handler = await freshHandler();
  await handler({ question: "loop please", interactionToken: "tok" });
  check("searches capped at MAX_SEARCHES(2)", searchCalls === 2, `searchCalls=${searchCalls}`);
  check("still posted a prose answer", edits.length === 1 && edits[0].content.includes("best answer"));
}

console.log("\n--- RED: a failed search degrades — the answer still lands ---");
{
  reset({ replies: [toolUse("q"), text("Answering without the web then.")], parallel: "throw" });
  const handler = await freshHandler();
  await handler({ question: "with broken search", interactionToken: "tok" });
  check("search attempted", searchCalls === 1);
  check("answer still delivered", edits.length === 1 && edits[0].content.includes("without the web"));
}

console.log("\n--- RED: the outbound edit must neutralize mass mentions ---");
{
  reset({ replies: [text("@everyone the server is up!")] });
  const handler = await freshHandler();
  await handler({ question: "announce", interactionToken: "tok" });
  const mentions = edits[0]?.body?.allowed_mentions;
  check("allowed_mentions parse:[] present", mentions && Array.isArray(mentions.parse) && mentions.parse.length === 0, JSON.stringify(mentions));
}

console.log("\n--- RED: a Bedrock failure edits a visible error and does NOT throw ---");
{
  reset({ replies: [], error: true });
  const handler = await freshHandler();
  let threw = false;
  try {
    await handler({ question: "boom", interactionToken: "tok" });
  } catch {
    threw = true; // a throw would let Lambda async-retry re-run the paid loop
  }
  check("handler did not throw", threw === false);
  check("a visible error was edited in", edits.length === 1 && edits[0].content.includes("❌"));
}

console.log("\n--- RED: a Lambda TIMEOUT still edits the message (no permanent 'thinking…') ---");
{
  // The model never responds. Without the deadline watchdog the runtime would kill
  // the process with no edit at all — the exact failure four review seats flagged.
  reset({ replies: [], hangs: true });
  const handler = await freshHandler();
  // Lambda-style context: 5.6s left, so the watchdog fires ~600ms in (reserve 5000).
  const context = { getRemainingTimeInMillis: () => 5_600 };
  let threw = false;
  const started = Date.now();
  try {
    await handler({ question: "hang forever", interactionToken: "tok" }, context);
  } catch {
    threw = true;
  }
  const elapsed = Date.now() - started;
  check("handler did not throw on timeout", threw === false);
  check("abandoned BEFORE the runtime would kill it", elapsed < 5_000, `elapsed=${elapsed}ms`);
  check("a timeout message was edited in", edits.length === 1 && edits[0].content.includes("⏱️"), JSON.stringify(edits[0]?.content));
}

console.log("\n--- GREEN: a missing interaction token is a no-op, not a crash ---");
{
  reset({ replies: [] });
  const handler = await freshHandler();
  let threw = false;
  try { await handler({ question: "orphan" }); } catch { threw = true; }
  check("no token -> no edit, no throw", threw === false && edits.length === 0);
}

console.log(`\n${failures === 0 ? "ALL PASS" : failures + " FAILURE(S)"}`);
process.exit(failures === 0 ? 0 : 1);
