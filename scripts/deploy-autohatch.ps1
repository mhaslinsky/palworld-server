# Deploy the repo's AutoHatchFix Lua to the box and enable it. Run on the box via SSM Run
# Command (no RDP), fetching itself and the Lua from S3:
#
#   $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
#   $b = (Get-Content C:\PalServer\idle.conf.json -Raw | ConvertFrom-Json).BackupBucket
#   & $aws s3 cp "s3://$b/scripts/windows/deploy-autohatch.ps1" C:\PalServer\scripts\deploy-autohatch.ps1 --only-show-errors
#   & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PalServer\scripts\deploy-autohatch.ps1 -ExpectedSha256 <sha>
#
# This targets AutoHatchFix, not the original AutoHatch mod. The original's Lua must stay
# DISABLED on this server (its pak is enabled and driven as machinery by AutoHatchFix; its
# own shared-context sweep is the "everyone's Pals go to whoever hatched first" bug
# AutoHatchFix replaces), so this script never touches the original's enabled.txt.
#
# It REFUSES while anyone is online, and refuses just as hard when it cannot tell. A
# running server whose REST API does not answer is an unknown roster, not an empty one;
# the last time a script reported an unconfirmed roster instead of refusing, it dropped
# two players mid-session.
#
# Every rename is CHECKED rather than announced. An earlier disable script printed
# "disabled" after a Move-Item failed against a pak locked by the running server
# (AGENTS.md rule 8).
#
# Pure ASCII with a UTF-8 BOM, like its siblings.

param(
  [Parameter(Mandatory = $true)][string]$ExpectedSha256,
  [switch]$VanillaOnly
)

$ErrorActionPreference = "Stop"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$bucket = $conf.BackupBucket
$region = $conf.AwsRegion
$saveQualifier = Split-Path -Qualifier $conf.SaveRoot
$problems = @()

$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}
if (-not $bucket) { Write-Output "REFUSING: no BackupBucket in idle.conf.json"; exit 1 }

# --- Nobody online, and no doubt about it ----------------------------------------
$server = Get-Process -Name "PalServer-Win64-Shipping" -ErrorAction SilentlyContinue
if ($server) {
  $restBase = "http://127.0.0.1:$($conf.RestPort)/v1/api"
  $secure = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential("admin", $secure)
  $players = $null
  try {
    $players = Invoke-RestMethod -Uri "$restBase/players" -Credential $cred -TimeoutSec 5 -ErrorAction Stop
  } catch {
    Write-Output "REFUSING: server is running but /players did not answer ($($_.Exception.Message)). Unknown is not empty."
    exit 1
  }
  if ($null -eq $players -or $null -eq $players.players) {
    Write-Output "REFUSING: server is running but /players was unparseable. Unknown is not empty."
    exit 1
  }
  $count = @($players.players).Count
  if ($count -gt 0) {
    $names = (@($players.players) | ForEach-Object { $_.name }) -join ", "
    Write-Output "REFUSING: $count player(s) online ($names). Announce and try again when empty."
    exit 1
  }
  Write-Output "Roster empty (server running). Proceeding; the new Lua takes effect on the next server start."
} else {
  Write-Output "No server process. Proceeding; the new Lua takes effect on the next server start."
}

# --- Fetch the Lua and prove it arrived intact -----------------------------------
$staged = "C:\PalServer\scripts\autohatchfix-main.lua"
& $awsExe s3 cp "s3://$bucket/scripts/windows/autohatchfix-main.lua" $staged --region $region --only-show-errors
if ($LASTEXITCODE -ne 0) { Write-Output "FAILED: s3 cp exit $LASTEXITCODE"; exit 1 }
if (-not (Test-Path $staged)) { Write-Output "FAILED: s3 cp exited 0 but '$staged' does not exist"; exit 1 }

$actual = (Get-FileHash -Path $staged -Algorithm SHA256).Hash.ToLower()
$expected = $ExpectedSha256.ToLower()
if ($actual -ne $expected) {
  Write-Output "FAILED: hash mismatch. expected $expected, got $actual. NOT deploying."
  exit 1
}
Write-Output "Fetched autohatchfix-main.lua, sha256 $actual (matches)."

# --- Copy into both Mods folders, live and stage ----------------------------------
# Copy-Item rather than a re-encode: the file is ASCII now, and a script that rewrites
# the bytes it was asked to deliver can no longer be checked against the hash above.
# The parent directory is created rather than treated as a hard failure: unlike AutoHatch,
# AutoHatchFix has no long install history on this box, so a missing Scripts folder is an
# expected first-deploy state, not evidence something else is wrong.
$targets = @(
  "C:\PalServer\Pal\Binaries\Win64\ue4ss\Mods\AutoHatchFix\Scripts\main.lua",
  "$saveQualifier\PalServer\ue4ss-stage\Win64\ue4ss\Mods\AutoHatchFix\Scripts\main.lua"
)
foreach ($target in $targets) {
  $parent = Split-Path -Parent $target
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null }
  if (-not (Test-Path $parent)) { $problems += "could not create directory '$parent'"; continue }
  Copy-Item -Path $staged -Destination $target -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $target)) { $problems += "copy to '$target' produced no file"; continue }
  $landed = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLower()
  if ($landed -ne $expected) { $problems += "'$target' has sha $landed, expected $expected" }
  else { Write-Output "OK: $target" }
}

