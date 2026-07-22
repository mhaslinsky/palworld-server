## ADDED Requirements

### Requirement: Signature-verified command intake
The `/ask` command SHALL be accepted only through the existing Discord interactions endpoint and SHALL be subject to the same Ed25519 signature verification and timestamp-skew check as every other command, before any allowlist, cooldown, or model work occurs.

#### Scenario: Forged or unsigned request
- **WHEN** a request arrives whose `x-signature-ed25519` fails verification against the app public key, or whose timestamp skew exceeds the allowed window
- **THEN** the handler returns HTTP 401 and performs no allowlist lookup, no cooldown write, no model call

#### Scenario: Discord PING probe still answered
- **WHEN** Discord sends its `PING` verification probe to the endpoint
- **THEN** the handler responds with `PONG` exactly as before, unaffected by the new command

### Requirement: Allowlist gating
The `/ask` command SHALL be usable only by callers whose Discord user id is in `ALLOWED_USER_IDS`, the same allowlist that gates `/palworld-start`.

#### Scenario: Non-allowlisted caller
- **WHEN** a user not in `ALLOWED_USER_IDS` invokes `/ask`
- **THEN** the handler replies with an ephemeral refusal and does not consume cooldown, call the model, or invoke the ask-worker

### Requirement: Per-user cooldown
The system SHALL enforce a per-user cooldown of a configurable number of seconds between accepted `/ask` invocations. The cooldown SHALL be checked and claimed atomically on the fast HTTP path, before the interaction is deferred, so that a rejected request never triggers a model call.

#### Scenario: Within cooldown window
- **WHEN** an allowlisted user invokes `/ask` and their last accepted `/ask` was fewer than the cooldown seconds ago
- **THEN** the handler replies with an ephemeral message stating the remaining wait, and does not defer or invoke the ask-worker

#### Scenario: Cooldown elapsed
- **WHEN** an allowlisted user invokes `/ask` and no accepted `/ask` exists within the cooldown window
- **THEN** the handler atomically records the new timestamp, awaits the async invoke of the ask-worker, and only then returns the deferred acknowledgement (returning before the invoke resolves risks the frozen Lambda environment dropping the in-flight call)

#### Scenario: Cooldown consumed when the answer fails after dispatch
- **WHEN** a request is accepted (cooldown claimed), the ask-worker IS dispatched, but the answer never lands (worker crash, model error, timeout)
- **THEN** the cooldown remains consumed for the window — this is intentional so a failing downstream dependency cannot be used to bypass the rate limit; the failure surfaces as a visible error message (see honest-degradation), and the user waits out the window

#### Scenario: Cooldown released when dispatch itself fails
- **WHEN** the cooldown was claimed but the worker invoke fails before dispatch (so no model/search work runs and nothing is spent)
- **THEN** the handler best-effort releases the claim so the user is not penalized for an infrastructure hiccup they did not cause; releasing here opens no bypass, because a repeatedly-failing invoke runs no worker and spends nothing

#### Scenario: Cooldown store unreachable
- **WHEN** the cooldown store cannot be read or written
- **THEN** the handler denies the request with an ephemeral error rather than allowing an uncooled call (fail closed, so a store outage cannot be exploited to bypass the limit)

### Requirement: Deadline-safe deferred answer
The `/ask` command SHALL acknowledge the interaction within Discord's 3-second deadline by returning a deferred response on the HTTP path, and SHALL deliver the model's answer asynchronously by editing the original deferred message.

#### Scenario: Accepted question
- **WHEN** an allowlisted, un-cooled user asks a question
- **THEN** the HTTP path returns a deferred acknowledgement immediately, and the ask-worker later edits the original message to contain the answer

#### Scenario: Answer exceeds Discord message limit
- **WHEN** the model's answer is longer than Discord's 2000-character message limit
- **THEN** the ask-worker truncates the answer to fit (at a line/sentence boundary, not mid-markdown) rather than failing the edit

### Requirement: Retry-safe async handoff with an always-owned outcome
The async invocation of the ask-worker SHALL be treated as at-least-once, not exactly-once. The system SHALL prevent duplicate paid work on retry and SHALL guarantee that every terminal outcome results in the deferred message being edited, so a user never sees a permanent "thinking…" state.

