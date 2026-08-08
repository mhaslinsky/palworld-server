# Publish the box's CURRENT pak stage (D:\PalServer\paks-stage) up to S3, and pull it
# back down when D: is empty. The sibling of seed-ue4ss-stage.ps1, for the pak mods that
# the UE4SS stage does not cover (that one overlays Win64 only).
#
# Why this exists: palworld-launch.ps1 restores paks from D:\PalServer\paks-stage before
# every launch, and D: survives instance replacement - so the launcher alone covers the
# rebuild case. What it does NOT cover is the stage itself being lost: a recreated or
# restored EBS volume comes up with no paks-stage at all, and the launcher then quietly
# starts a server with no pak mods. Nothing anywhere reports that, which is the same
# shape as the empty-world restore. S3 is the off-volume baseline for exactly that.
#
# Run on the box via SSM Run Command (no RDP). Two directions:
#   (default)  publish  - D: -> S3, after verifying D: is worth publishing
#   -Restore            - S3 -> D:, for a rebuilt or empty volume
#
# Publish REFUSES on an empty stage. A zero-pak baseline in S3 would restore cleanly,
# exit 0, and leave the server modless while every check passed - a guard that cannot
# tell "no mods staged" from "the stage is gone" is not a guard.
#
# PUBLISH is an OVERLAY (no --delete), matching seed-ue4ss-stage.ps1: removing a pak
# locally leaves the old object in S3, so delete it from s3://<bucket>/paks-stage/ by
# hand too. That is deliberate and it is the sibling's documented behaviour - --delete is
# the flag that can erase the last copy of a mod nobody can re-download without a Nexus
# login, so making these two scripts disagree would be a worse trap than either rule
# alone. Changing both together is its own deliberate change.
#
# RESTORE is NOT an overlay: it stages into a scratch dir, verifies it holds every pak S3
# lists, and only then swaps it in. It has to be exact, because palworld-launch.ps1
# treats the stage as authoritative and sweeps live paks the stage does not list - a
# partial restore landing directly in the stage would DELETE working mods on next launch.
#
# Pure ASCII (output goes to the SSM console), with a UTF-8 BOM like its siblings so a
# future non-ASCII edit cannot silently break the PowerShell 5.1 parse.

param(
  [switch]$Restore
)

$ErrorActionPreference = "Stop"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$bucket = $conf.BackupBucket
$region = $conf.AwsRegion
$saveQualifier = Split-Path -Qualifier $conf.SaveRoot   # e.g. "D:"
$stageRoot = "$saveQualifier\PalServer\paks-stage"

$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}

if (-not $bucket) { Write-Output "REFUSING: no BackupBucket in idle.conf.json"; exit 1 }