if ($VanillaOnly) {
  if ($problems.Count -gt 0) {
    Write-Output "RESULT: FAILED with $($problems.Count) problem(s):"
    $problems | ForEach-Object { Write-Output "  - $_" }
    exit 1
  }
  Write-Output "RESULT: Lua deployed to $($targets.Count) location(s). Mod left disabled (-VanillaOnly)."
  exit 0
}

# --- Re-enable: every rename verified, never announced ----------------------------
function Enable-ByRename {
  param([string]$DisabledPath, [string]$EnabledPath, [string]$Label)
  # Returns a problem string, or $null. Nothing else may be written here: PowerShell
  # collects a function's whole output stream, so a Write-Output success line comes
  # back alongside the $null as a two-element array, and the caller's truthiness test
  # then reads a clean rename as a failure. Observed 2026-08-28, on a run where all
  # three renames worked and the script reported six problems.
  if (Test-Path $EnabledPath) { return $null }
  if (-not (Test-Path $DisabledPath)) { return "$Label - neither '$EnabledPath' nor '$DisabledPath' exists" }
  Move-Item -Path $DisabledPath -Destination $EnabledPath -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $EnabledPath)) { return "$Label - rename FAILED, '$EnabledPath' still absent (a running server holds a mounted pak locked)" }
  return $null
}

function Ensure-Enabled {
  param([string]$EnabledPath, [string]$Label)
  # Same contract as Enable-ByRename above (return a problem string or $null), for a mod
  # folder with no .disabled counterpart to rename FROM: AutoHatchFix has no long install
  # history on this box, so its enabled.txt may simply never have existed yet.
  if (Test-Path $EnabledPath) { return $null }
  New-Item -ItemType File -Path $EnabledPath -Force -ErrorAction SilentlyContinue | Out-Null
  if (-not (Test-Path $EnabledPath)) { return "$Label - could not create '$EnabledPath'" }
  return $null
}

# Only AutoHatchFix's own enabled.txt is touched here. The original AutoHatch mod's Lua
# enabled.txt is deliberately left alone in both trees: it must stay disabled, or its
# shared-context sweep runs again and reintroduces the misroute this mod replaces. Its pak
# stays enabled separately, as the machinery AutoHatchFix drives.
$enables = @(
  @{ Label = "live AutoHatchFix enabled.txt";
     Path = "C:\PalServer\Pal\Binaries\Win64\ue4ss\Mods\AutoHatchFix\enabled.txt" },
  @{ Label = "staged AutoHatchFix enabled.txt";
     Path = "$saveQualifier\PalServer\ue4ss-stage\Win64\ue4ss\Mods\AutoHatchFix\enabled.txt" }
)
foreach ($enable in $enables) {
  $problem = Ensure-Enabled -EnabledPath $enable.Path -Label $enable.Label
  if ($problem) { $problems += $problem } else { Write-Output "OK: $($enable.Label) enabled" }
}

$autoHatchPakRename = @{ Label = "staged AutoHatch.pak";
  Disabled = "$saveQualifier\PalServer\logicmods-stage\AutoHatch.pak.disabled";
  Enabled = "$saveQualifier\PalServer\logicmods-stage\AutoHatch.pak" }
$problem = Enable-ByRename -DisabledPath $autoHatchPakRename.Disabled -EnabledPath $autoHatchPakRename.Enabled -Label $autoHatchPakRename.Label
if ($problem) { $problems += $problem } else { Write-Output "OK: $($autoHatchPakRename.Label) enabled" }

# The launcher mirrors the stage into LogicMods before every launch, so the live pak
# follows from the staged one. Reported rather than touched: it is locked while the
# server runs, and a stale live copy beside an enabled stage is worth seeing.
$livePak = "C:\PalServer\Pal\Content\Paks\LogicMods\AutoHatch.pak"
Write-Output "Live LogicMods\AutoHatch.pak present: $(Test-Path $livePak)"

if ($problems.Count -gt 0) {
  Write-Output "RESULT: FAILED with $($problems.Count) problem(s):"
  $problems | ForEach-Object { Write-Output "  - $_" }
  exit 1
}
Write-Output "RESULT: Lua deployed and AutoHatchFix enabled. Restart the server to load it."
exit 0
