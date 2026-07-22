## 1. Prerequisites (out-of-band, verify before coding)

- [x] 1.1 Enable Amazon Bedrock model access for Claude Haiku 4.5; confirm with a red/green invoke from the CLI using the EXACT id the Lambda will use — likely the cross-region inference profile `us.anthropic.claude-haiku-4-5-*`, NOT the bare foundation-model id (bare id → ValidationException; IAM scoped only to the foundation-model ARN → AccessDenied). Record the exact id + ARN(s) for IAM.
- [x] 1.4 Verify the `nodejs22.x`-bundled `@aws-sdk/client-bedrock-runtime` exposes `Converse` with tool support; if not, plan to use raw `InvokeModel` with an Anthropic messages body (both keep zero npm install).
- [x] 1.2 Confirm the current Parallel AI fast Search API surface against live docs: endpoint URL, auth header, request body, response shape, and the exact "fast/turbo" tier + rate limits. Do NOT code from memory.
- [x] 1.3 Obtain a Parallel AI API key for the bot.

> **Bedrock access note (2026-07-22):** invocation is gated behind an account-level
> Anthropic **use-case form**, submitted via the Bedrock console (chat playground or
> Model access). Enforcement began mid-build, which is why an early red/green invoke
> succeeded and later ones failed. `get-foundation-model-availability` reports
> `AUTHORIZED` even while every invoke fails — do NOT use it as a readiness check;
> use `bedrock get-use-case-for-model-access` (errors until the form is on file) plus
> a real `invoke-model`. The form record replicates to all regions immediately, but
> entitlement propagates per-region: us-east-1 (the deploy region) cleared in ~1 min
> while us-east-2/us-west-2 lagged.

## 2. Secret + cooldown infrastructure (Terraform)

- [x] 2.1 Add `aws_ssm_parameter` for the Parallel API key as a `SecureString` with `lifecycle { ignore_changes = [value] }` (mirror `discord_bot_token`); set the value out-of-band.
- [x] 2.2 Add a DynamoDB table (on-demand billing) keyed by Discord user id for cooldown, with a TTL attribute enabled for self-cleanup.
- [x] 2.3 Add Terraform variables: `ask_cooldown_seconds` (default 60), `ask_max_tokens`, `ask_max_tool_turns`, and the Bedrock model id.

## 3. Ask-worker Lambda (Terraform)

