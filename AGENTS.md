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

- `ami` (hence: **every AMI is pinned by id**, in `data.tf`, `presence.tf`, `windows.tf`
  - never `most_recent = true` or `ami-windows-latest`, both of which drift into a
  silent replacement on an unrelated apply)
- `user_data` / anything `templatefile()` renders into it
- `subnet_id`, `instance_type` on some families, `availability_zone`

### 5. Do not re-arm the guards in `compute.tf`

`prevent_destroy`, `delete_on_termination = false`, and
`user_data_replace_on_change = false` exist because of the root-volume loss incident documented in the CAI-1990 incident artifact. The world now
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

Read the plan for `aws_instance.server` at all, not just for `must be replaced`. An
in-place `user_data` update is a player-facing restart: announce it, force-save, and
confirm `Level.sav`'s mtime advanced first. Prefer keeping runtime-tunable values OUT
of `user_data` entirely (SSM, like the Discord webhook and roster already are).

**The Valheim box's swap and memory cap live outside `user_data`.** `terraform/memory_guard.tf`
manages them through an SSM association that runs `scripts/memory-guard.mts` every 30 minutes
while the box is up, and on any rebuilt instance. Change the sizes in that script, never by hand
on the box: running `systemctl set-property` without `--runtime` writes a drop-in that outranks
the repo's, and the next scheduled run deletes it. Without the cap, the 4 GB box froze solid on
2026-09-23 when it ran out of memory instead of letting systemd restart Valheim.

## Current runbooks

- For alert changes, inspect `terraform/backup_monitor.tf`, `terraform/mod_monitor.tf`, `terraform/alarm_forwarder.tf`, and `discord-bot/alarm-forwarder/index.mjs`. The SNS Discord subscription uses the monitor webhook; only a confirmed email subscriber provides independent coverage, so verify live subscriptions before relying on them.
- Start mod work with [mods/README.md](mods/README.md) and `mods/manifest.json`. Compare each mod's readme-declared target game build against `game_version` rather than its upload date; check setting gates and units, and test runtime behavior before treating a mod as working. Verify the server before publishing a matching client pack.

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
- a `user_data` that never ran at all because an em-dash in a comment broke the parse
- a systemd timer that was `start`ed but never `enable`d, so it worked perfectly
  until the next reboot and then never came back. `systemctl status` said `active`
  right up to the reboot; only `is-enabled` would have said `disabled`. **Check
  `is-enabled`, not just `is-active`** - and prefer `enable --now` to `start`.

So: after a change, ask the running system what it thinks is true (`/v1/api/settings`,
`/v1/api/info`, `aws s3 ls`, the served world GUID) rather than trusting the command's
return code. And when adding a guard, **make it fail once on purpose** before believing
it.

## Context

Plans, postmortems and runbooks live in AIDB at
`~/Developer/AIDB/_global/personal/palworld-server/`, not in this repo.
