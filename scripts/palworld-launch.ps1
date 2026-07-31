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

  Start-Process -FilePath $exe `
    -ArgumentList "Pal", "-port=$($conf.GamePort)", "-players=$($conf.MaxPlayers)", "-log" `
    -WorkingDirectory "C:\PalServer" -WindowStyle Hidden

  # Do not release the lock until the process is VISIBLE to Get-Process. Releasing on
  # the strength of Start-Process returning would let the next racer through while the
  # guard above still sees nothing, which is the whole bug wearing a lock.
  for ($waited = 0; $waited -lt 20; $waited++) {
    if (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue) { return 0 }
    Start-Sleep -Milliseconds 500
  }
  # 10s and still nothing: either the exe died on startup or it never launched. Either
  # way, saying nothing here would report a successful launch of a server that is not
  # there, and the next watchdog cycle would silently try again forever.
  Write-EventLog -LogName Application -Source "Palworld" -EventId 110 -EntryType Error `
    -Message "launched $exe but no PalServer-Win64-Shipping process appeared within 10s" -ErrorAction SilentlyContinue
  Write-Output "ERROR: server process did not appear within 10s of launch"
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
  } else {
    # Not an error: the holder is starting the server right now, which is the end state
    # this invocation wanted. Exiting non-zero would make the watchdog cry wolf.
    Write-Output "another launcher holds the start lock; leaving the start to it"
  }
} finally {
  if ($holdsMutex) { $launchMutex.ReleaseMutex() }
  $launchMutex.Dispose()
}
exit $exitCode
