# Re-deliver the boot scripts from S3 to a RUNNING box.
#
# This exists because putting a script in S3 is NOT deploying it. The boot-fetch loop
# in windows_user_data.ps1.tftpl runs from user_data, and user_data runs on FIRST BOOT
# ONLY - a stop/start does not re-run it. So editing palworld-idle.ps1 or
# palworld-launch.ps1 and running `terraform apply` updates the S3 object and changes
# nothing on the box, indefinitely.
#
# That failure is silent in the worst way: the apply succeeds, the S3 object carries
# today's timestamp, and the live box keeps running whatever it fetched the day it was
# built. Observed 2026-07-29 - on-box palworld-launch.ps1 was ELEVEN DAYS older than
# the S3 copy, across several stop/starts, with nothing anywhere reporting a problem.
#
# update-server.ps1 and seed-ue4ss-stage.ps1 do not need this: they are pulled fresh
# from S3 by whoever runs them. The three below are the ones with no delivery path.
#
# Run over SSM Run Command (no RDP):
#   $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
#   $b = (Get-Content C:\PalServer\idle.conf.json -Raw | ConvertFrom-Json).BackupBucket
#   & $aws s3 cp "s3://$b/scripts/windows/sync-scripts.ps1" C:\PalServer\scripts\sync-scripts.ps1 --only-show-errors
#   & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PalServer\scripts\sync-scripts.ps1
#
# Integrity is checked the same way the boot path checks it, and for the same reason:
# a size floor is not enough, because half a PowerShell script usually still parses and
# then runs the wrong subset. Verified against S3's own ETag rather than a baked-in
# hash, so a script edit never has to touch user_data.
#
# Exit codes: 0 = every script synced and verified, 1 = at least one did not. A script
# that could not be verified is REMOVED rather than left in place, because a corrupt
# watcher means no idle-shutdown (the box bills around the clock) and no watchdog.
#
# Pure ASCII (output goes to the SSM console, not Discord), but carries a UTF-8 BOM
# like its siblings so a future non-ASCII edit cannot silently break PS 5.1.

$ErrorActionPreference = "Continue"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$bucket = $conf.BackupBucket
$region = $conf.AwsRegion

if (-not $bucket) { Write-Output "REFUSING: no BackupBucket in idle.conf.json"; exit 1 }

$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}

# The three fetched by user_data at first boot, and therefore the three that go stale.
$scriptNames = @("palworld-launch.ps1", "palworld-idle.ps1", "backup-to-s3.ps1")

$failed = @()
foreach ($scriptName in $scriptNames) {
  $dest = "C:\PalServer\scripts\$scriptName"
  $key = "scripts/windows/$scriptName"

  $before = if (Test-Path $dest) { (Get-FileHash $dest -Algorithm MD5).Hash.ToLower() } else { $null }

  & $awsExe s3 cp "s3://$bucket/$key" $dest --region $region --only-show-errors
  if ($LASTEXITCODE -ne 0) {
    Write-Output "FAILED $scriptName - aws s3 cp exited $LASTEXITCODE"
    $failed += $scriptName
    continue
  }
  if (-not (Test-Path $dest)) {
    Write-Output "FAILED $scriptName - not present after download"
    $failed += $scriptName
    continue
  }

  # ETag == MD5 for these single-part uploads. A multipart ETag carries a "-N" suffix
  # and is treated as unverifiable rather than as a mismatch, same as the boot path.
  $etag = (& $awsExe s3api head-object --bucket $bucket --key $key --region $region --query ETag --output text 2>$null)
  $etag = if ($etag) { $etag.Trim('"').ToLower() } else { $null }
  $actual = (Get-FileHash $dest -Algorithm MD5).Hash.ToLower()

  if (-not $etag) {
    Write-Output "WARNING $scriptName - could not read ETag, integrity unverified (left in place)"
  } elseif ($etag -like "*-*") {
    Write-Output "NOTE $scriptName - multipart ETag, integrity unverified (left in place)"
  } elseif ($actual -ne $etag) {
    Write-Output "FAILED $scriptName - checksum mismatch (S3 $etag, local $actual). REMOVING rather than running a corrupt script."
    Remove-Item $dest -Force -ErrorAction SilentlyContinue
    $failed += $scriptName
    continue
  }

  # Say whether anything actually MOVED. "synced" on an unchanged file and "synced" on
  # a file that was eleven days stale should not read identically - the whole reason
  # this script exists is that the second case was invisible.
  if ($before -eq $actual) {
    Write-Output "unchanged $scriptName ($actual)"
  } else {
    Write-Output "UPDATED   $scriptName (was $(if ($before) { $before } else { 'absent' }), now $actual)"
  }
}

if ($failed.Count -gt 0) {
  Write-Output ""
  Write-Output "RESULT: FAILED for $($failed -join ', '). The box may be running without its watchdog or idle-shutdown - fix before relying on either."
  exit 1
}

Write-Output ""
Write-Output "RESULT: all $($scriptNames.Count) scripts present and hash-verified against S3."
exit 0
