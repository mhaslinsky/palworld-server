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

# Watchdog. The launcher's only other trigger is -AtStartup, so without this a
# crashed PalServer would stay dead until the next reboot. (An earlier version of
# this file CLAIMED the idle task did this and did not - a comment describing
# behaviour that does not exist is worse than no comment.)
if (-not (Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue)) {
  $launcher = "C:\PalServer\scripts\palworld-launch.ps1"
  # The launcher is fetched from S3 at boot and that fetch is allowed to fail
  # (loudly, but non-fatally). If it is missing, invoking it would do nothing and
  # this task would keep returning 0 forever while the server stayed down.
  if (-not (Test-Path $launcher)) {
    Write-EventLog -LogName Application -Source "Palworld" -EventId 104 -EntryType Error `
      -Message "watchdog: launcher missing at $launcher - server cannot be restarted" -ErrorAction SilentlyContinue
    Write-Output "ERROR: launcher missing at $launcher"
    exit 1
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
  if ($LASTEXITCODE -ne 0) {
    # Returning 0 here would report a healthy watchdog run while the server is
    # still down - the failure would only ever be visible to someone who thought
    # to look at the box.
    Write-EventLog -LogName Application -Source "Palworld" -EventId 105 -EntryType Error `
      -Message "watchdog: launcher exited $LASTEXITCODE - server did not start" -ErrorAction SilentlyContinue
    Write-Output "ERROR: launcher exited $LASTEXITCODE"
    exit 1
  }
  # Nothing to poll this cycle; the next run in 2 min sees the started server.
  exit 0
}
$secure = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("admin", $secure)

# Absolute path, NOT bare "aws": the CLI is not on PATH in the Scheduled Task's
# SYSTEM context, so `& aws ...` resolved to nothing and every SSM call failed
# silently inside its catch block - the roster simply never published and nothing
# said so. Verified on the box 2026-07-18.
$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}

function Get-WebhookUrl {
  if (-not $conf.WebhookParam) { return $null }
  try {
    $value = & $awsExe ssm get-parameter --name $conf.WebhookParam --with-decryption `
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
    & $awsExe ssm put-parameter --name $conf.RosterParam --type String --overwrite `
      --value "file://$rosterFile" --region $conf.AwsRegion 2>$null | Out-Null
    # Best-effort is fine; SILENT best-effort is not. A publish that never lands
    # makes /palworld-status quietly report a stale roster forever.
    if ($LASTEXITCODE -ne 0) {
      Write-EventLog -LogName Application -Source "Palworld" -EventId 103 -EntryType Warning `
        -Message "roster publish to $($conf.RosterParam) failed (aws exit $LASTEXITCODE)" -ErrorAction SilentlyContinue
      Write-Output "WARNING: roster publish failed (aws exit $LASTEXITCODE)"
    }
  } catch {
    Write-Output "WARNING: roster publish threw: $($_.Exception.Message)"
  }
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

  # Clean-shutdown sequence (BLOCKER 5): save -> VERIFY -> graceful stop -> wait for
  # exit -> only then power off. Content-Length:0 avoids the documented HTTP 411.
  #
  # The verification is the point. Pocketpair have said a console-close/terminate is
  # not reliably a graceful save, so powering off after an unverified save is how a
  # world gets lost quietly. An HTTP 200 is not proof either: what proves the world
  # reached disk is Level.sav's mtime advancing. If it did not, this REFUSES to shut
  # down and says so - an idle box costing a few cents an hour is strictly cheaper
  # than an unsaved world, and a failure that keeps running gets noticed.
  # Locate Level.sav FIRST and treat its absence as a hard stop.
  #
  # A missing Level.sav here means the save volume is not mounted or is mapped
  # wrong - precisely the degraded-storage case where powering off is most
  # dangerous. An earlier version checked `$saveOk -and $levelSav` with an
  # `elseif (-not $saveOk)`, so the combination "save returned 200 but no
  # Level.sav found" matched NEITHER branch and fell straight through to
  # Stop-Computer. The guard skipped itself in the one case it existed for.
  $levelSav = Get-ChildItem "$($conf.SaveRoot)\*\*\Level.sav" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $levelSav) {
    Send-Notify "⚠️ **$($conf.ServerLabel)**: no Level.sav under ``$($conf.SaveRoot)`` - the save volume may be unmounted. REFUSING to shut down; an idle box is cheaper than a lost world."
    exit 1
  }
  $mtimeBefore = $levelSav.LastWriteTimeUtc

  try {
    Invoke-RestMethod -Uri "$restBase/save" -Method Post -Credential $cred `
      -Headers @{ "Content-Length" = "0" } -TimeoutSec 30 -ErrorAction Stop | Out-Null
  } catch {
    Send-Notify "⚠️ **$($conf.ServerLabel)**: force-save FAILED before idle shutdown ($($_.Exception.Message)). Staying up rather than risking an unsaved world."
    exit 1
  }

  # An HTTP 200 is not proof the world reached disk - the mtime advancing is.
  Start-Sleep -Seconds 5
  $after = (Get-Item $levelSav.FullName -ErrorAction SilentlyContinue).LastWriteTimeUtc
  if ($null -eq $after -or $after -le $mtimeBefore) {
    Send-Notify "⚠️ **$($conf.ServerLabel)**: save reported success but Level.sav did not change on disk. Staying up - shutting down now could lose the world."
    exit 1
  }

  try {
    $body = @{ waittime = 5; message = "Idle shutdown" } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$restBase/shutdown" -Method Post -Credential $cred `
      -ContentType 'application/json' -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
  } catch {
    # Non-fatal: the save is already verified on disk, so a failed graceful-stop
    # request only costs us a hard kill below, not the world.
    Send-Notify "⚠️ **$($conf.ServerLabel)**: graceful /shutdown request failed; stopping the process directly (world already saved)."
  }

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
