## Why

The friends on the server constantly ask Palworld lookup questions ("where do I get X ingot", "what does this Pal's passive do", "best base Pal for mining") and end up alt-tabbing to a wiki mid-session. A cheap Discord Q&A bot that can answer those — searching the live web only when it needs to — turns that into a one-line `/ask` in the same channel they already use to start the server. It is a small quality-of-life add, explicitly scoped to be *very* cheap to run.

## What Changes

- Add a new `/ask <question>` Discord slash command handled by the **existing** `discord-bot` Lambda, reusing its verify → allowlist → defer → async-worker pattern.
- Add a dedicated **ask-worker Lambda** (async-invoked by the entry handler) that runs a short LLM tool-use loop against **Amazon Bedrock (Claude Haiku 4.5)** and edits the deferred Discord reply with the answer.
- Give the model **one tool**: `parallel_search`, backed by the **Parallel AI fast Search API**, so it fetches current web results only when a question needs them (not on every call).
- Add a **per-user cooldown** (DynamoDB, TTL-based) enforced on the fast HTTP path before deferring, so a user cannot spam the model.
- Keep `/ask` **allowlist-gated** by the existing `ALLOWED_USER_IDS` — same audience as `/palworld-start`.
- Store the Parallel API key as an **SSM SecureString**; grant Bedrock/DynamoDB/SSM access via new least-privilege IAM.
- Register the new command with Discord (one-time `applications/commands` upsert).

Non-goals: no game-server integration (the bot never touches the Palworld box or its REST API), no conversation memory across invocations, no LiteLLM-style multi-model complexity router (single cheap model is sufficient at this scale — revisit only if answer quality demands it).

## Capabilities

### New Capabilities
- `discord-qa-bot`: An allowlist-gated, cooldown-limited Discord `/ask` command that answers Palworld questions with a cheap Bedrock LLM which may call a Parallel AI web-search tool, delivered through the existing Discord interactions endpoint.

### Modified Capabilities
<!-- None. openspec/specs/ is empty; the existing /palworld-start and /palworld-status commands have no spec file, and their behavior is unchanged. -->

## Impact

- **Code**: `discord-bot/src/index.mjs` (route `/ask`, cooldown check, invoke ask-worker); new `discord-bot/ask-worker/index.mjs` (Bedrock loop + `parallel_search` tool); command-registration script/doc.
- **Infra (Terraform)**: new `discord_ask.tf` (ask-worker Lambda, DynamoDB cooldown table, IAM, log group); edits to `discord.tf` (env vars for the entry handler: ask-worker name, cooldown table, cooldown seconds; IAM to invoke ask-worker + DynamoDB read/write); new `aws_ssm_parameter` for the Parallel API key (SecureString, `ignore_changes = [value]`).
- **Dependencies**: `@aws-sdk/client-bedrock-runtime` and `@aws-sdk/client-dynamodb` — both already present in the `nodejs22.x` runtime, so still zero `npm install`. Parallel Search is a plain HTTPS call via `fetch`.
- **External**: requires Bedrock model access for Claude Haiku 4.5 enabled in the account/region, and a Parallel AI API key. Adds outbound egress from the ask-worker to `api.parallel.ai`.
- **Cost**: pay-per-use only — Bedrock per-token + Parallel per-search + trivial DynamoDB on-demand; ~$0 when idle. No persistent inference endpoint (SageMaker was explicitly rejected for this reason).

## Follow-ups (deferred — not built in this change)

1. **Extended thinking on `/ask`.** Haiku 4.5 is an older-generation model for this API:
   it does NOT accept `adaptive` thinking or the `effort` dial (4.6+ only), so enabling
   reasoning means the explicit form `thinking: {type: "enabled", budget_tokens: N}`,
   where `N >= 1024` **and** `N < max_tokens`. Blocking detail: `ask_max_tokens` is
   currently **700**, below the 1024 floor — so this is not a one-line flag. It requires
   raising `max_tokens` to ~3000+ (budget 1024–2048 plus room for the answer), which
   raises per-question cost (thinking tokens bill as output) and latency against the
   worker's 60s Lambda budget.
   **Deferred because** the current question shape is lookup-style ("where is quartz",
   "best mining Pal") where `parallel_search` does the work and reasoning depth adds
   little. **Revisit when** `/ask` is wanted for genuinely multi-step questions (base
   layout planning, comparing breeding paths). The timeout watchdog already covers the
   added latency risk.

2. **Lambda on-failure destination.** Closes the documented residual in the
   `discord-qa-bot` spec: an abrupt process kill (OOM / runtime fault) leaves the
   deferred message un-edited, because no in-process handler can run. The timeout case
   is already covered by the watchdog; this would cover the rest via an SNS/Lambda
   destination that PATCHes using the interaction token from the failed event.

3. **S3 knowledge corpus / bot memory — CONSIDERED AND DECLINED (2026-07-22).**
   Idea: an S3 bucket of markdown the bot reads (server-specific facts web search cannot
   know — the UE4SS mod, decay-off, raised base cap, house rules) and possibly writes.
   Grok and Codex were consulted independently and **agreed** on: no model write path
   (prompt text is not a security boundary — the model reads untrusted search results, so
   a write tool turns one poisoned result into durable poisoned state); no Q&A answer cache
   (it freezes wrongness and fights the search-first prompt); and no embeddings/vector
   store/manifest. They **split** on the read path — Grok: inject into the system prompt
   (fail-closed; a tool the model may skip is wrong for must-know facts). Codex: a bounded
   read tool (below Haiku's 4096-token cache floor an inlined corpus bills on every turn).
   **Declined anyway**, on a ground neither weighed: the owner will not maintain the file.
   An unmaintained corpus decays into confidently-wrong server facts stated with the same
   authority as searched ones — worse than having none. **Revisit only** if someone commits
   to ownership, or if a safe write path removes the maintenance burden (Codex's minimum:
   owner-only `/remember` writing verbatim to `corpus/pending/`, worker cannot read
   `pending/`, writer cannot write `trusted/`, S3 versioning + read-back verification).
