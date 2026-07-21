## Why

The group wants a UE4SS building mod ("Less Building Restrictions") that only runs on a
Windows Palworld dedicated server — the current Ubuntu box structurally cannot load it. The
Windows box is already built and its mod was proven in-game on 2026-07-18; what remains is
the **cutover**: make the Windows instance serve the *real* world and take over the Elastic
IP + Discord/monitoring control plane. The overriding constraint is the 2026-07-18
world-loss incident: **this must never destroy the live Linux server or its world.**

## What Changes

- Rebuild the Windows game instance (`aws_instance.server_windows`) on current code and
  re-validate the building mod on a throwaway world — **before** any cutover.
- Install a second, additive mod `BaseWorkerPalSize50Percent_P.pak` (non-blocking).
- Migrate the live world Linux → Windows via **S3 copy only** (never detach/write the Linux
  world volume), including the mandatory `DedicatedServerName` GUID surgery so Windows
  serves the real world (GUID `E02C5819443F44ED89133A6C03B43E25`) and not a fresh empty one.
- Repoint the control plane to the Windows instance id + Windows backup prefix: start-bot
  Lambda, `/status`, presence daemon, backup/liveness monitor, and the roster SSM parameter.
- Move the Elastic IP association from the Linux instance to the Windows instance.
- **BREAKING** (player-facing, ~2 min): one graceful Linux stop to take a consistent save.
  Keep the Linux instance **stopped, not terminated**, ~1 week as rollback.

## Capabilities

### New Capabilities
- `windows-game-server`: the Windows dedicated server serves the real world with the correct
  world GUID, runs the building mod (and, best-effort, the Pal-size mod), and is the target
  of the EIP, Discord control plane, idle-shutdown, and backup/liveness monitoring.

### Modified Capabilities
<!-- No existing openspec specs (openspec/specs/ is empty); nothing to delta. -->

## Impact

- **Terraform**: `windows_instance.tf` (rebuild), `discord.tf` (INSTANCE_ID + StartInstances
  ARN), `backup_monitor.tf` (INSTANCE_ID + BACKUP_PREFIX→`world/windows/`), `presence.tf`
  (instance_id), `ssm.tf`/`windows.tf` (roster param + IAM), `network.tf` (EIP association),
  `outputs.tf` (cosmetic). Local state + gitignored tfvars bind execution to this checkout.
- **AWS live**: replaces the Windows instance (Linux untouched — plan is `0 to change` on
  `aws_instance.server`); moves the EIP; one brief Linux service stop.
- **Data**: Linux world volume (`prevent_destroy`) is read-only throughout; the real world
  lands on the Windows D: volume (`prevent_destroy`) which becomes non-disposable at cutover.
- **Players**: no impact during validation; a single ~2 min disconnect at the save-copy step
  (only the owner is online).
