# Palworld

Palworld now runs on the Windows PC "ascension" as a scheduled task, not in AWS.
The AWS estate was retired on 2026-09-06.

This directory keeps:

- mod notes
- Save Pal compensation scripts
- the modkit reference
- old Windows box scripts for reference

Retirement record: AIDB plan
`_global/personal/palworld-server/2026-09-06-palworld-wind-down-and-valheim-plan.md`.

## Archived AWS operational notes

Verify these notes on the local Windows server before relying on them; its current settings, paths, and Event Log writers have not been checked.

### Save notes recorded on the AWS host

- Force-save before any restart. Confirm `Level.sav`'s mtime advanced because an HTTP 200
  on `/save` does not prove the world reached disk.
- `POST /v1/api/save` needs `Content-Length: 0`; without it, the endpoint returns HTTP 411.

### World settings recorded on the AWS host

- `OptionSettings` is a **single line**; keys must be inserted inside the parens. Keys
  appended on a new line are ignored, and keys near the tail are lost first if the line
  truncates; insert at the front.
- Game-balance settings live in the INI rather than the world save. Restoring a save does
  not recover them, and a rebuilt instance starts with engine defaults, ejecting every
  Pal over the base cap onto the ground.

### Windows bootstrap notes recorded on the AWS host

- **Windows**: `PalServer.exe` (the wrapper) hangs in session 0; launch
  `Pal\Binaries\Win64\PalServer-Win64-Shipping.exe` directly. SteamCMD's first run only
  self-updates and skips `app_update`, so the install needs a retry loop.
- `windows_user_data.ps1.tftpl` **must stay pure ASCII**; EC2Launch does not decode it
  as UTF-8 and a single em dash breaks the PowerShell parse. Check:
  `grep -P '[^\x00-\x7F]'`.
- PowerShell 5.1 reads a BOM-less `.ps1` as ANSI, so the injector prepends a UTF-8 BOM.
- Windows bootstrap scripts shipped via S3 (`scripts/windows/` in the backups bucket)
  because embedding them in `user_data` exceeded EC2's hard 16 KB limit. S3 hosting meant
  a script fix did not force an instance rebuild.
- Palworld does not auto-load an existing world. `DedicatedServerName` in
  `GameUserSettings.ini` controls this, and a fresh install generates its own GUID; this is
  how a restore can end up serving an empty world.

### Windows Event Log IDs from the AWS estate

`Write-Output` from a Scheduled Task running as SYSTEM went nowhere visible, so
`palworld-idle.ps1` also logged best-effort failures to the Application event log.
Check this on a Windows host only after verifying that it runs the corresponding scripts:

```powershell
Get-EventLog -LogName Application -Source Palworld -Newest 30 | Format-Table TimeGenerated, EventID, EntryType, Message -AutoSize
```

**The source was shared by every writer in the AWS estate, so IDs were allocated across
the whole repository, including the former `terraform/windows_user_data.ps1.tftpl`.**
Widening the search uncovered four collisions from before this registry existed: `106`
meant both "SteamCMD install failed" and "watchdog stuck disabled", `107` both "UE4SS
restore failed" and "stale build stranded", `109` both "may serve an EMPTY world" and
"alert dropped", and `110` both "backup failed" and "Discord POST failed". Filtering for
a critical event only to hit unrelated noise defeats the point of distinct IDs.

**Before assigning an ID in a current script, scan every current Palworld writer.** The
former Windows `user_data` template is no longer in this checkout:

```bash
grep -ho 'EventId 1[0-9][0-9]' palworld/scripts/*.ps1 | sort -u
```

The former `windows_user_data.ps1.tftpl` writer owned 102, 106, 107, and 108. Its source
is retired and must not be used to decide which IDs are available on the local host.

| ID | Writer | Meaning |
|----|--------|---------|
| 101 | launch | `PalServer` shipping exe missing. |
| 102 | user_data | A bootstrap script fetched from S3 was unusable. |
| 103 | idle | Roster publish failed. The off-box backup monitor reads a stale roster as "the idle watcher is dead". |
| 104 | idle | Watchdog: the launcher script is missing, so a crashed server cannot be restarted. |
| 105 | idle | Watchdog: the launcher exited non-zero; the server did not start. |
| 106 | user_data | SteamCMD install failed after 3 attempts; the shipping exe is missing. (Overlaps 101's meaning from a different stage of the box's life. Left as-is because the template could not be edited safely.) |
| 107 | user_data | Ambiguous RAW disks; the save volume was not initialized. |
| 108 | user_data | UE4SS restore failed, its durable stage is missing, or the restore was incomplete and the server is vanilla. |
| 109 | launch | No staged `GameUserSettings.ini`; the server may serve an **EMPTY world** while the real save sits intact on D:. |
| 110 | backup | Backup failed. |
| 111 | idle | A duplicate `PalServer` was reaped (which one was kept, and why). |
| 112 | launch | Launch failed: no process object, exited within 10s, or no process appeared within 10s. |
| 113 | launch | Timed out after 30s waiting for the start lock while no server is running. |
| 114 | idle | **FAILED** to kill duplicate `PalServer` processes. This is the condition that exhausted memory on 2026-07-31. |
| 115 | launch | Pak-mod staging: removed unstaged, restored from stage, failed to restore, or removed under vanilla mode. |
| 116 | idle | An alert was dropped because no webhook resolved. The message body is in the entry. |
| 117 | idle | The Discord POST itself failed (revoked token, deleted webhook, 429, outage). The message body is in the entry. |
| 118 | idle | Installed-build publish failed or threw. The version monitor loses its freshness signal. |
| 119 | idle | `update.lock` has been HELD over an hour. The watchdog and idle-shutdown have been standing down that whole time, so the box is billing and a crashed server will not be restarted. Logged once per stuck lock. |
| 120 | idle | The Discord webhook could not be resolved from SSM. **Alerts from this box are down.** |
| 121 | idle | The appmanifest was unreadable AND the UNKNOWN sentinel could not be published, so a stale build ID is stranded in SSM. |
| 122 | launch | `PalworldIdle` was disabled at startup. Error = could NOT be re-enabled, so there is no watchdog and no idle shutdown; Warning = it was re-armed. |
| 123 | update | The updater could not resolve the webhook; update progress and results will not reach Discord. |
| 124 | update | The updater's Discord POST failed. The message body is in the entry, and the SSM command output still has the text. |
| 125 | idle | `update.lock` state could NOT be determined. The cycle stands down, so the watchdog and idle-shutdown are both inactive until it clears; if it persists the box will not stop on its own. |

IDs 116, 117, and 120 handled alerts. Alerting was best-effort by design: `Send-Notify`
ran from shutdown and save-verification paths where throwing would trade "I could not
tell you" for "I stopped protecting the world." Silent failure was the bug, and these
IDs made a dropped alert recoverable.
