## Context

Terraform-managed Palworld server on AWS (`aidb-personal`, us-east-1). The Windows migration
is ~90% built and gated on `enable_windows_migration = true`; the Windows box
(`i-03b0719f765c523c1`, stopped) had its mod proven in-game 2026-07-18. The live Linux box
(`i-09d1d8ae70eb28369`) is running with the owner online. Local tfstate + gitignored tfvars
bind execution to the primary checkout. The governing history is the 2026-07-18 world loss
(an untargeted `terraform apply` replaced the live instance).

## Goals / Non-Goals

**Goals**: Windows serves the real world with both mods; EIP + control plane repointed;
zero risk to the Linux world; one short owner-only disconnect.

**Non-Goals**: preserving the Windows box across the rebuild (disposable until the real world
lands on D:); resizing the instance; changing game balance; terminating Linux (kept as
rollback ~1 week).

## Decisions

- **Rebuild Windows before cutover** (vs. cut over as-is). Owner accepts a wiped Windows box;
  rebuilding validates current code. Risk lives entirely on the disposable Windows side.
- **S3 as the save transport, read-only from Linux** (vs. detach + remount the Linux world
  volume). The volume that must never be at risk is never touched; ext4→NTFS remount avoided.
- **Explicit GUID surgery** — set `DedicatedServerName=<GUID>` in `GameUserSettings.ini`
  (pattern in `scripts/restore-drill.ps1:65`). Without it Palworld generates a fresh empty
  world (the documented empty-world trap). Verified served GUID gates the EIP move.
- **Full `terraform plan`, not `-target`** — the untargeted plan already shows `0 to change`
  on Linux, and HashiCorp warns against routine `-target`; reading the whole plan is safer.
- **Building mod gates; Pal-size mod does not** — the migration's purpose is the building mod.

## Risks / Trade-offs

- [SteamCMD pulls a mod-breaking Palworld build on rebuild] → validate the building mod on a
  throwaway world; fail closed at Phase A; Linux untouched while we pin/fix.
- [Windows serves an empty world] → verify `worldguid` via REST before moving the EIP.
- [macOS `._*` AppleDouble files + ext4/NTFS case-sensitivity corrupt the placed save] →
  strip with `COPYFILE_DISABLE=1` + `find -name '._*' -delete` when extracting.
- [An untargeted apply replaces Linux] → saved-plan review + quote `Plan:`/replacements;
  abort if `aws_instance.server` is in the change set; never `-auto-approve`.
- [Losing the irreplaceable, Nexus-gated building-mod `.pak`] → it lives on the
  `prevent_destroy` D: volume (survives rebuild); snapshot D: before rebuild anyway.

## Migration Plan

Parallel build + validate (Linux up) → brief graceful Linux stop → fresh backup → S3 copy +
GUID surgery onto Windows D: → verify served GUID → repoint control plane + move EIP →
verify Discord/monitor/idle paths → keep Linux stopped ~1 week, then decommission.
**Rollback**: start the Linux instance and move the EIP back — its world was never mutated.
Snapshot the Windows save before any rollback so Windows-era progress stays re-attemptable.

## Open Questions

- Does the Pal-size mod need per-client subscription to take visual effect? (test, non-blocking)
- Exact "declare good" soak length before decommissioning Linux (default ~1 week).
