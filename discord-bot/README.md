# Discord start bot — phase 2 (no deadline)

The **start** half of the control plane. Lets a whitelisted friend bring the server
back up from Discord. The **stop** half is already handled on the server itself
(`scripts/idle-shutdown.sh` + systemd timer) — see the repo README.

Not built yet. Design is locked (see the AIDB decision doc referenced in the root
README). Planned shape:

- **Discord Application + slash command** (`/pow-start`, `/pow-status`) with an
  **Interactions Endpoint URL** (NOT a webhook, NOT a Gateway socket).
- **AWS Lambda (Function URL, `NONE` auth)** that:
  1. Verifies the `X-Signature-Ed25519` header over `timestamp + raw body` using the
     app's public key; rejects with 401 on failure; rejects if `|now - timestamp| > 5m`.
  2. Checks the caller's `member.user.id` against a **snowflake allowlist** (env/SSM).
  3. ACKs within Discord's 3-second window (deferred response), then calls
     `ec2:StartInstances` on the single instance ARN and edits the follow-up message.
- **IAM**: least-privilege — `ec2:StartInstances` + `ec2:DescribeInstances` on this
  instance only.
- **Guardrails**: per-user `/start` cooldown; CloudWatch billing alarm.

Will be added as a `terraform/discord/` module (or sibling stack) when built.

---

## `/ask` — Palworld Q&A (added by the discord-ask-command change)

A cheap Bedrock (Claude Haiku 4.5) Q&A command. Allowlisted users ask a Palworld
question; the model answers, optionally calling one Parallel AI web-search tool.

- **Entry** (`src/index.mjs`): verifies the signature, checks the allowlist, claims a
  per-user cooldown (DynamoDB conditional write, fail-closed), defers, and async-invokes
  the ask-worker. Never spends on a rejected request.
- **Worker** (`ask-worker/index.mjs`): bounded tool-use loop (turns, searches, output
  tokens, result bytes all capped), then edits the deferred message. Async retries are
  disabled (`maximum_retry_attempts = 0`) and the worker never throws after editing, so
  an accepted `/ask` costs exactly one loop. Outbound text is posted with
  `allowed_mentions: {parse: []}` so an answer can never `@everyone` the server.

### Prerequisites before it works live
1. **Bedrock model access** for Claude Haiku 4.5 enabled in the account/region, and the
   Terraform vars `bedrock_model_id` + `bedrock_model_arns` set to the EXACT inference-
   profile id and ARNs (profile ARN **and** the underlying regional model ARNs).
2. **Parallel AI key** seeded into SSM: `terraform apply` with `-var parallel_api_key=...`
   once, or `aws ssm put-parameter --name /palworld-server/parallel_api_key --type
   SecureString --value <key> --overwrite`. Without it, search is disabled and the model
   answers from its own knowledge (it does not error).

### Registering the slash commands
```bash
cd discord-bot
export DISCORD_APP_ID=<app id>
export DISCORD_BOT_TOKEN=$(aws ssm get-parameter --name /palworld-server/discord_bot_token \
  --with-decryption --query Parameter.Value --output text --region us-east-1)
node register-commands.mjs           # global; add DISCORD_GUILD_ID=<id> for instant, guild-scoped
```

### Tests
```bash
cd discord-bot && npm install && npm test   # backup-monitor + ask-entry + ask-worker
```
