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
