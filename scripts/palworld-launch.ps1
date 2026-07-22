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

if (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue) {
  exit 0
}

$exe = "C:\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe"
if (-not (Test-Path $exe)) {
  Write-EventLog -LogName Application -Source "Palworld" -EventId 101 -EntryType Error `
    -Message "PalServer shipping exe missing at $exe" -ErrorAction SilentlyContinue
  exit 1
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