- [x] 3.1 Create `discord_ask.tf`: ask-worker `aws_lambda_function` (nodejs22.x, arm64), its CloudWatch log group (with a retention_in_days), IAM role, and a timeout sized to cover the bounded tool loop with margin (well under Discord's 15-min edit window). Give the worker NO Function URL.
- [x] 3.2 IAM for the ask-worker role (least privilege): `bedrock:InvokeModel` scoped to the inference-profile ARN AND the underlying regional model ARNs (from task 1.1), plus `ssm:GetParameter` + `kms:Decrypt` for the Parallel key. NO DynamoDB — the worker never touches the cooldown table; the entry handler owns the claim.
- [x] 3.3 Add `aws_lambda_function_event_invoke_config` for the worker with `maximum_retry_attempts = 0` (async is at-least-once; a retry would double-spend Bedrock/Parallel and may 404 after the token window).
- [x] 3.4 Wire the ask-worker's env vars: model id, Parallel key param name, max output tokens, max tool turns, max searches, max search-result bytes, `DISCORD_APP_ID`.

## 4. Ask-worker Lambda (code)

- [x] 4.1 Create `discord-bot/ask-worker/index.mjs` with a `handler` that receives `{ question, interactionToken }` from the async invoke.
- [x] 4.2 Implement the Bedrock Haiku tool-use loop: system prompt scoped to Palworld Q&A that prefers a single search and treats search-result text as untrusted data (never instructions); one `parallel_search` tool declaration; enforce max turns (≤3), max searches (≤2), and max output tokens. On loop-bound exhaustion, force a final no-tool answer or return the canned "couldn't answer" string — do not post a bare tool-result.
- [x] 4.3 Implement `parallel_search(query)` as a `fetch` to the Parallel API with an AbortController timeout (~8s), using the SSM key (read once at runtime, never logged); truncate results to the max-bytes cap before returning to the model; fail soft — report tool unavailability to the model rather than throwing.
- [x] 4.4 Edit the deferred message via the interaction token; truncate to Discord's 2000-char limit at a line/sentence boundary; set `allowed_mentions` to none so `@everyone`/`@here`/role pings in the answer never fire.
- [x] 4.5 Wrap the whole worker in a top-level catch-all that PATCHes a clear error and logs the cause; ensure NO throw occurs after a successful PATCH (so a Lambda retry cannot re-run paid work). Never `console.log` the raw event (it carries the interaction-token bearer credential).

## 5. Entry handler routing + cooldown (code)

- [x] 5.1 In `discord-bot/src/index.mjs`, add `/ask` to the accepted-command set, read the question option, and reject a question over the max-length cap with an ephemeral message before any further work.
- [x] 5.2 Enforce allowlist for `/ask` (reuse `ALLOWED_USER_IDS`), returning ephemeral refusal for non-members before any further work.
- [x] 5.3 Add the cooldown check: atomic DynamoDB conditional write (`attribute_not_exists(pk) OR last_ts < :threshold`, with a TTL attribute) on the HTTP path BEFORE deferring; on within-window, reply ephemerally with remaining wait and stop; **fail closed** on a DynamoDB error (deny, do not allow uncooled call).
- [x] 5.4 On accept, `await` the async-invoke of the ask-worker with `{ question, interactionToken }` BEFORE returning the deferred (type-5) response — returning first can drop the in-flight invoke when the environment freezes.
- [x] 5.5 Wrap the defer+invoke in a try/catch: if the invoke fails after we've decided to defer, PATCH the original message with an error via the interaction token so the user never sees a permanent "thinking…".
- [x] 5.6 Update `discord.tf`: add entry-handler env vars (ask-worker function name, cooldown table, cooldown seconds, max question length) and IAM (`lambda:InvokeFunction` on the ask-worker + DynamoDB read/write on the cooldown table). The entry role — not the worker — owns DynamoDB.

## 6. Command registration

- [x] 6.1 Register the `/ask` slash command (with a required `question` string option) via a one-time `applications/commands` upsert; document the command in `discord-bot/README.md`.

## 7. Tests + verification

- [x] 7.1 Unit-test the entry-handler cooldown logic (accept, within-window reject, store-error fail-closed) and allowlist gating, matching the existing `discord-bot/tests` style.
- [x] 7.2 Unit-test the ask-worker loop: no-search answer path, search-backed path, loop-bound stop (forced final answer, not a bare tool-result), Parallel timeout/failure fail-soft, mass-mention neutralization, and degradation messages (mock Bedrock + Parallel).
- [x] 7.3 Make guards fail on purpose (per repo rule 7): confirm the cooldown actually blocks a second call; a forged signature still 401s with the new command present; a simulated post-defer invoke failure produces a visible error edit (not a stuck "thinking…"); and an answer containing `@everyone` pings nobody.
- [ ] 7.4 End-to-end from an allowlisted Discord account: a knowledge-only answer, a search-backed answer, a cooldown rejection, and a forced-error path.

## 8. Ship

- [ ] 8.1 `git status` + read the full `terraform plan` (quote `Plan:` and any replace/destroy lines); confirm the plan touches only the new/edited Lambda + DynamoDB + IAM + SSM and does NOT replace the game instance. Apply per repo rules (no `-auto-approve`).
- [ ] 8.2 Open a PR; run it through the review loop; update the deferred-idea memory ([[palworld-discord-llm-qa-bot-idea]]) to "shipped" when merged.
