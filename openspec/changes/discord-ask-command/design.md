## Context

The Palworld Discord already has a working bot: a single `nodejs22.x` Lambda behind a public Function URL (`discord.tf` / `discord-bot/src/index.mjs`) that handles `/palworld-start` and `/palworld-status`. Its shape is the whole reason this feature is cheap to add:

- **HTTP path** — verify the Ed25519 signature, check the timestamp skew, check `ALLOWED_USER_IDS`, then return a *deferred* response and async self-invoke a worker. This path must finish inside Discord's hard 3-second ACK deadline, so it does no slow work.
- **Worker path** — the async invocation does the slow thing (today: `StartInstances`) and PATCHes the original message via the interaction token, which Discord keeps editable for 15 minutes.

A Q&A command fits this exactly: verify → gate → defer → let a worker think and edit the answer in. The only genuinely new pieces are the model call, a web-search tool, and a cooldown store. The project's governing constraint is cost — the game server itself sleeps when idle — so the design rejects anything with a standing idle bill.

## Goals / Non-Goals

**Goals:**
- Add `/ask <question>` for allowlisted users, answered by a cheap LLM that can search the web when needed.
- Keep idle cost at ~$0 (pay-per-use only).
- Reuse the existing verify/defer/worker pattern rather than inventing a new intake.
- Fail honestly: a broken dependency produces a visible error, never a silent non-answer or a bypassed cooldown.

**Non-Goals:**
- No integration with the game server or its localhost REST API — the bot is pure Q&A.
- No conversation memory / multi-turn context across invocations.
- No LiteLLM-style multi-model complexity router (the Firebird pattern). A single cheap model with an optional tool is enough here; routing is revisitable later if answer quality demands it.
- No public (non-allowlisted) access in this change.

## Decisions

### Bedrock Claude Haiku 4.5, not SageMaker
Pay-per-token, zero idle cost, native IAM (`bedrock:InvokeModel`), strong tool-use, in-account. **Alternatives:** SageMaker real-time endpoint — rejected: a persistent instance bills 24/7 (~$50+/mo) and contradicts the everything-sleeps design; only justified for self-hosting a specific open-weights model, which is not a requirement. Anthropic API direct — viable and same cost profile, but adds an API key to store/rotate and out-of-account egress for the core model call; Bedrock avoids both. **Prerequisite:** Haiku 4.5 model access must be enabled in the account/region — a console/one-time step, called out in tasks.

### Separate ask-worker Lambda, one shared entry point
Discord sends every interaction to a single configured endpoint, so the existing entry Lambda stays the sole HTTP handler and router. It async-invokes a **dedicated ask-worker Lambda** for `/ask` (rather than self-invoking as `/palworld-start` does). **Why separate — the honest reason is independent timeout and config, not blast radius:** the worker needs a much longer timeout for the bounded model+search loop, and forcing that onto the public-URL function (which must answer in <3s) is wrong; a distinct function also gets its own event-invoke retry config (see the retry decision below). The IAM-isolation argument is weaker than it looks — the entry role still grows DynamoDB writes plus `lambda:InvokeFunction`, so this is not a clean separation of privilege. **Alternative:** one Lambda handling everything — simpler infra, but it couples the public-facing function's timeout and retry policy to the slow LLM path. Lambda has no idle cost, so the second function is effectively free; keep it for the config isolation.

### Async handoff is at-least-once, and every outcome must edit the message
Lambda async (`InvocationType: Event`) retries a failed invocation up to 2 more times by default. Without care this double-spends Bedrock + Parallel and can fire an edit after the 15-minute interaction-token window (a 404). So: set `aws_lambda_function_event_invoke_config { maximum_retry_attempts = 0 }` on the worker, and the worker must **never throw after it has PATCHed the message** (side effects first, then a clean return). Separately, the *entry* handler owns the "invoke failed after we already deferred" path — it must catch that and PATCH an error itself, because otherwise the user is stuck on a permanent "thinking…". The worker also needs a top-level catch-all for a crash/timeout before its own error handling. This is the single most important correctness cluster in the change — an independent Grok + Kimi review both ranked it #1. The spec's language is "at-least-once with an always-owned outcome," not "exactly once."

### Bedrock invocation: inference profile, and verify the bundled SDK
Claude Haiku 4.5 in most regions is invocable only through a **cross-region inference profile** id (`us.anthropic.claude-haiku-4-5-*`), not the bare foundation-model id. Two failure modes to avoid: IAM scoped only to the foundation-model ARN → `AccessDenied`; a bare model id in the request body → `ValidationException`. The task-1.1 red/green MUST use the exact id the Lambda will use, and IAM MUST cover the inference-profile ARN plus the underlying regional model ARNs. Also **verify at build time** that the `nodejs22.x`-bundled `@aws-sdk/client-bedrock-runtime` exposes `Converse` with tool support before banking the zero-npm posture; the fallback is raw `InvokeModel` with an Anthropic messages body (still zero-install).

