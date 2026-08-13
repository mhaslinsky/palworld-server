# Palworld Windows updater - pulls the latest Steam build on demand.
#
# Triggered by the Discord /palworld-update command: the bot Lambda fetches this
# script from S3 and runs it via SSM RunPowerShellScript (as SYSTEM). It also runs
# by hand in an SSM session. This is the ONLY supported way to update the build -
# the boot path runs SteamCMD only when the binary is MISSING (see
# windows_user_data.ps1.tftpl), so nothing updates the game on its own. That is
# deliberate: an unattended update can land a build the client mods have not caught
# up to. This script makes the update an explicit, announced, backup-first action.
#
# Sequence, and why each step exists:
#   1. force-save + PROVE it (Level.sav mtime advanced) - a 200 on /save is not disk.
#   2. fresh backup (best-effort, LOUD) - a build swap should have an escape hatch.
#   3. DISABLE PalworldIdle and CONFIRM it went down - it is BOTH the 2-min watchdog
#      AND idle-shutdown; left armed it relaunches the server mid-update and SteamCMD
#      then fights a locked binary, producing a half-patched install (the worst
#      failure: it still parses). A disable that silently failed is the same thing, so
#      this aborts rather than trusting the cmdlet.
#   4. graceful /shutdown with a real 60s warning, then confirm the process exited.
#   5. steamcmd +app_update, TWICE - the first run often only self-updates steamcmd
#      and silently skips app_update (verified on this box) - and CHECK the exit code
#      of the final pass, because a failed update leaves the old binary in place and
#      every later check then passes.
#   6. finally{}: RE-ARM PalworldIdle no matter how we exit and VERIFY the re-arm took,
#      then relaunch through the launcher. A failure that left the watchdog disabled
#      means no auto-restart and no idle-shutdown - a dead-or-costly box with nothing
#      watching it, and nothing saying so.
#   7. verify by COMPARING the version against the one recorded in step 0. Asking
#      /info proves the server is UP; only the comparison proves the build moved.
#
# The emoji in the Discord strings are why this file carries a UTF-8 BOM: PowerShell
# 5.1 reads a BOM-less .ps1 as ANSI and the multibyte bytes break the parse, so the
# script would never run. s3 cp preserves the bytes exactly.
#
# -Mods controls the UE4SS layer, because this is a MODDED server and a base patch
# usually outruns the mod builds (see docs/client-mods.md):
#   keep     - re-overlay the UE4SS build currently on D: (default). Right when the
#              staged build already matches the new game version.
#   vanilla  - DISABLE UE4SS (remove the dwmapi.dll loader) so the box boots clean and
#              is JOINABLE regardless of mod compatibility. Building falls back to
#              vanilla. The escape hatch when the mod builds have not caught up.
#   restage  - `aws s3 sync` a matching UE4SS build from s3://<bucket>/ue4ss-stage/
#              onto the D: durable stage FIRST, then overlay it like keep. This is the
#              no-RDP path: upload the new build to S3, then run this.

param(
  [ValidateSet('keep', 'vanilla', 'restage')]
  [string]$Mods = 'keep'
)

$ErrorActionPreference = "Continue"

$conf        = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$restBase    = "http://127.0.0.1:$($conf.RestPort)/v1/api"
$saveGlob    = "$($conf.SaveRoot)\*\*\Level.sav"
$saveQualifier = Split-Path -Qualifier $conf.SaveRoot   # e.g. "D:" - also where UE4SS is staged
$steamcmd    = "C:\steamcmd\steamcmd.exe"
$installDir  = "C:\PalServer"
$appId       = "2394010"
$shipping    = "PalServer-Win64-Shipping"
$shippingExe = "C:\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe"
$label       = $conf.ServerLabel

$stateDir = "C:\PalServer\state"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$lock = Join-Path $stateDir "update.lock"
# Carries "when was this update last making progress". Separate from the lock because
# the lock is held open with FileShare::Read for the whole run, which excludes the
# second write handle that stamping its own timestamp would need.
$heartbeatFile = Join-Path $stateDir "update.heartbeat"

