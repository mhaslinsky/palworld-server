# AGENTS.md

Terraform manages the live Valheim server in AWS. Palworld runs on the local Windows PC; its AWS estate retired on 2026-09-06. See [palworld/README.md](palworld/README.md) for archived scripts and notes.

## Production Terraform rules

### 1. Never `terraform apply -auto-approve`. Ever.

```
terraform plan -out=tfplan     # then READ it
terraform apply tfplan
```

Before any apply, **quote to the user** the `Plan: X to add, Y to change, Z to destroy`
line and every resource showing `must be replaced` or `will be destroyed`. If Z > 0 or
anything is being replaced, stop and get explicit confirmation naming that resource.

### 2. Terraform plans the ENTIRE state, every time

An apply for feature A will happily ship an unrelated edit to production B that is
sitting in your working tree. **Run `git status` before every apply.** If the diff
contains anything you did not intend to deploy right now, stash it or commit it
separately first. "I only meant to deploy the Windows change" is not a mechanism.

### 3. `terraform/**` is infra-class. Docs tasks do not touch it.

A README fix, a rename, a typo sweep, a grep-and-replace: **none of these may edit
files under `terraform/`**, especially `*.tftpl`. If a search-and-replace hits an
infra file, stop and ask. A comment in a template is not a comment to Terraform - it
is part of a hash that can replace a running server.

### 4. Replacement-class attributes

Changing any of these on a live instance destroys and recreates it. Treat an edit to
one as a deliberate, backup-first operation, never a side effect:

- `ami` (hence: **every AMI is pinned by id**, in `terraform/data.tf`, `terraform/presence.tf`
  - never `most_recent = true` or `ami-windows-latest`, both of which drift into a
  silent replacement on an unrelated apply)
- `user_data` / anything `templatefile()` renders into it
- `subnet_id`, `instance_type` on some families, `availability_zone`

### 5. Do not re-arm the guards in `compute.tf`

`prevent_destroy`, `delete_on_termination = false`, and
`user_data_replace_on_change = false` exist because of the root-volume loss incident
documented in `_global/personal/palworld-server/postmortems/2026-07-18-comment-edit-destroyed-live-world-postmortem.md`. The world now
lives on its own EBS volume (`aws_ebs_volume.world`, also `prevent_destroy`), so a
replacement is survivable rather than fatal - but all four are still load-bearing, and a
replacement still drops every player and re-runs SteamCMD into whatever build is current.

Consequence to remember: with `user_data_replace_on_change = false`, **boot-script edits
no longer reach a running instance through Terraform.** Apply them over SSM, or do a
deliberate backup-first replacement. Silently assuming a template edit deployed is its
own failure.

**But `false` does NOT mean the apply is inert on the box.** Per the AWS provider:
"Updates to this field will trigger a stop/start of the EC2 instance by default."
So editing anything `templatefile()` renders into `user_data` - a threshold, a game
setting, a comment in the template - will **stop and start the live server on apply**,
disconnecting every player, while the script itself does NOT re-run. Both halves bite:
players get dropped AND the change does not take effect.

Every AWS CLI command in rules 5, 7, and 8 pins `--profile aidb-personal --region us-east-1`
because the operator shell defaults to `us-east-2`, which is wrong for this estate.

Read the plan for `aws_instance.server` at all, not just for `must be replaced`. An
in-place `user_data` update is a player-facing restart: announce it, check occupancy with
the full roster command below, and wait, unless the owner says otherwise. Read `count`, not
`names`: `count` is the A2S player count; `names` contains only journal names from the
previous three minutes, so a player connected longer can be missing.

```bash
aws ssm get-parameter \
  --name /palworld-server/roster \
  --profile aidb-personal \
  --region us-east-1
```

Valheim saves on its configured interval and on the SIGINT shutdown path in
`terraform/user_data.sh.tftpl`. Before restarting, run the backup command below over SSM
Run Command. The command resolves the running instance from its `Name=palworld-server` tag.
The box sleeps when idle, so if no running instance id is returned, do not send the command
or start the box. Stop and ask the owner to wake it.

Set `BOX_COMMAND` to the requested command and run this recipe. A successful
`send-command` call means only that AWS accepted the request. Wait for the invocation to
finish, then inspect its final status and output. Accept success only when `Status` is
`Success` and `ResponseCode` is `0`; for the backup, also require the stdout line
`BACKUP_VERIFIED <key> <size>`. `BACKUP_DEGRADED` is not success.

```bash
BOX_COMMAND='sudo -u steam /usr/bin/node /opt/valheim/valheim-backup.mts'
INSTANCE_ID="$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=palworld-server' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text \
  --profile aidb-personal \
  --region us-east-1)" || exit 1
if ! printf '%s\n' "$INSTANCE_ID" | grep -Eq '^i-([[:xdigit:]]{8}|[[:xdigit:]]{17})$'; then
  printf 'Expected exactly one running palworld-server instance, got: %s\n' "$INSTANCE_ID" >&2
  exit 1
fi
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"$BOX_COMMAND\"]" \
  --query 'Command.CommandId' \
  --output text \
  --profile aidb-personal \
  --region us-east-1)" || exit 1
if [ -z "$COMMAND_ID" ] || [ "$COMMAND_ID" = None ]; then
  printf 'send-command returned no command id\n' >&2
  exit 1
fi
while true; do
  if aws ssm wait command-executed \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --profile aidb-personal \
    --region us-east-1; then
    break
  fi
  INVOCATION_STATUS="$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query Status \
    --output text \
    --profile aidb-personal \
    --region us-east-1)" || exit 1
  case "$INVOCATION_STATUS" in
    Success|Failed|TimedOut|Cancelled) break ;;
    Pending|InProgress|Delayed|Cancelling) sleep 5 ;;
    *) printf 'Unexpected invocation status: %s\n' "$INVOCATION_STATUS" >&2; exit 1 ;;
  esac
done
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --output json \
  --profile aidb-personal \
  --region us-east-1
```

