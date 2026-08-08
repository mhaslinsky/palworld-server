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
# Publish exit codes: 0 = published and the baseline matches the stage exactly.
# 2 = every local pak published and verified, but S3 holds extras the stage no longer
# has, so a later -Restore would resurrect them. 1 = failed, baseline not trustworthy.
#
# Publish REFUSES on an empty stage. A zero-pak baseline in S3 would restore cleanly,
# exit 0, and leave the server modless while every check passed - a guard that cannot
# tell "no mods staged" from "the stage is gone" is not a guard.
#
# PUBLISH is an OVERLAY (no --delete), matching seed-ue4ss-stage.ps1: removing a pak
# locally leaves the old object in S3. --delete is the one flag that can destroy the last
# copy of a mod that needs a Nexus login to re-download, so this REPORTS the divergence
# loudly (with the exact `aws s3 rm` lines) instead of acting on it. Silent divergence
# would be the real bug, since a later -Restore resurrects those paks and the launcher
# then makes them live; a human deleting them is fine.
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

  # Complete and verified: swap it in, holding the SAME mutex palworld-launch.ps1 takes
  # around its start. Without it the launcher (also the every-2-min watchdog) can land in
  # the window where the old stage has been moved aside and the new one is not in place
  # yet, see no stage at all, and start the server without the pak mods. Global\ because
  # the racers are separate processes.
  $previous = "$stageRoot.previous"
  $swapMutex = New-Object System.Threading.Mutex($false, "Global\PalworldLaunch")
  $holdsSwap = $false
  try {
    try { $holdsSwap = $swapMutex.WaitOne(30000) }
    catch [System.Threading.AbandonedMutexException] { $holdsSwap = $true }
    if (-not $holdsSwap) {
      Write-Output "FAILED: could not take the launch lock in 30s - stage left UNTOUCHED (a launch is in progress)."
      Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
      exit 1
    }

    if (Test-Path $previous) { Remove-Item $previous -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $stageRoot) { Move-Item $stageRoot $previous -Force }
    try {
      Move-Item $scratch $stageRoot -Force
    } catch {
      # Put the old stage back rather than leaving the canonical path missing. A box with
      # a stale stage still boots its mods; a box with NO stage silently boots without
      # them, which is the state this whole script exists to prevent.
      Write-Output ("FAILED: could not move the verified stage into place: " + $_.Exception.Message)
      if ((Test-Path $previous) -and -not (Test-Path $stageRoot)) {
        Move-Item $previous $stageRoot -Force -ErrorAction SilentlyContinue
        Write-Output "  rolled back to the previous stage"
      }
      exit 1
    }

    # Validate BEFORE discarding the rollback copy, and ROLL BACK on failure. Leaving the
    # bad stage at the canonical path would be worse than not restoring at all: the
    # launcher treats it as authoritative and would sweep working mods out of ~mods to
    # match an incomplete set. Done inside the mutex so no launch can observe the swap.
    $restored = @(Get-ChildItem $stageRoot -Filter *.pak -ErrorAction SilentlyContinue)
    if ($restored.Count -ne $remoteNames.Count) {
      Write-Output "FAILED: stage holds $($restored.Count) pak(s) after the swap, expected $($remoteNames.Count) - rolling back."
      $failed = "$stageRoot.failed"
      if (Test-Path $failed) { Remove-Item $failed -Recurse -Force -ErrorAction SilentlyContinue }
      Move-Item $stageRoot $failed -Force -ErrorAction SilentlyContinue
      if (Test-Path $previous) {
        Move-Item $previous $stageRoot -Force -ErrorAction SilentlyContinue
        Write-Output ("  rolled back to the previous stage; the bad set is at '" + $failed + "'")
      } else {
        Write-Output ("  there was no previous stage to roll back to; the bad set is at '" + $failed + "'")
      }
      exit 1
    }
    Remove-Item $previous -Recurse -Force -ErrorAction SilentlyContinue
  } finally {
    if ($holdsSwap) { $swapMutex.ReleaseMutex() }
    $swapMutex.Dispose()
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

# --- Verify on S3 by CONTENT, not by key existence (AGENTS.md rule 8) ---------------
# "The key is there" is the wrong question. Uploading, `s3 sync` compares size and
# timestamp, so a REBUILT pak that lands on the same byte count can be skipped entirely
# while the key sits there looking healthy - the same trap that made a restage transfer
# nothing on 2026-07-30, just pointed the other way. Compare the ETag to the local MD5,
# which is what sync-scripts.ps1 already does for the bootstrap scripts.
$stale = @()
foreach ($pak in $staged) {
  $etag = & $awsExe s3api head-object --bucket $bucket --key "paks-stage/$($pak.Name)" `
    --region $region --query ETag --output text 2>$null
  if (-not $etag) { $stale += ($pak.Name + " (absent from S3)"); continue }
  $etag = $etag.Trim('"')
  if ($etag -like "*-*") {
    # Multipart upload: the ETag is a hash OF HASHES, not the file's MD5, so it cannot be
    # compared directly. A size check is not a substitute - a rebuilt same-size pak is the
    # exact case this verification exists to catch, so accepting size here would wave
    # through the one failure it is looking for. Download and hash instead: slower, but
    # this branch only fires on paks above the multipart threshold, and a recovery
    # baseline is worth the round trip.
    Write-Output ("  $($pak.Name): multipart ETag, verifying by download ...")
    $probe = Join-Path $env:TEMP ("pakverify-" + $pak.Name)
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    & $awsExe s3 cp "s3://$bucket/paks-stage/$($pak.Name)" $probe --region $region --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $probe)) {
      $stale += ($pak.Name + " (could not download to verify)")
      continue
    }
    $remoteSha = (Get-FileHash $probe -Algorithm SHA256).Hash.ToLower()
    $localSha = (Get-FileHash $pak.FullName -Algorithm SHA256).Hash.ToLower()
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    if ($remoteSha -ne $localSha) { $stale += ($pak.Name + " (S3 copy differs from local)") }
    continue
  }
  $localMd5 = (Get-FileHash $pak.FullName -Algorithm MD5).Hash.ToLower()
  if ($etag.ToLower() -ne $localMd5) { $stale += ($pak.Name + " (S3 copy differs from local)") }
}
if ($stale.Count -gt 0) {
  Write-Output "FAILED: S3 does not match the local stage - baseline NOT trustworthy:"
  $stale | ForEach-Object { Write-Output ("  " + $_) }
  Write-Output "  Re-run, or upload the offender explicitly with `aws s3 cp`."
  exit 1
}

# --- Report divergence rather than deleting it --------------------------------------
# Publish is an overlay, so a pak removed locally still sits in S3 and a later -Restore
# would resurrect it - and because palworld-launch.ps1 makes the stage authoritative,
# that resurrected pak would then be pushed live. Deleting automatically is worse: it is
# the one action that can destroy the last copy of a mod that needs a Nexus login to
# re-download. So surface it loudly and let a human decide.
$remoteOnly = @(& $awsExe s3 ls "s3://$bucket/paks-stage/" --region $region 2>$null |
  ForEach-Object { ($_ -split '\s+', 4)[-1] } |
  Where-Object { $_ -like "*.pak" -and ($staged.Name -notcontains $_) })
if ($remoteOnly.Count -gt 0) {
  Write-Output ""
  Write-Output "WARNING: S3 holds $($remoteOnly.Count) pak(s) that are NOT in the local stage:"
  $remoteOnly | ForEach-Object { Write-Output ("  " + $_) }
  Write-Output "  A later -Restore WOULD bring these back, and the launcher would then make them live."
  Write-Output "  If they were removed deliberately, delete them from S3 too:"
  $remoteOnly | ForEach-Object { Write-Output ("    aws s3 rm s3://$bucket/paks-stage/$_") }
  Write-Output ""
}

if ($remoteOnly.Count -gt 0) {
  # Exit 2, not 0. Every local pak really did publish, so this is not a failure - but the
  # BASELINE is divergent, and a caller that only reads the exit code would file that
  # under "published cleanly" and never see the warning above. Make the two outcomes
  # structurally distinguishable rather than leaving the difference in a log line.
  Write-Output "PUBLISHED WITH DIVERGENCE (exit 2): all $($staged.Count) local pak(s) verified in S3, but the baseline holds $($remoteOnly.Count) extra listed above."
  Write-Output "Recover a lost stage with: seed-paks-stage.ps1 -Restore"
  exit 2
}

Write-Output "OK: pak stage published to s3://$bucket/paks-stage/ (all $($staged.Count) verified by content)."
Write-Output "Recover a lost stage with: seed-paks-stage.ps1 -Restore"
exit 0
