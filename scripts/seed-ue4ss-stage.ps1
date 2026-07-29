# Publish the box's CURRENT UE4SS stage (D:\PalServer\ue4ss-stage) up to S3, so
# `/palworld-update mods:restage` has a baseline to pull from. Run on the box via SSM
# Run Command (no RDP). Re-run it whenever you update the D: stage locally and want S3
# to match.
#
# It REFUSES to publish a stage that is missing its load-bearing files: a broken or
# half-empty baseline in S3 would make every future `restage` silently install a
# broken mod (the server boots vanilla while looking fine) - the same class of failure
# as restoring an empty world. So it verifies the SAME files update-server.ps1 checks
# after a restage, then verifies the object landed in S3 rather than trusting the sync
# exit code (AGENTS.md rule 8).
#
# sync is an OVERLAY (no --delete): it uploads new/changed files but never purges S3.
# If you REMOVE a mod locally, delete it from s3://<bucket>/ue4ss-stage/ by hand too.
#
# Pure ASCII (no Discord emoji here - output goes to the SSM console), but it carries a
# UTF-8 BOM like its siblings so a future non-ASCII edit can't silently break PS 5.1.

$ErrorActionPreference = "Stop"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$bucket = $conf.BackupBucket
$region = $conf.AwsRegion
$saveQualifier = Split-Path -Qualifier $conf.SaveRoot   # e.g. "D:"
$stageRoot = "$saveQualifier\PalServer\ue4ss-stage"
$win64 = "$stageRoot\Win64"

$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved }
}

if (-not $bucket) { Write-Output "REFUSING: no BackupBucket in idle.conf.json"; exit 1 }

# --- Verify the stage is COMPLETE before publishing it as the baseline -----------
$modDir = "$win64\ue4ss\Mods\BuildingRestrictionsDisabler"
$modsTxt = "$win64\ue4ss\Mods\mods.txt"
$enableLine = (Test-Path $modsTxt) -and `
  (Select-String -Path $modsTxt -Pattern 'BuildingRestrictionsDisabler\s*:\s*1' -Quiet)
$ok = (Test-Path "$win64\dwmapi.dll") -and `
      (Test-Path "$win64\ue4ss\UE4SS.dll") -and `
      (Test-Path "$modDir\dlls\main.dll") -and `
      (Test-Path "$modDir\enabled.txt") -and `
      $enableLine
if (-not $ok) {
  Write-Output "REFUSING: '$win64' is missing load-bearing UE4SS/mod files - not publishing a broken baseline."
  Write-Output "  need: Win64\dwmapi.dll, Win64\ue4ss\UE4SS.dll, ...\BuildingRestrictionsDisabler\dlls\main.dll + enabled.txt, and 'BuildingRestrictionsDisabler : 1' in mods.txt"
  exit 1
}

# --- Publish (overlay) -----------------------------------------------------------
Write-Output "Publishing '$stageRoot' -> s3://$bucket/ue4ss-stage/ ..."
& $awsExe s3 sync "$stageRoot" "s3://$bucket/ue4ss-stage/" --region $region --only-show-errors
if ($LASTEXITCODE -ne 0) { Write-Output "FAILED: s3 sync exit $LASTEXITCODE"; exit 1 }

# --- Verify on S3, don't trust the exit code -------------------------------------
$remote = & $awsExe s3 ls "s3://$bucket/ue4ss-stage/Win64/dwmapi.dll" --region $region
if (-not $remote) { Write-Output "FAILED: Win64/dwmapi.dll not visible in S3 after sync - baseline NOT trustworthy"; exit 1 }

Write-Output "OK: UE4SS stage published to s3://$bucket/ue4ss-stage/ (verified Win64/dwmapi.dll present)."
Write-Output "You can now run /palworld-update mods:restage to pull it back onto D: and overlay it."