This creates, integrity-checks, uploads, and verifies a backup, rather than only reading
the save mtime. Prefer keeping runtime-tunable values OUT of `user_data` entirely (SSM,
like the Discord webhook and roster already are).

**The Valheim box's swap and memory cap live outside `user_data`.** `terraform/memory_guard.tf`
manages them through an SSM association that runs `scripts/memory-guard.mts` every 30 minutes
while the box is up, and on any rebuilt instance. Change the sizes in that script, never by hand
on the box: running `systemctl set-property` without `--runtime` writes a drop-in that outranks
the repo's, and the next scheduled run deletes it. Without the cap, the 4 GB box froze solid on
2026-09-23 when it ran out of memory instead of letting systemd restart Valheim.

### 6. Putting a script in S3 is NOT deploying it

Terraform uploads `a2s.mts`, `idle-logic.mts`, `valheim-idle.mts`, `backup-gates.mts`,
and `valheim-backup.mts` to the backups bucket. `terraform/user_data.sh.tftpl` copies
them into `/opt/valheim` only on first boot, so updating those S3 objects does not update
the running host. `memory-guard.mts` is re-copied by its SSM association in
`terraform/memory_guard.tf`. For a changed script, deliver the updated file to the running
host and verify its contents there before reporting it deployed.

### 7. Backups: check, don't assume

The `aws_s3_bucket.backups` bucket stores healthy world backups under `world/linux/`,
written by `scripts/valheim-backup.mts` on a 30-minute systemd timer. The freshness monitor
for that prefix is configured in `terraform/backup_monitor.tf`. Before any risky operation,
run this listing and confirm an object is no more than 75 minutes old, matching the monitor's
stale threshold. Do not assume the timer is alive.

```bash
aws s3 ls s3://palworld-server-backups-414700437904/world/linux/ \
  --profile aidb-personal \
  --region us-east-1
```

`world/linux-degraded/` holds captures whose save freshness could not be proven, so an
object there is not a healthy backup.
After changing anything in the backup path, prove an actual backup restores before
cutover. This repository has no Valheim restore drill yet.

## Current runbooks

- For alert changes, inspect `terraform/backup_monitor.tf`, `terraform/mod_monitor.tf`, `terraform/alarm_forwarder.tf`, and `discord-bot/alarm-forwarder/index.mjs`. The SNS Discord subscription uses the monitor webhook; only a confirmed email subscriber provides independent coverage, so verify live subscriptions before relying on them.
- Start mod work with [mods/README.md](mods/README.md), especially [Mod behavior and rollout checks](mods/README.md#mod-behavior-and-rollout-checks), and `mods/manifest.json`. When adding a mod, read its README's declared target game build and record the target-build gap on the manifest entry when one exists. Compare each mod's declared target against `game_version` rather than its upload date; check setting gates and units, and test runtime behavior before treating a mod as working. Verify the server before publishing a matching client pack.

## Archived Palworld safeguards

- Keep plain content paks and `LogicMods` in separate, nonempty stages; staging is authoritative and a missing mod can fail silently.
- For archived UE4SS mods, stage the full Okaetsu folder, preserve the local `BPModLoaderMod` patch, create Lua paths under `C:\PalServer`, and snapshot `UE4SS.log` during tests.
- Read the archived Windows Event Log registry and bootstrap notes in [palworld/README.md](palworld/README.md), and confirm they apply locally before use.

## Behavior verification

### 8. Verify on the box, not by exit code

This codebase has produced several failures that reported success:

- an upload that exited 0 while S3 had no object (IAM denied, message swallowed)
- a roster publish that failed every cycle because `aws` is not on `PATH` in a
  Scheduled Task's SYSTEM context, inside a bare `try/catch`
- a restore that "succeeded" while serving a freshly generated **empty** world
- a `user_data` that never ran at all because an em dash in a comment broke the parse
- a systemd timer that was `start`ed but never `enable`d, so it worked perfectly
  until the next reboot and then never came back. `systemctl status` said `active`
  right up to the reboot; only `is-enabled` would have said `disabled`. **Check
  `is-enabled`, not just `is-active`** - and prefer `enable --now` to `start`.

So: after a change, ask the running system what it thinks is true: read the roster's
`count` with the complete command in rule 5, and run `journalctl -u valheim` over SSM by
setting `BOX_COMMAND='journalctl -u valheim'` and using the same SSM recipe in rule 5. Repeat
the backup listing in rule 7. Do not trust the command's return code alone. And when adding
a guard, **make it fail once on purpose** before believing it.

## Context

Plans, postmortems and runbooks live in AIDB at
`~/Developer/AIDB/_global/personal/palworld-server/`, not in this repo.