# Absolute path, NOT bare "aws": the CLI is not on PATH in the SYSTEM context an SSM
# command runs under, so `& aws ...` resolves to nothing and every call fails inside
# its catch. Same lesson as palworld-idle.ps1.
$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}

$secure = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("admin", $secure)

function Get-WebhookUrl {
  if (-not $conf.WebhookParam) { return $null }
  try {
    $value = & $awsExe ssm get-parameter --name $conf.WebhookParam --with-decryption `
      --region $conf.AwsRegion --query 'Parameter.Value' --output text 2>$null
    # An unset SSM parameter comes back as the literal string "None".
    if ($value -and $value.Trim() -ne "None") { return $value.Trim() }
    Write-EventLog -LogName Application -Source "Palworld" -EventId 123 -EntryType Error `
      -Message "update-server Get-WebhookUrl: $($conf.WebhookParam) resolved to nothing (aws exit $LASTEXITCODE). Update progress and results will not reach Discord." -ErrorAction SilentlyContinue
  } catch {
    Write-EventLog -LogName Application -Source "Palworld" -EventId 123 -EntryType Error `
      -Message "update-server Get-WebhookUrl threw: $($_.Exception.Message). Update progress and results will not reach Discord." -ErrorAction SilentlyContinue
  }
  return $null
}

function Send-Notify([string]$content) {
  # Echo to stdout as well as Discord. docs/client-mods.md tells you to run this by
  # hand over SSM Run Command, and every progress and result line goes to the webhook -
  # so by hand the command returned Success with COMPLETELY EMPTY output and you had to
  # take the update on faith. Observed 2026-07-29 on the v1.0.1 -> v1.0.2 update.
  # Printed BEFORE the webhook attempt, so a run with no webhook configured still says
  # what happened rather than going dark twice over.
  Write-Output $content
  $url = Get-WebhookUrl
  if (-not $url) { return }
  try {
    $body = @{ content = $content } | ConvertTo-Json -Compress
    # PS 5.1 otherwise sends string bodies through the ANSI code page, mangling emoji.
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
    # -ErrorAction Stop because this file also runs under "Continue"; without it a
    # non-terminating error would skip the catch and the failure would vanish.
    Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' `
      -Body $bodyBytes -TimeoutSec 5 -ErrorAction Stop | Out-Null
  } catch {
    # This one is worse than the idle script's equivalent, because an update posts its
    # progress AND its verdict here. A swallowed failure meant a build swap that
    # announced nothing: no "starting", no "back up on version X", no warning that the
    # mod did not load. The Write-Output above already echoed the text to the SSM
    # command output, so this records that Discord specifically did not get it.
    Write-EventLog -LogName Application -Source "Palworld" -EventId 124 -EntryType Error `
      -Message "update-server Discord POST failed: $($_.Exception.Message). Not delivered: $content" -ErrorAction SilentlyContinue
    Write-Output "ERROR: Discord POST failed ($($_.Exception.Message)); the line above did not reach Discord"
  }
}

function Get-LatestLevelSav {
  Get-ChildItem $saveGlob -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc | Select-Object -Last 1
}

# --- Runtime proof that the building mod actually WORKS ------------------------
# The file checks in step 5b prove the overlay COPIED. They cannot prove the mod does
# anything, and on 2026-07-30 that gap bit: every file was present and correct against
# game v1.0.2.100933, so the report said "Relaxed-building mod loaded" while the mod
# was printing
#     [BuildingRestrictionDisabler]: Version pattern not found :(
# on every attempt. 1898 finds the code it patches by AOB signature scan, and a game
# patch moves those bytes - so the mod loads, registers, and silently no-ops. Building
# was vanilla for a day with a green report on the board.
#
# So: after the server is back up, read what the mod SAID about itself. Note the log tag
# is 'BuildingRestrictionDisabler' (singular Restriction) while the folder is
# 'BuildingRestrictionsDisabler' - the regex tolerates both rather than matching neither.
#
# Returns 'ok' | 'failed' | 'unknown'. 'unknown' is deliberately NOT 'ok': a missing or
# unreadable log means the check did not run, and reporting that as a pass is the same
# defect this function exists to close (AGENTS.md rule 8).
#
# $logPath is a parameter only so this can be exercised against a fixture log without
# editing a copy of it - the guard is worth nothing until it has been made to go red.
function Test-ModRuntimeStatus([datetime]$sinceUtc, [string]$logPath) {
  $log = if ($logPath) { $logPath } else { "C:\PalServer\Pal\Binaries\Win64\ue4ss\UE4SS.log" }
  if (-not (Test-Path $log)) { return 'unknown' }
  try {
    # UE4SS stamps every line [yyyy-MM-dd HH:mm:ss.fffffff] and logs in UTC (it prints
    # "Timezone: Etc/UTC" at startup). UE4SS TRUNCATES this log on every launch, so in
    # practice the file already holds only the current run - verified 2026-07-30, where
    # lines from 16:12 were gone from the whole file by 16:35. The timestamp filter is
    # therefore defense in depth, not the load-bearing part: it costs nothing and means
    # this check does not silently start reading a previous boot's verdict if UE4SS ever
    # switches to appending.
    $lines = Get-Content $log -ErrorAction Stop | Where-Object {
      if ($_ -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        try { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) -ge $sinceUtc }
        catch { $false }
      } else { $false }
    }
  } catch { return 'unknown' }
  if (-not $lines) { return 'unknown' }

  $modTag = 'BuildingRestrictions?Disabler'

  # Judge the OUTCOME, not the presence of an alarming line. The mod retries its version
  # scan, so "Version pattern not found :(" is normal cold-boot noise: on 2026-07-30 a
  # healthy start printed it 13 times before succeeding. A draft of this check treated
  # any occurrence as decisive and reported a working server as broken - which is the
  # cry-wolf failure that gets a guard switched off, and is not an improvement on the
  # false green it replaced.
  #
  # The three states are distinguished by what the mod ENDS UP saying:
  #   failed : "Incompatible game client version ... !"  (it gives up - terminal), or the
  #            scan retried and never once succeeded (v1.75 on game 1.0.2.100933: 13+
  #            "not found", zero "found")
  #   ok     : "Found all AOBs for restriction <...>" - it located and hooked real
  #            restrictions. Stronger than "Disabling restrictions", which the mod prints
  #            early, BEFORE the scan that can still fail.
  #   unknown: none of the above appeared in this window

  # Terminal refusal outranks everything: the mod has stopped trying.
  $incompatible = $lines | Where-Object { $_ -match $modTag -and $_ -match 'incompatible' }
  if ($incompatible) { return 'failed' }

  # Proof of work. 1.78 legitimately fails ONE of ~22 restrictions ("Not connected to
  # structure") on a build it otherwise supports, so this deliberately does not demand a
  # clean sweep - "Could not find all AOBs" for a single restriction is not a mod that
  # failed to load.
  $hooked = $lines | Where-Object { $_ -match 'Found all AOBs for restriction' }
  if ($hooked) { return 'ok' }

  # Retried and got nowhere. Reached only when no AOB was ever hooked above.
  $scanFailed = $lines | Where-Object { $_ -match $modTag -and $_ -match 'pattern not found' }
  if ($scanFailed) { return 'failed' }

  $otherFailure = $lines | Where-Object {
    ($_ -match $modTag -and $_ -match 'unsupported|fatal') -or ($_ -match "Failed to start .*$modTag")
  }
  if ($otherFailure) { return 'failed' }
  return 'unknown'
}

# --- Concurrency guard: exactly one update at a time --------------------------
# A double /palworld-update (or a hand-run overlapping the bot) would launch two
# SteamCMDs into the same dir. The acquire is an ATOMIC CreateNew, not Test-Path then
# write: two SSM commands arriving together would both see no lock and both proceed,
# which is the one outcome this guard exists to prevent.
#
# Holding the handle open for the whole run is also what makes the 30-min staleness
# rule safe. A lock left behind by a crashed run has nothing holding it and deletes
# cleanly; a genuinely slow LIVE run still owns its handle, the delete fails, and the
# second invocation bails instead of reclaiming a lock that is still in use.
#
# palworld-idle.ps1 reads this same file to stand down while an update is running.
$lockHandle = $null
function Open-UpdateLock {
  try { return [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
  catch { return $null }
}
function Remove-UpdateLock {
  if ($script:lockHandle) {
    try { $script:lockHandle.Dispose() } catch { }
    $script:lockHandle = $null
  }
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  # The sidecar goes with it. A heartbeat left behind after the lock is gone would make
  # the NEXT update's lock look like it had already been running for however long this
  # file had been sitting there.
  Remove-Item $heartbeatFile -Force -ErrorAction SilentlyContinue
}

$lockHandle = Open-UpdateLock
if (-not $lockHandle) {
  $existing = Get-Item $lock -ErrorAction SilentlyContinue
  $age = if ($existing) { (Get-Date) - $existing.LastWriteTime } else { [TimeSpan]::Zero }
  if ($age.TotalMinutes -lt 30) {
    Send-Notify "⏳ **$label**: an update is already in progress - ignoring this request."
    exit 0
  }
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  $lockHandle = Open-UpdateLock
  if (-not $lockHandle) {
    # "Could not confirm I am alone" must not end up reading as "I am alone".
    Send-Notify "⏳ **$label**: could not take the update lock - another update holds it. Ignoring this request."
    exit 0
  }
}
$stamp = [Text.Encoding]::UTF8.GetBytes((Get-Date).ToString("o"))
$lockHandle.Write($stamp, 0, $stamp.Length)
$lockHandle.Flush()

# Re-stamp the lock so its age means "how long has this update been running", not "when
# did it start". palworld-idle.ps1 decides whether to stand down by asking whether the
# handle is still HELD, so this timestamp no longer gates anything; what it feeds is the
# 60-minute "this update looks hung" warning, and a timestamp frozen at acquisition
# would fire that warning on every update that outlives an hour of honest work.
#
# Called at phase boundaries rather than on a timer: a background heartbeat job would
# have to be reaped on every exit path, and getting that wrong risks leaving a thread
# holding the lock after the updater is gone. Phase boundaries cost nothing and cannot
# outlive the process. A single phase can still exceed an hour (SteamCMD on a very large
# patch over a slow link), and the warning is deliberately advisory for that reason: it
# says look, it does not act.
function Update-LockHeartbeat {
  if (-not $script:lockHandle) { return }
  try {
    # A SIDECAR file, not the lock itself. Stamping the lock's own LastWriteTime needs a
    # second write handle, and this process holds it with FileShare::Read, which excludes
    # exactly that - so the attempt raised a sharing violation on EVERY successful
    # heartbeat, printed a failure warning each time, and never moved the timestamp it
    # existed to move. A separate file has no such contention: opened, written, closed.
    [IO.File]::WriteAllText($heartbeatFile, (Get-Date).ToString("o"))
  } catch {
    # Best-effort by design. A failed heartbeat costs a possibly-early advisory warning
    # from the idle script; throwing here would abort a running update, which is worse.
    Write-Output "WARNING: update.lock heartbeat failed: $($_.Exception.Message)"
  }
}

$watchdogDisabled = $false
$modOk = $null       # $null = not checked; $true/$false = FILES verified after re-stage
$modRuntime = $null  # 'ok'/'failed'/'unknown' - what the mod said about itself once up
$relaunchAtUtc = $null # marks which UE4SS.log lines belong to THIS run's relaunch
$oldVersion = $null  # the build we were on BEFORE this run; step 6 compares against it
$steamFailed = $false
try {
  Send-Notify "🔧 **$label**: updating to the latest Steam build (mods: ``$Mods``). Players will drop for a few minutes."

  # --- 0. record the build we are ON, so step 6 can prove the update landed ----
  # Without this, "the server answered /info" is the only evidence of success, and
  # that is equally true of an update that never ran. The before/after comparison is
  # what turns liveness into proof.
  try {
    $oldInfo = Invoke-RestMethod -Uri "$restBase/info" -Credential $cred -TimeoutSec 5 -ErrorAction Stop
    if ($oldInfo) { $oldVersion = $oldInfo.version }
  } catch { }

  Update-LockHeartbeat
  # --- 1. force-save and PROVE it reached disk (200 on /save is not proof) -----
  if (Get-Process -Name $shipping -ErrorAction SilentlyContinue) {
    $before = (Get-LatestLevelSav).LastWriteTimeUtc
    try {
      Invoke-RestMethod -Uri "$restBase/save" -Method Post -Credential $cred `
        -Headers @{ "Content-Length" = "0" } -TimeoutSec 20 | Out-Null
    } catch {
      Send-Notify "⚠️ **$label**: force-save request failed ($($_.Exception.Message)). Continuing - the world is not modified during an update, but flagging it."
    }
    Start-Sleep -Seconds 3
    $after = (Get-LatestLevelSav).LastWriteTimeUtc
    if ($before -and $after -and $after -le $before) {
      Send-Notify "⚠️ **$label**: save did not advance on disk before the update. Continuing (rolling backups exist), but flagging it."
    }
  }

  Update-LockHeartbeat
  # --- 2. fresh pre-update backup (best-effort, LOUD on failure) ---------------
  # backup-to-s3.ps1 does its own save+verify+upload; a build swap deserves a known
  # escape hatch beyond the 30-min rolling backups.
  $backupScript = "C:\PalServer\scripts\backup-to-s3.ps1"
  if (Test-Path $backupScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $backupScript | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Send-Notify "⚠️ **$label**: pre-update backup returned $LASTEXITCODE. Continuing - the 30-min rolling backups still exist."
    }
  }

  Update-LockHeartbeat
  # --- 3. disable the watchdog so it cannot relaunch mid-update ----------------
  # ASK the task what state it is in rather than trusting the cmdlet. PalworldIdle
  # relaunches the server whenever the process is absent, which is exactly what step 4
  # is about to make true, so a disable that silently failed leaves SteamCMD fighting a
  # relaunched, locked binary: the half-patched install that still parses.
  Disable-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue | Out-Null
  # Set BEFORE the check: if the disable half-landed we still owe a re-arm, and the
  # finally block is the only thing that pays it.
  $watchdogDisabled = $true
  # Disable stops FUTURE triggers; a cycle already running keeps going. Wait it out
  # rather than killing it, since an idle run interrupted mid-save is worse than waiting.
  $idleDeadline = (Get-Date).AddSeconds(120)
  while (((Get-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue).State -eq 'Running') -and (Get-Date) -lt $idleDeadline) {
    Start-Sleep -Seconds 5
  }
  $idleState = (Get-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue).State
  if ($idleState -ne 'Disabled') {
    if (-not $idleState) { $idleState = "unknown (task not found)" }
    Send-Notify "❌ **$label**: could not disable the ``PalworldIdle`` watchdog (state: ``$idleState``). ABORTING - continuing would let it relaunch the server into SteamCMD and half-patch the install."
    Remove-UpdateLock
    return
  }

  Update-LockHeartbeat
  # --- 4. graceful stop, then confirm the process is really gone ---------------
  # 60s of warning, not 5: this drops everyone, and AGENTS.md asks for a real announce
  # and wait. The Discord side names who is online before it gets here.
  try {
    $body = @{ waittime = 60; message = "Server updating - back in a few minutes" } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$restBase/shutdown" -Method Post -Credential $cred `
      -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
  } catch { }
  # 180s, not 90: the server now counts down 60 of those before it even begins saving
  # and exiting, so the old budget would have force-killed a server that was behaving.
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Process -Name $shipping -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
  }
  # A graceful /shutdown already saved and left; this only catches a server that
  # ignored it, and only after the wait above - so it is not racing an unsaved world.
  Get-Process -Name $shipping -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

  Update-LockHeartbeat
  # --- 5. update to latest. TWICE: first pass often only self-updates steamcmd --
  if (-not (Test-Path $steamcmd)) {
    Send-Notify "❌ **$label**: steamcmd is missing at ``$steamcmd`` - cannot update. Relaunching the current build."
    Remove-UpdateLock
    return
  }
  $steamExit = $null
  foreach ($pass in 1..2) {
    & $steamcmd +force_install_dir $installDir +login anonymous +app_update $appId validate +quit | Out-Null
    $steamExit = $LASTEXITCODE
  }
  # A non-zero exit on the FINAL pass means app_update did not complete. The old binary
  # is still sitting there, so every later check (Test-Path below, /info answering in
  # step 6) passes - which is exactly how a failed update gets announced as a good one.
  if ($steamExit -ne 0) {
    $steamFailed = $true
    Send-Notify "⚠️ **$label**: steamcmd exited ``$steamExit`` on its final pass - the build probably did NOT change. Relaunching so players get the server back, but do not trust this as an update."
  }

  if (-not (Test-Path $shippingExe)) {
    Send-Notify "❌ **$label**: after the update the server binary is MISSING at ``$shippingExe``. NOT what a good update looks like - check the box."
    Remove-UpdateLock
    return
  }

  Update-LockHeartbeat
  # --- 5b. handle the UE4SS mod layer per -Mods -------------------------------
  # This is a MODDED server. SteamCMD 'validate' re-checks the official depot and can
  # drop the injected UE4SS loader, and a base patch usually outruns the mod builds -
  # so what happens to UE4SS is a deliberate choice, not an afterthought.
  $ue4ssStage = "$saveQualifier\PalServer\ue4ss-stage\Win64"
  $win64 = "C:\PalServer\Pal\Binaries\Win64"
  # dwmapi.dll is the UE4SS proxy loader; without it the game boots pure vanilla. It is
  # NOT a Steam depot file, so 'validate' neither adds nor removes it.
  $loader = "$win64\dwmapi.dll"

  if ($Mods -eq 'vanilla') {
    # Guarantee a JOINABLE box: strip the loader so an old/incompatible UE4SS can't
    # crash-loop the server. Building goes vanilla until a matching build is restaged.
    Remove-Item $loader -Force -ErrorAction SilentlyContinue
    $modOk = $false
  } else {
    if ($Mods -eq 'restage') {
      # Pull a matching UE4SS build onto the D: durable stage FIRST (no RDP needed).
      # Overlay (no --delete): the admin uploads only what changed. ListBucket is on
      # the shared role already; GetObject on ue4ss-stage/* is granted in windows.tf.
      $stageRoot = "$saveQualifier\PalServer\ue4ss-stage"
      # Check the REMOTE has a stage before syncing. An empty or missing prefix makes
      # `s3 sync` exit 0 having transferred nothing, after which the overlay below uses
      # whatever was already on D: and the verification passes on those leftovers - so
      # the report would say the mod loaded and the operator would read that as "restage
      # pulled the matching build" when S3 contributed nothing at all.
      $remoteStage = & $awsExe s3 ls "s3://$($conf.BackupBucket)/ue4ss-stage/Win64/dwmapi.dll" `
        --region $conf.AwsRegion 2>$null
      if (-not $remoteStage) {
        Send-Notify "⚠️ **$label**: ``s3://$($conf.BackupBucket)/ue4ss-stage/`` has no published stage (no ``Win64/dwmapi.dll``), so ``restage`` has nothing to pull. Seed it with ``seed-ue4ss-stage.ps1`` first. Continuing with the build already on D:, which is what ``keep`` would have done."
      } else {
        # --exact-timestamps is LOAD-BEARING, not a tuning flag. Syncing S3 -> local, the
        # AWS CLI ignores same-sized objects unless the LOCAL copy is newer, so a rebuilt
        # DLL that happens to land on the same byte count is silently skipped no matter
        # how much newer S3 is. That is not a corner case for this stage: mod 1898 v1.78
        # is exactly the same size as v1.75 (1270272 bytes), and on 2026-07-30 the restage
        # transferred NOTHING, exited 0, overlaid the year-old DLL, and reported the mod
        # loaded. --exact-timestamps compares the timestamp instead, so a same-size rebuild
        # transfers.
        & $awsExe s3 sync "s3://$($conf.BackupBucket)/ue4ss-stage/" "$stageRoot" `
          --region $conf.AwsRegion --exact-timestamps --only-show-errors
        if ($LASTEXITCODE -ne 0) {
          Send-Notify "⚠️ **$label**: restage sync from ``s3://$($conf.BackupBucket)/ue4ss-stage/`` failed (aws exit $LASTEXITCODE). Falling back to the build already on D:."
        }
      }
    }
    # keep / restage: re-overlay D: -> Win64, the SAME robocopy the bootstrap does,
    # then VERIFY every load-bearing file so the report reflects reality, not hope.
    if (Test-Path "$ue4ssStage\ue4ss\UE4SS.dll") {
      robocopy "$ue4ssStage" "$win64" /E /R:2 /W:2 | Out-Null    # /E overlay, NEVER /MIR
      if ($LASTEXITCODE -lt 8) {                                  # robocopy 0-7 = success
        $modDir = "$win64\ue4ss\Mods\BuildingRestrictionsDisabler"
        $modsTxt = "$win64\ue4ss\Mods\mods.txt"
        $enableLine = (Test-Path $modsTxt) -and `
          (Select-String -Path $modsTxt -Pattern 'BuildingRestrictionsDisabler\s*:\s*1' -Quiet)
        $modOk = (Test-Path $loader) -and `
                 (Test-Path "$win64\ue4ss\UE4SS.dll") -and `
                 (Test-Path "$modDir\dlls\main.dll") -and `
                 (Test-Path "$modDir\enabled.txt") -and `
                 $enableLine
      } else {
        $modOk = $false
      }
    } else {
      $modOk = $false
    }
    # Verification failed, so make the state MATCH what the report is about to say.
    # Leaving the loader in place here would leave the PREVIOUS UE4SS overlaid against a
    # freshly patched engine (validate does not remove it - it is not a depot file),
    # which is the crash-loop case, while the report claimed the box was vanilla.
    # Stripping the loader makes "vanilla" true and guarantees a joinable server.
    if (-not $modOk) {
      Remove-Item $loader -Force -ErrorAction SilentlyContinue
    }
  }
}
catch {
  # Without this the script dies here having sent only the opening "updating" notice.
  # finally still re-arms and relaunches, but nobody is ever told the update failed,
  # and silence is indistinguishable from an update still in progress.
  Send-Notify "❌ **$label**: the update threw before finishing ($($_.Exception.Message)). Re-arming the watchdog and relaunching - check the SSM command output."
}
finally {
  # Re-arm the watchdog no matter how we exit, THEN relaunch through the launcher.
  # The launcher restores the staged GameUserSettings.ini (the world GUID) and starts
  # the shipping exe. It does NOT re-overlay UE4SS: that is this script's job, and
  # mods:vanilla only stays vanilla because the launcher leaves the loader alone.
  if ($watchdogDisabled) {
    Enable-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue | Out-Null
    # A failed re-arm is the expensive silence: no crash-restart and no idle-shutdown,
    # on a box that bills by the hour until a human happens to look at it.
    $reArmed = (Get-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue).State
    if ((-not $reArmed) -or $reArmed -eq 'Disabled') {
      if (-not $reArmed) { $reArmed = "unknown (task not found)" }
      Send-Notify "❌ **$label**: FAILED to re-arm the ``PalworldIdle`` watchdog (state: ``$reArmed``). There is now no auto-restart and no idle shutdown - re-enable it by hand."
    }
  }
  # Stamped BEFORE the launch so no startup line can be missed, and rounded down to the
  # second because UE4SS.log timestamps parse at second precision.
  $relaunchAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-1)
  Start-ScheduledTask -TaskName "PalworldLaunch" -ErrorAction SilentlyContinue
}

# --- 6. verify on the box: ASK the server its version; don't trust exit codes --
$version = $null
$deadline = (Get-Date).AddSeconds(150)
while ((Get-Date) -lt $deadline) {
  try {
    $info = Invoke-RestMethod -Uri "$restBase/info" -Credential $cred -TimeoutSec 5 -ErrorAction Stop
    if ($info -and $info.version) { $version = $info.version; break }
  } catch { }
  Start-Sleep -Seconds 5
}

# /info already returns the version WITH its leading "v" (e.g. "v1.0.2.101103"), so the
# "v$version" in the messages below rendered as "vv1.0.2.101103" on every report. Trim it
# once here rather than touching four strings.
if ($version) { $version = $version -replace '^v', '' }
if ($oldVersion) { $oldVersion = $oldVersion -replace '^v', '' }

if ($version) {
  # The files passed, so now ask the MOD whether it actually hooked. This runs only on
  # the keep/restage path (vanilla has no mod to check) and only when the file checks
  # already passed, because a failed overlay has stripped the loader and there is
  # nothing loaded to report on. The mod prints its verdict during startup, but /info
  # can answer first, so poll rather than reading once and trusting a race.
  if ($Mods -ne 'vanilla' -and $modOk -and $relaunchAtUtc) {
    $modDeadline = (Get-Date).AddSeconds(60)
    do {
      $modRuntime = Test-ModRuntimeStatus $relaunchAtUtc
      if ($modRuntime -ne 'unknown') { break }
      Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $modDeadline)
  }

  if ($Mods -eq 'vanilla') {
    $modNote = "Running **vanilla** (UE4SS disabled) - the box is joinable but illegal builds are rejected. Re-enable relaxed building with ``/palworld-update mods:restage`` once a matching UE4SS + mod 1898 build is on S3."
  } elseif ($modOk -and $modRuntime -eq 'failed') {
    # The loader is deliberately LEFT IN PLACE here, unlike the file-check failure below.
    # A mod that cannot find its pattern no-ops; it does not crash the server (observed
    # 2026-07-30: the box ran fine for a day this way), so there is nothing to rescue by
    # stripping it - and stripping a DLL the live process holds open would fail anyway.
    # The defect this closes is the false green, so the fix is an honest report.
    $modNote = "⚠️ the building mod LOADED but is NOT working: it logged ``Version pattern not found`` against this build, so it cannot hook and **building is effectively VANILLA**. The 1898 build needs to be re-matched to the new game version - stage it and run ``/palworld-update mods:restage``."
  } elseif ($modOk -and $modRuntime -eq 'ok') {
    $modNote = "Relaxed-building mod loaded ✅ and verified working against this build - players need the matching client-side UE4SS + mod 1898."
  } elseif ($modOk) {
    # 'unknown': the files are right and nothing said it failed, but nothing confirmed it
    # worked either. Saying that plainly is the point - silence is not an all-clear.
    $modNote = "❔ the building mod's files verified, but its runtime status could NOT be read from ``UE4SS.log`` (no matching lines after relaunch). Do not assume relaxed building works - check by placing an illegal build."
  } else {
    # The loader was stripped above, so this claim is now true rather than hopeful.
    $modNote = "⚠️ the building mod did NOT verify, so UE4SS was disabled to keep the box joinable. Building is VANILLA (illegal builds rejected) until a matching UE4SS + mod 1898 build is staged (``/palworld-update mods:restage``) or D: is updated and this is re-run."
  }
  # "The server answered /info" proves it is UP, not that the build moved. Announcing
  # "updated" on an unchanged version is the silent success this script exists to avoid,
  # so the three outcomes get three different words.
  if ($steamFailed) {
    Send-Notify "⚠️ **$label** is back up on **v$version**, but steamcmd FAILED - treat the build as NOT updated. $modNote Join at ``$($conf.ServerAddress)``."
  } elseif ($oldVersion -and $version -eq $oldVersion) {
    Send-Notify "ℹ️ **$label** is back up and STILL on **v$version** (unchanged). Either it was already current or the update did not land - check the SSM command output before assuming players can join. $modNote"
  } else {
    $fromNote = if ($oldVersion) { " (was **v$oldVersion**)" } else { " (previous version unknown - ``/info`` did not answer before the update)" }
    Send-Notify "✅ **$label** is updated and back up - now on **v$version**$fromNote. $modNote Join at ``$($conf.ServerAddress)``."
  }
} else {
  # No /info after the window. On a modded box the usual cause is a UE4SS build that
  # is incompatible with the new engine crash-looping the server (see the mod docs).
  Send-Notify "⚠️ **$label**: updated the build, but the server has not answered ``/info`` yet. If it stays down after a game patch, the staged UE4SS is probably incompatible with the new version and is crashing the server - update the ``$saveQualifier\PalServer\ue4ss-stage`` build (or clear UE4SS to boot vanilla) and re-run. Check the box."
}

# The lock is released HERE, not in the finally above, so it covers the verification
# window too. Releasing it earlier would let a second /palworld-update start while this
# one is still waiting up to 150s for /info, and stop the server it had just relaunched.
Remove-UpdateLock
