# Palworld Windows launcher + watchdog.
#
# Invoked at boot (Scheduled Task, SYSTEM) and again every 2 min by the idle task,
# which doubles as the watchdog: if the process is gone, this restarts it.
#
# Why not NSSM: its stop is a console-close/terminate, which Pocketpair has said is
# NOT guaranteed to trigger a world save — so the clean-shutdown path has to call the
# REST API first regardless (see palworld-idle.ps1). With that in place NSSM adds an
# external binary and a second supervisor without buying a safe stop.
#
# Why the Shipping exe and not PalServer.exe: the wrapper hangs in session 0 (no
# interactive desktop) and never spawns its child, so a boot-time launch through it
# silently yields a running-but-dead server. Verified 2026-07-18.

$ErrorActionPreference = "Continue"
$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$stateDir = "C:\PalServer\state"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# Per-boot state reset. Linux gets this free from /run (tmpfs); Windows needs it
# explicit, keyed on boot time, so a fresh boot restarts the idle clock and re-announces.
$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$bootStamp = Join-Path $stateDir "boot_stamp"
$recordedBoot = if (Test-Path $bootStamp) { Get-Content $bootStamp -Raw } else { "" }
if ($recordedBoot.Trim() -ne $bootTime.ToString("o")) {
  Get-ChildItem $stateDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
  Set-Content -Path $bootStamp -Value $bootTime.ToString("o")
}

# Self-heal a watchdog that was left disabled. update-server.ps1 disables PalworldIdle
# for the duration of an update and re-arms it in a finally{}, but a finally does not run
# if the process is killed outright (host reboot mid-update, SSM agent kill, execution
# timeout) - and a disabled scheduled task SURVIVES the reboot. The result is a box with
# no crash-restart and no idle-shutdown, billing hourly, with nothing anywhere saying so.
# This runs -AtStartup, which is precisely the path a killed update comes back through.
#
# Skipped while an update genuinely holds the lock, so this cannot undo a deliberate
# disable; the 30-min ceiling matches the updater's own staleness rule.
$updateLock = Join-Path $stateDir "update.lock"
$updateLive = $false
if (Test-Path $updateLock) {
  $updateLive = ((Get-Date) - (Get-Item $updateLock).LastWriteTime).TotalMinutes -lt 30
}
if (-not $updateLive) {
  $idleTask = Get-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue
  if ($idleTask -and $idleTask.State -eq 'Disabled') {
    Enable-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue | Out-Null
    $nowState = (Get-ScheduledTask -TaskName "PalworldIdle" -ErrorAction SilentlyContinue).State
    # Say which way it went. "Tried to re-arm the watchdog" is not the same claim as
    # "the watchdog is armed", and only the second one is worth anything here.
    if ($nowState -eq 'Disabled') {
      Write-EventLog -LogName Application -Source "Palworld" -EventId 106 -EntryType Error `
        -Message "PalworldIdle was disabled at startup and could NOT be re-enabled - no watchdog, no idle shutdown" -ErrorAction SilentlyContinue
      Write-Output "ERROR: PalworldIdle stuck disabled - no watchdog, no idle shutdown"
    } else {
      Write-EventLog -LogName Application -Source "Palworld" -EventId 106 -EntryType Warning `
        -Message "PalworldIdle was found disabled at startup (likely a killed update) and has been re-enabled" -ErrorAction SilentlyContinue
      Write-Output "re-armed PalworldIdle (was disabled, likely a killed update)"
    }
  }
}