#### Scenario: Worker retry does not double-spend
- **WHEN** the ask-worker completes its side effects (model calls, search, message edit) and then a later error would otherwise occur
- **THEN** the worker does not re-throw after editing the message, and the worker's async event-invoke config sets a maximum retry attempts of 0, so Lambda does not re-run the full model/search loop and bill it again

#### Scenario: Invoke fails after the interaction was deferred
- **WHEN** the entry handler has returned a deferred acknowledgement but the async invoke of the ask-worker fails
- **THEN** the entry handler catches that failure and edits the deferred message with a visible error via the interaction token (the entry handler owns this failure path; it needs only the app id and token, no worker)

#### Scenario: Worker crashes or times out before answering
- **WHEN** the ask-worker crashes before its own error handling runs, or exceeds its timeout
- **THEN** the outcome is still surfaced to the user rather than left silent (top-level catch-all in the worker; worker timeout sized to leave margin before Discord's 15-minute edit window closes)

### Requirement: Cheap-model answering with an optional search tool
The ask-worker SHALL answer questions using Amazon Bedrock Claude Haiku 4.5, exposing exactly one tool — `parallel_search`, backed by the Parallel AI fast Search API — that the model MAY call when a question needs current or non-obvious information. The worker SHALL bound cost and latency with tight, explicit limits: a maximum question length, a maximum number of model turns (default ≤3), a maximum number of `parallel_search` calls per question (default ≤2), a cap on the byte size of search results fed back into the model (they are re-billed on every subsequent turn), a bounded output length, and a client-side timeout (AbortController) on the Parallel `fetch` so a hung search cannot burn the whole Lambda timeout. The system prompt SHALL scope the model to Palworld Q&A, instruct it to prefer a single search, and treat search-result text as untrusted data (never as instructions).

#### Scenario: Answerable without search
- **WHEN** the model can answer from its own knowledge
- **THEN** it responds without calling `parallel_search`, and no Parallel API request is made

#### Scenario: Requires a web lookup
- **WHEN** the model calls `parallel_search`
- **THEN** the worker executes the search against the Parallel API, returns the results to the model, and lets it produce a final answer

#### Scenario: Tool-use loop bound reached
- **WHEN** the model has not produced a final answer within the maximum allowed turns
- **THEN** the worker stops the loop and returns the best answer available (or a clear "couldn't answer" message) rather than looping unbounded

### Requirement: Honest degradation on failure
When any dependency the answer relies on fails (Bedrock, the Parallel search, or the Discord edit), the user SHALL receive an explicit failure message rather than a silent non-answer, and the failure SHALL be logged.

#### Scenario: Model or search backend errors
- **WHEN** Bedrock returns an error, or a `parallel_search` call fails
- **THEN** the worker edits the deferred message with a clear error notice and logs the underlying error; a failed search alone does not crash the answer if the model can still respond without it

#### Scenario: Parallel API key missing
- **WHEN** the Parallel API key SSM parameter is unset or a placeholder
- **THEN** the `parallel_search` tool reports its unavailability to the model (so the model answers without it or says it cannot), rather than the worker throwing an unhandled error

### Requirement: Safe outbound message content
Before editing the deferred message, the ask-worker SHALL neutralize mass mentions in the model's output so an answer cannot ping the server. The interaction token and the raw async event payload SHALL never be logged.

#### Scenario: Model output contains a mass mention
- **WHEN** the model's answer text contains `@everyone`, `@here`, or a role/user mention
- **THEN** the worker neutralizes it (via Discord `allowed_mentions` set to none, and/or escaping the mention syntax) so editing the message pings nobody

### Requirement: Secret and least-privilege handling
The Parallel AI API key SHALL be stored as an SSM SecureString and never embedded in code, Terraform state as plaintext, environment variables at rest in the repo, or logs. The ask-worker's IAM role SHALL grant only Bedrock model invocation for the chosen model, read of the key parameter, and the cooldown table access it needs.

#### Scenario: Key referenced at runtime
- **WHEN** the ask-worker needs the Parallel key
- **THEN** it reads the SecureString from SSM at runtime and does not log its value
