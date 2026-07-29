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

---

## `/palworld-update` - pull the latest Steam build on demand

Steam patches Palworld often, and a client that auto-updates can no longer join a
server still on the old build. This command updates the **Windows** game box to the
current Steam build without a Terraform apply or an instance rebuild.

Flow: the entry Lambda defers, then the worker calls **`ssm:SendCommand`
(AWS-RunPowerShellScript)** on the game instance. That command pulls
`scripts/windows/update-server.ps1` fresh from S3 and runs it. The script does the
whole risky dance on the box - force-save + prove it hit disk, a pre-update backup,
**disable the `PalworldIdle` watchdog** (so it can't relaunch mid-update and fight a
locked binary), graceful `/shutdown`, `steamcmd +app_update` (twice - the first pass
often only self-updates SteamCMD), then a `try/finally` that **re-arms the watchdog no
matter what** and relaunches. It posts `🔧` start and `✅ v<version>` / `⚠️` result to
the same Discord webhook the up/down notices use.

- **Only when running.** SSM can't reach a stopped box, and a fresh boot comes up on
  the *same* build (boot never runs SteamCMD by design). If stopped, the bot tells the
  user to `/palworld-start` first.
- **IAM**: `ssm:SendCommand` scoped to this one instance ARN + the AWS-managed
  `AWS-RunPowerShellScript` document - not a general remote-exec grant.
- **`mods` option** (this is a modded server): `keep` (default) re-stages the current
  UE4SS build from D:; `vanilla` disables UE4SS so the box is joinable regardless of mod
  compatibility (building goes vanilla); `restage` `aws s3 sync`s a matching build from
  `s3://<bucket>/ue4ss-stage/` onto D: first, then overlays it. The on-box script owns
  this logic; the worker just forwards the validated choice. See `docs/client-mods.md`
  for the patch-day flow.
- **Modded servers**: a game update will likely outrun the client-side UE4SS/mod
  builds until those are bumped too. Base update is safe; relaxed building needs matching
  server- *and* client-side mods, so expect `mods:vanilla` right after a patch, then
  `mods:restage` once matching builds exist.

`update-server.ps1` carries a UTF-8 BOM (it has emoji, and PS 5.1 reads a BOM-less
`.ps1` as ANSI). It is **not** in the boot-fetch list in `windows_user_data.ps1.tftpl`
on purpose: adding it there would change the `user_data` hash and stop/start the live
box on apply. It ships only as its own `aws_s3_object` and is pulled per-run.