### Cooldown in DynamoDB, claimed on the HTTP path
A single on-demand DynamoDB table keyed by Discord user id, holding the last-accepted epoch with a TTL attribute for self-cleanup. The entry handler does a **conditional write** (accept only if no record within the window) *before* deferring, so the limit is claimed atomically and a rejected call never reaches the model. **Alternatives:** in-memory per-container state — rejected: unreliable across cold starts and concurrent executions, trivially bypassed. SSM parameter — rejected: not built for per-key rate-limit writes, no TTL. DynamoDB on-demand at this volume is effectively free.

**Fail-closed** on a cooldown store error (spec requirement): a DynamoDB outage denies the request rather than allowing an uncooled model call — the cost/abuse limit must not be bypassable by degrading its store. This is the deliberate exception to "degrade, don't crash": the guarded resource is spend, and the user still gets an explicit ephemeral error, not silence.

### `parallel_search` as the model's only tool
The worker exposes one Bedrock tool, `parallel_search(query)`, implemented as a plain HTTPS `fetch` to the Parallel AI fast Search API with the key from SSM. The **model decides** whether to call it, so simple questions cost one Haiku turn and no search, satisfying the memory's "avoid always-LLM + always-search" cost note. The tool-use loop is bounded (small max turns, bounded `max_tokens`) so a pathological question can't loop or run long. **Build-time confirmation:** the exact Parallel Search tier, endpoint, auth header, and request/response shape must be verified against current Parallel docs at implementation time (the memory flags this explicitly) — do not code them from memory.

### Zero new npm dependencies
`@aws-sdk/client-bedrock-runtime` and `@aws-sdk/client-dynamodb` ship in the `nodejs22.x` runtime; Parallel is a `fetch` call. So the build stays install-free, matching the existing bot's zero-dependency posture.

## Risks / Trade-offs

- **Async retry storm double-spends** → `maximum_retry_attempts = 0` + no-throw-after-PATCH (see decision above). This is the top cost *and* correctness risk.
- **Permanent "thinking…"** (invoke fails post-defer, or worker crashes/times out) → entry-handler catch that PATCHes an error + worker top-level catch-all; worker timeout sized under the 15-min edit window.
- **Token amplification from search results** → tool results are re-billed on every subsequent model turn, so cap result bytes fed back, cap searches (≤2) and turns (≤3), and cap the question length. Tight defaults ship in Terraform vars, not "tune later."
- **Prompt injection via a user question or a search result** → allowlist bounds *who*; system prompt scopes to Palworld and treats search text as untrusted data; blast radius is contained (one tool, bounded turns, no memory, no game-server access). Residual risk is a few wasted turns / a junk answer — acceptable.
- **Answer pings the whole server** → neutralize `@everyone`/`@here`/role mentions via `allowed_mentions: none` before the edit. Cheap, mandatory.
- **Hung Parallel search burns the Lambda timeout** → AbortController (~8s) on the `fetch`.
- **Runaway LLM/search spend** → cooldown claimed pre-defer + bounded turns + bounded output + allowlist-only. The existing `EstimatedCharges` billing alarm remains the coarse backstop (slow; not a substitute for the bounds above).
- **Bedrock model access not enabled** → the first `/ask` errors clearly; tasks include enabling access and a red/green check before wiring the command live.
- **Parallel API shape assumed wrong** → mitigated by the build-time-confirmation decision above; the tool fails soft (model answers without it) rather than crashing the worker.
- **Latency: Haiku + a search round-trip may exceed a few seconds** → acceptable because the interaction is deferred (15-min edit window); worker timeout sized to cover the bounded loop with margin, well under Discord's edit window.
- **Secret leakage** → key only in SSM SecureString, read at runtime, never logged; Terraform uses `ignore_changes = [value]` on the parameter (mirrors `discord_bot_token`).
- **Cost of the second Lambda** → negligible; Lambda has no idle cost and this reduces risk on the public-facing function.

## Migration Plan

1. Enable Bedrock Haiku 4.5 model access in the account/region; verify with a direct `InvokeModel` red/green.
2. Create the Parallel API key SSM SecureString (value set out-of-band, like the bot token).
3. Apply Terraform for the ask-worker Lambda, DynamoDB table, IAM, and entry-handler env/IAM additions. Note: editing `discord-bot/src/index.mjs` changes the entry Lambda's code hash (a normal function update, **not** an EC2-style replacement — this is Lambda, not `user_data`).
4. Register the `/ask` command with Discord (one-time upsert).
5. Test end-to-end with an allowlisted account; confirm cooldown, a no-search answer, and a search-backed answer.
6. **Rollback:** deregister `/ask` and/or revert the code+Terraform. No game-server or world impact is possible since the bot never touches the box.

## Open Questions

- Cooldown length and answer `max_tokens` / max tool turns — pick sensible defaults (e.g. 60s cooldown) as Terraform variables; tune after real use.
- Whether to also surface live server status (roster) into answers — deferred; keep the bot decoupled from the game box for now.
