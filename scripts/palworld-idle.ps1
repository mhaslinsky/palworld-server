# Palworld idle-shutdown watcher + Discord notifier + roster publisher (Windows).
#
# PowerShell port of scripts/idle-shutdown.sh. Runs on a Scheduled Task every 2 min
# as SYSTEM. Same contract as the Linux original:
#   - publishes the roster to SSM (so /palworld-status reads it without 8212 ever
#     leaving localhost),
#   - announces "server up" once per boot,
#   - warns WarnBeforeMin before shutdown,
#   - stops the box after ThresholdMin minutes of zero players.
#
# Fail-safe, as on Linux: any error reaching or parsing the API counts as "players
# present", so a transient blip never stops a live server.
#
# Windows-specific deltas from the bash version:
#  - State lives in C:\PalServer\state and is cleared by palworld-launch.ps1 on a new
#    boot (no tmpfs equivalent).
#  - Shutdown does a REST save + graceful /shutdown FIRST and waits for the process to
#    exit before Stop-Computer. Pocketpair has stated SIGTERM/console-close is not
#    reliably a graceful save, so killing the box without this risks the world.

$ErrorActionPreference = "Continue"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$stateDir = "C:\PalServer\state"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$idleSince = Join-Path $stateDir "idle_since"
$warned = Join-Path $stateDir "warned"
$announcedUp = Join-Path $stateDir "announced_up"

$now = [int][double]::Parse((Get-Date -UFormat %s))
$restBase = "http://127.0.0.1:$($conf.RestPort)/v1/api"
$secure = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("admin", $secure)

function Get-WebhookUrl {
  if (-not $conf.WebhookParam) { return $null }
  try {
    $value = & aws ssm get-parameter --name $conf.WebhookParam --with-decryption `
      --region $conf.AwsRegion --query 'Parameter.Value' --output text 2>$null
    # An unset SSM parameter comes back as the literal string "None".
    if ($value -and $value.Trim() -ne "None") { return $value.Trim() }
  } catch { }
  return $null
}

function Send-Notify([string]$content) {
  $url = Get-WebhookUrl
  if (-not $url) { return }
  try {
    $body = @{ content = $content } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' `
      -Body $body -TimeoutSec 5 | Out-Null
  } catch { }
}

# --- Poll --------------------------------------------------------------------
$players = $null
try {
  $players = Invoke-RestMethod -Uri "$restBase/players" -Credential $cred `
    -TimeoutSec 5 -ErrorAction Stop
} catch {
  Remove-Item $idleSince -Force -ErrorAction SilentlyContinue  # unreachable -> assume active
  exit 0
}
if ($null -eq $players -or $null -eq $players.players) {
  Remove-Item $idleSince -Force -ErrorAction SilentlyContinue  # unparseable -> assume active
  exit 0
}

$count = @($players.players).Count
$names = (@($players.players) | ForEach-Object { $_.name }) -join ", "

# --- Publish the roster (best-effort; never blocks shutdown logic) ------------
# The value goes through a FILE, not an argument: passing the JSON inline strips every
# quote on the way through cmd.exe, publishing `{count:0,names:}` — invalid JSON that
# makes the Discord bot's JSON.parse throw. Verified broken that way on 2026-07-18.
if ($conf.RosterParam) {
  try {
    $roster = @{ count = $count; names = $names; updated = $now } | ConvertTo-Json -Compress
    $rosterFile = Join-Path $stateDir "roster.json"
    [IO.File]::WriteAllText($rosterFile, $roster, (New-Object Text.UTF8Encoding($false)))
    & aws ssm put-parameter --name $conf.RosterParam --type String --overwrite `
      --value "file://$rosterFile" --region $conf.AwsRegion 2>$null | Out-Null
  } catch { }
}

# --- Announce "up" once per boot ---------------------------------------------
# The REST API answering is a truer readiness signal than "the process exists".
if (-not (Test-Path $announcedUp)) {
  New-Item -ItemType File -Path $announcedUp -Force | Out-Null
  Send-Notify "🟢 **$($conf.ServerLabel)** is up — join at ``$($conf.ServerAddress)``"
}

# --- Players online: reset the clock -----------------------------------------
if ($count -gt 0) {
  Remove-Item $idleSince, $warned -Force -ErrorAction SilentlyContinue
  exit 0
}

# --- Zero players -------------------------------------------------------------
if (-not (Test-Path $idleSince)) {
  Set-Content -Path $idleSince -Value $now
  exit 0
}

$since = [int](Get-Content $idleSince -Raw).Trim()
$elapsedMin = [math]::Floor(($now - $since) / 60)
$warnAtMin = $conf.ThresholdMin - $conf.WarnBeforeMin

if ($elapsedMin -ge $conf.ThresholdMin) {
  Send-Notify "🛑 **$($conf.ServerLabel)** has been empty for $($conf.ThresholdMin) min — shutting down to save money. Start it again with ``/palworld-start``."

  # Clean-shutdown sequence (BLOCKER 5): save -> verify -> graceful stop -> wait ->
  # only then power off. Content-Length:0 avoids the documented HTTP 411 on /save.
  try {
    Invoke-RestMethod -Uri "$restBase/save" -Method Post -Credential $cred `
      -Headers @{ "Content-Length" = "0" } -TimeoutSec 30 -ErrorAction Stop | Out-Null
  } catch { }
  try {
    $body = @{ waittime = 5; message = "Idle shutdown" } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$restBase/shutdown" -Method Post -Credential $cred `
      -ContentType 'application/json' -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
  } catch { }

  # Wait for the process to exit on its own; only force after a grace period, since a
  # forced kill is exactly what risks an unsaved world.
  for ($waited = 0; $waited -lt 90; $waited += 5) {
    if (-not (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 5
  }
  Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue | Stop-Process -Force

  # instance_initiated_shutdown_behavior = "stop" turns this into an EC2 stop, which
  # halts compute billing while the save volume persists.
  Stop-Computer -Force
  exit 0
}

if ($elapsedMin -ge $warnAtMin -and -not (Test-Path $warned)) {
  New-Item -ItemType File -Path $warned -Force | Out-Null
  $remaining = $conf.ThresholdMin - $elapsedMin
  Send-Notify "⏰ **$($conf.ServerLabel)** is empty — shutting down in about $remaining min. Join now to keep it alive."
}