if ($Restore) {
  # --- S3 -> D: ------------------------------------------------------------------
  # Check the REMOTE has something first. `s3 sync` from an empty prefix exits 0 having
  # transferred nothing, after which "restored" would describe a stage that is still
  # empty - the failure reporting success, which this file exists to avoid.
  $remote = & $awsExe s3 ls "s3://$bucket/paks-stage/" --region $region 2>$null
  if (-not $remote) {
    Write-Output "REFUSING: s3://$bucket/paks-stage/ is empty - nothing to restore. Publish a baseline first."
    exit 1
  }

  # Sync into a SCRATCH dir, never straight into the stage. palworld-launch.ps1 treats
  # the stage as authoritative and sweeps live paks that it does not list, so a partial
  # sync landing there directly would not merely be incomplete - it would actively delete
  # working mods from ~mods on the next launch. The recovery tool would cause the outage
  # it exists to fix. Validate the full expected set first, swap only then.
  $scratch = "$stageRoot.incoming"
  if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null

  # --exact-timestamps is load-bearing going S3 -> local: the CLI skips same-SIZE objects
  # unless the local copy is newer, and a rebuilt pak very often lands on the same byte
  # count. That exact trap cost a silent no-op restage on 2026-07-30 (see docs). Into an
  # empty scratch dir every object transfers anyway; it is kept so this stays correct if
  # the scratch is ever reused.
  & $awsExe s3 sync "s3://$bucket/paks-stage/" "$scratch" `
    --region $region --exact-timestamps --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    Write-Output "FAILED: s3 sync exit $LASTEXITCODE - stage left untouched"
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
  }

  # Completeness, not "at least one". Compare against what S3 actually holds, so an
  # interrupted transfer is caught rather than rounded up to success.
  $remoteNames = @(& $awsExe s3 ls "s3://$bucket/paks-stage/" --region $region 2>$null |
    ForEach-Object { ($_ -split '\s+', 4)[-1] } |
    Where-Object { $_ -like "*.pak" })
  $localNames = @(Get-ChildItem $scratch -Filter *.pak -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
  $absent = @($remoteNames | Where-Object { $localNames -notcontains $_ })
  if ($remoteNames.Count -eq 0 -or $absent.Count -gt 0) {
    Write-Output "FAILED: incomplete restore - stage left UNTOUCHED. Missing locally:"
    $absent | ForEach-Object { Write-Output ("  " + $_) }
    if ($remoteNames.Count -eq 0) { Write-Output "  (could not enumerate any .pak in S3)" }
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
  }

  # Complete and verified: swap it in. Keep the old stage until the new one is in place,
  # so a failure here cannot leave the box with no stage at all.
  $previous = "$stageRoot.previous"
  if (Test-Path $previous) { Remove-Item $previous -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path $stageRoot) { Move-Item $stageRoot $previous -Force }
  Move-Item $scratch $stageRoot -Force
  Remove-Item $previous -Recurse -Force -ErrorAction SilentlyContinue

  $restored = @(Get-ChildItem $stageRoot -Filter *.pak -ErrorAction SilentlyContinue)
  if ($restored.Count -ne $remoteNames.Count) {
    Write-Output "FAILED: stage holds $($restored.Count) pak(s) after the swap, expected $($remoteNames.Count) - do NOT trust this as a restore."
    exit 1
  }
  Write-Output "OK: restored $($restored.Count) pak(s) to '$stageRoot':"
  $restored | ForEach-Object {
    Write-Output ("  " + $_.Name + "  " + $_.Length + " bytes  sha256 " + (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())
  }
  Write-Output "They go live at the next server start; palworld-launch.ps1 copies them into ~mods."
  exit 0
}

# --- D: -> S3 (publish) ------------------------------------------------------------
$staged = @(Get-ChildItem $stageRoot -Filter *.pak -ErrorAction SilentlyContinue)
if ($staged.Count -eq 0) {
  Write-Output "REFUSING: '$stageRoot' holds no .pak - not publishing an empty baseline."
  Write-Output "  An empty baseline restores cleanly and leaves the server with NO pak mods, silently."
  Write-Output "  If you meant to clear the stage, delete s3://$bucket/paks-stage/ by hand."
  exit 1
}

Write-Output "Publishing $($staged.Count) pak(s) from '$stageRoot' -> s3://$bucket/paks-stage/ ..."
$staged | ForEach-Object {
  Write-Output ("  " + $_.Name + "  " + $_.Length + " bytes  sha256 " + (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())
}
& $awsExe s3 sync "$stageRoot" "s3://$bucket/paks-stage/" --region $region --only-show-errors
if ($LASTEXITCODE -ne 0) { Write-Output "FAILED: s3 sync exit $LASTEXITCODE"; exit 1 }

# --- Verify on S3, do not trust the exit code (AGENTS.md rule 8) --------------------
# Check EVERY pak landed, not just that the prefix is non-empty: a partial sync leaves
# the older objects sitting there and the listing looks healthy either way.
$missing = @()
foreach ($pak in $staged) {
  $remote = & $awsExe s3 ls "s3://$bucket/paks-stage/$($pak.Name)" --region $region 2>$null
  if (-not $remote) { $missing += $pak.Name }
}
if ($missing.Count -gt 0) {
  Write-Output "FAILED: these paks are NOT visible in S3 after the sync - baseline NOT trustworthy:"
  $missing | ForEach-Object { Write-Output ("  " + $_) }
  exit 1
}

Write-Output "OK: pak stage published to s3://$bucket/paks-stage/ (all $($staged.Count) verified present)."
Write-Output "Recover a lost stage with: seed-paks-stage.ps1 -Restore"