# Returns an exit code, and writes NOTHING to the success stream. A PowerShell function's
# return value is its ENTIRE output stream, so one stray Write-Output here makes the
# caller's $exitCode an Object[], and `exit` on a non-integer silently becomes 0. Measured
# on the box 2026-07-31: the contaminated form exited 0, the clean form exited 1 - i.e. a
# failed launch would have reported success to the very watchdog meant to catch it.
# Diagnostics go to the event log; the CALLER prints the human-readable line.
#
# Event IDs in use across this repo: 101-110 are taken (107 by windows_user_data.ps1.tftpl,
# 110 by backup-to-s3.ps1, 106 shared). New IDs here start at 111. Check before reusing -
# a collision makes the one signal you grep during an outage ambiguous.
function Start-ServerIfAbsent {
  if (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue) {
    return 0
  }

  $exe = "C:\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe"
  if (-not (Test-Path $exe)) {
    Write-EventLog -LogName Application -Source "Palworld" -EventId 101 -EntryType Error `
      -Message "PalServer shipping exe missing at $exe" -ErrorAction SilentlyContinue
    return 1
  }

  # Load the REAL world, not a fresh empty one. Palworld picks the world by the
  # DedicatedServerName GUID in GameUserSettings.ini, which lives on C: (NOT the D:
  # SaveGames junction) - so a rebuilt box generates a new GUID and serves an EMPTY world
  # while the real save sits untouched on D:. Restore the staged copy (carrying the world
  # GUID) from the persistent volume before every launch. Done here, not in user_data,
  # because user_data has a hard 16 KB limit and this runs before the server every boot.
  $gusStage = "D:\PalServer\GameUserSettings.ini"
  $cfgDir = "C:\PalServer\Pal\Saved\Config\WindowsServer"
  if (Test-Path $gusStage) {
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    Copy-Item $gusStage (Join-Path $cfgDir "GameUserSettings.ini") -Force
  } else {
    # Loud: without the GUID the server silently serves an empty world (real save intact
    # on D:, just not selected). Distinct EventId so a rebuild-into-empty is diagnosable.
    Write-EventLog -LogName Application -Source "Palworld" -EventId 109 -EntryType Warning `
      -Message "no staged GameUserSettings.ini at $gusStage; server may serve an EMPTY world (fresh GUID)" -ErrorAction SilentlyContinue
  }

  # Restore pak mods from the persistent volume, same reasoning as GameUserSettings.ini
  # above: C: is rebuilt on every instance replacement, D: is not. A pak in ~mods is NOT
  # covered by the UE4SS stage (that overlays Win64 only), so without this a rebuild comes
  # up with the pak mods silently absent - the server boots fine and reports healthy, and
  # the only symptom is a mod that quietly stopped existing.
  #
  # D: is the master, copied only on a hash mismatch. This runs on the absent-server path
  # only (the guard at the top of this function returns early when it is up), so there is
  # no contention with the running server, which holds a mounted pak open and locked -
  # verified 2026-08-08, a delete of the live pak was refused while the server ran. The
  # consequence worth knowing: staging a NEW version of a pak takes effect at the next
  # restart, not immediately.
  #
  # An empty or missing stage is NOT an error - a box legitimately running no pak mods
  # must not log a fault on every launch. Failing to restore one that IS staged is.
  $pakStage = "D:\PalServer\paks-stage"
  $pakLive = "C:\PalServer\Pal\Content\Paks\~mods"
  $stagedPaks = Get-ChildItem $pakStage -Filter *.pak -ErrorAction SilentlyContinue
  if ($stagedPaks) {
    New-Item -ItemType Directory -Force -Path $pakLive | Out-Null
    foreach ($stagedPak in $stagedPaks) {
      $target = Join-Path $pakLive $stagedPak.Name
      $stageHash = (Get-FileHash $stagedPak.FullName -Algorithm SHA256).Hash
      $liveHash = if (Test-Path $target) { (Get-FileHash $target -Algorithm SHA256).Hash } else { $null }
      if ($liveHash -eq $stageHash) { continue }
      Copy-Item $stagedPak.FullName $target -Force -ErrorAction SilentlyContinue
      # Verify the copy rather than trusting Copy-Item: a truncated or absent pak leaves
      # the server perfectly joinable with the mod missing, which is the failure this
      # whole block exists to prevent and the one nobody would notice.
      $afterHash = if (Test-Path $target) { (Get-FileHash $target -Algorithm SHA256).Hash } else { $null }
      if ($afterHash -eq $stageHash) {
        Write-EventLog -LogName Application -Source "Palworld" -EventId 115 -EntryType Information `
          -Message "restored pak mod $($stagedPak.Name) from $pakStage" -ErrorAction SilentlyContinue
      } else {
        Write-EventLog -LogName Application -Source "Palworld" -EventId 115 -EntryType Error `
          -Message "FAILED to restore pak mod $($stagedPak.Name) from $pakStage - server will run WITHOUT it" -ErrorAction SilentlyContinue
      }
    }
  }

  $started = Start-Process -FilePath $exe `
    -ArgumentList "Pal", "-port=$($conf.GamePort)", "-players=$($conf.MaxPlayers)", "-log" `
    -WorkingDirectory "C:\PalServer" -WindowStyle Hidden -PassThru
  if (-not $started) {
    Write-EventLog -LogName Application -Source "Palworld" -EventId 112 -EntryType Error `
      -Message "Start-Process returned no process object for $exe" -ErrorAction SilentlyContinue
    return 1
  }

  # Do not release the lock until the process is VISIBLE to Get-Process. Releasing on
  # the strength of Start-Process returning would let the next racer through while the
  # guard above still sees nothing, which is the whole bug wearing a lock. Track the PID
  # we actually started (-PassThru) rather than any process of that name, so the wait is
  # tied to THIS attempt and an instant death is distinguishable from a slow appearance.
  for ($waited = 0; $waited -lt 20; $waited++) {
    if ($started.HasExited) {
      Write-EventLog -LogName Application -Source "Palworld" -EventId 112 -EntryType Error `
        -Message "PalServer pid $($started.Id) exited within 10s of launch (exit code $($started.ExitCode))" -ErrorAction SilentlyContinue
      return 1
    }
    if (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue) { return 0 }
    Start-Sleep -Milliseconds 500
  }
  # 10s and still not visible under the name the guard checks. Kill the half-start BEFORE
  # releasing the lock: leaving it alive is how the next launcher adds a second server on
  # top of a hung one, which is the exact condition this file exists to prevent.
  Write-EventLog -LogName Application -Source "Palworld" -EventId 112 -EntryType Error `
    -Message "launched $exe but no PalServer-Win64-Shipping process appeared within 10s; killing pid $($started.Id)" -ErrorAction SilentlyContinue
  Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
  return 1
}

# Two separate things start the server: this script's -AtStartup task, and the watchdog in
# palworld-idle.ps1, which shells out to this same file every 2 min. The Get-Process guard
# is a check-then-start with nothing holding the halves together, so both can see an absent
# server at the same instant and both start one. That is what happened on 2026-07-31: PIDs
# 4856 and 4864, eight apart, ran side by side until commit (RAM + pagefile) was exhausted
# and the server died under five players. MultipleInstances=IgnoreNew on the tasks does not
# help - it stops a task overlapping ITSELF, not two different tasks racing each other.
#
# Global\ because the racers are separate processes; a session-local mutex would not see
# across them, which is the failure mode that looks exactly like having no lock at all.
$launchMutex = New-Object System.Threading.Mutex($false, "Global\PalworldLaunch")
$holdsMutex = $false
$exitCode = 0
try {
  try {
    $holdsMutex = $launchMutex.WaitOne(30000)
  } catch [System.Threading.AbandonedMutexException] {
    # A previous holder died between acquiring and releasing (killed update, host reset).
    # The mutex is ours now; the Get-Process check decides whether a start is still needed.
    $holdsMutex = $true
  }
  if ($holdsMutex) {
    $exitCode = Start-ServerIfAbsent
    if ($exitCode -ne 0) {
      Write-Output "ERROR: could not start the server - see the Application log, source Palworld"
    }
  } else {
    # A 30s wait means the holder is STUCK, not merely busy: a healthy start is bounded by
    # the 10s visibility poll above. Reporting 0 on that assumption is the silent-success
    # bug - the watchdog would read "fine" every 2 min while the server stayed down. So
    # check the end state we are claiming, and only claim it if it is true.
    if (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue) {
      Write-Output "another launcher holds the start lock; the server is running"
    } else {
      Write-EventLog -LogName Application -Source "Palworld" -EventId 113 -EntryType Error `
        -Message "timed out after 30s waiting for the start lock and no server is running - the lock holder is stuck" -ErrorAction SilentlyContinue
      Write-Output "ERROR: waited 30s for the start lock and the server is still down"
      $exitCode = 1
    }
  }
} finally {
  # Dispose even if ReleaseMutex throws (wrong owner, bad state); otherwise the handle
  # leaks and the throw escapes with the mutex still open.
  try {
    if ($holdsMutex) { $launchMutex.ReleaseMutex() }
  } finally {
    $launchMutex.Dispose()
  }
}
exit $exitCode
