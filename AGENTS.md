# AGENTS.md

Terraform for a Palworld dedicated server that a group of friends actually plays on.
**This repo manages a live service with other people's progress in it.** Treat every
apply as production.

## The rules that exist because they were broken

On 2026-07-18 an agent fixed the spelling of "pow world" -> "palworld" in a **comment**
inside `terraform/user_data.sh.tftpl`, then ran `terraform apply -auto-approve` for
unrelated work. The comment changed the rendered `user_data` hash; with
`user_data_replace_on_change = true` Terraform replaced the live instance; the world
lived on its root volume and was deleted with it. About 4.5 hours of five players'
progress was lost. The plan said `aws_instance.server must be replaced` in plain text
and was never read.

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
`user_data_replace_on_change = false` exist because of the incident above. The world now
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

### 6. Backups: check, don't assume

- Rolling backups land in `s3://palworld-server-backups-<account>/world/linux/` every
  30 min, written by `scripts/backup-to-s3.sh` on a systemd timer.
- A Lambda checks freshness every 15 min and alerts Discord.
- Before any risky operation, confirm a **recent** object exists - do not assume the
  timer is alive:
  `aws s3 ls s3://palworld-server-backups-414700437904/world/linux/ | tail -3`
- `scripts/restore-drill.ps1` proves a backup actually restores. Run it after changing
  anything in the backup path, and before cutover.

### 7. Verify on the box, not by exit code

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

## Live-service etiquette

- Check who is online first: `aws ssm get-parameter --name /palworld-server/roster`.
- A restart disconnects players for 1-2 min. Announce via the REST `/announce` endpoint
  and wait, unless the owner says otherwise.
- Force-save before any restart, and confirm `Level.sav`'s mtime advanced - an HTTP 200
  on `/save` is not proof the world reached disk.
- `POST /v1/api/save` needs `Content-Length: 0` or it returns HTTP 411.
- `OptionSettings` is a **single line**; keys must be inserted inside the parens. Keys
  appended on a new line are ignored, and keys near the tail are the first casualty if
  the line is ever truncated - insert at the front.
- Game-balance settings live in the INI, not the world save. Restoring a save does not
  restore them, and a rebuilt instance comes up with engine defaults - which ejects
  every Pal over the base cap onto the ground.

## Platform notes

- **Windows**: `PalServer.exe` (the wrapper) hangs in session 0 - launch
  `Pal\Binaries\Win64\PalServer-Win64-Shipping.exe` directly. SteamCMD's first run only
  self-updates and skips `app_update`, so the install needs a retry loop.
- `windows_user_data.ps1.tftpl` **must stay pure ASCII** - EC2Launch does not decode it
  as UTF-8 and a single em-dash breaks the PowerShell parse. Check:
  `grep -P '[^\x00-\x7F]'`.
- PowerShell 5.1 reads a BOM-less `.ps1` as ANSI; injected scripts get a UTF-8 BOM from
  the injector for exactly this reason.
- Windows bootstrap scripts ship via S3 (`scripts/windows/` in the backups bucket), not
  embedded in `user_data` - that hit EC2's hard 16 KB limit, and S3 hosting means a
  script fix does not force an instance rebuild.
- Palworld does not auto-load an existing world. `DedicatedServerName` in
  `GameUserSettings.ini` decides, and a fresh install generates its own GUID - this is
  how a restore ends up serving an empty world.

## Context

Plans, postmortems and runbooks live in AIDB at
`~/Developer/AIDB/_global/personal/palworld-server/`, not in this repo.
