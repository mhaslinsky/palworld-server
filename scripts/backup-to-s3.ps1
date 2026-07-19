# Rolling off-box world backup for the WINDOWS box. The PowerShell counterpart of
# scripts/backup-to-s3.sh, same contract, same failure philosophy.
#
# Without this the Windows box has only DLM snapshots of its save volume - a
# once-daily crash-consistent tier. That is exactly the gap that made the
# 2026-07-18 recovery point 15 hours stale on the Linux side. It matters most at
# cutover: the moment Windows becomes the live server, an unbacked Windows world
# would put the group straight back where the incident started.
#
# Writes to world/windows/ so it can never be confused with a Linux backup - the
# two boxes share an instance role, and a monitor that watches one prefix must not
# be satisfied by the other box's objects.
#
# Every step that can fail silently fails LOUDLY instead: an unproven save is
# stored under a DEGRADED prefix the monitor does not watch, and the run exits
# non-zero rather than reporting a green backup.
$ErrorActionPreference = "Stop"

$conf = Get-Content "C:\PalServer\idle.conf.json" -Raw | ConvertFrom-Json
$bucket = $conf.BackupBucket
if (-not $bucket) { Write-Output "BACKUP_FAILED: idle.conf.json has no BackupBucket"; exit 1 }

$awsExe = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsExe)) {
  $resolved = (Get-Command aws -ErrorAction SilentlyContinue).Source
  if ($resolved) { $awsExe = $resolved } else { Write-Output "BACKUP_FAILED: aws CLI not found"; exit 1 }
}

$saveRoot = $conf.SaveRoot
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$archive = "$env:TEMP\palworld-backup-$stamp.zip"
# 1 MB floor: a real world is a few MB, a freshly generated empty one ~120 KB.
$minBytes = 1000000

function Fail([string]$reason) {
  Write-Output "BACKUP_FAILED: $reason"
  Write-EventLog -LogName Application -Source "Palworld" -EventId 110 -EntryType Error `
    -Message "backup failed: $reason" -ErrorAction SilentlyContinue
  Remove-Item $archive -Force -ErrorAction SilentlyContinue
  exit 1
}

$levelSav = Get-ChildItem "$saveRoot\*\*\Level.sav" -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $levelSav) { Fail "no Level.sav under $saveRoot (is the save volume mounted?)" }

# --- force-save, and try to PROVE it reached disk ----------------------------
# Content-Length: 0 is required or the REST API answers 411.
$degraded = $null
$mtimeBefore = $levelSav.LastWriteTimeUtc
$sec = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
$cred = New-Object PSCredential("admin", $sec)
try {
  Invoke-RestMethod -Uri "http://127.0.0.1:$($conf.RestPort)/v1/api/save" -Method Post `
    -Credential $cred -Headers @{ "Content-Length" = "0" } -TimeoutSec 30 -ErrorAction Stop | Out-Null
  Start-Sleep -Seconds 5
  $after = (Get-Item $levelSav.FullName -ErrorAction SilentlyContinue).LastWriteTimeUtc
  if ($null -eq $after -or $after -le $mtimeBefore) {
    $degraded = "save reported success but Level.sav did not change on disk"
  }
} catch {
  $degraded = "force-save request failed (server down or REST unreachable): $($_.Exception.Message)"
}

$key = if ($degraded) { "world/windows-degraded/$stamp.zip" } else { "world/windows/$stamp.zip" }
if ($degraded) { Write-Output "DEGRADED: $degraded - publishing under world/windows-degraded/" }

# --- archive + integrity gates ------------------------------------------------
Compress-Archive -Path "$saveRoot\*" -DestinationPath $archive -CompressionLevel Optimal -Force
if (-not (Test-Path $archive)) { Fail "archive missing after compression" }
$size = (Get-Item $archive).Length
# Open it: a truncated zip usually still exists at a plausible size.
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  $entries = $zip.Entries.Count
  $zip.Dispose()
} catch { Fail "archive fails integrity check: $($_.Exception.Message)" }
if ($entries -lt 1) { Fail "archive contains no entries" }
# Size floor catches the empty-world class - a restored shell passes every other check.
if ($size -lt $minBytes) { Fail "archive only $size bytes, below $minBytes floor - refusing to publish a suspect backup" }

# --- upload, then PROVE the object exists -------------------------------------
& $awsExe s3 cp $archive "s3://$bucket/$key" --region $conf.AwsRegion --only-show-errors
if ($LASTEXITCODE -ne 0) { Fail "s3 upload failed (aws exit $LASTEXITCODE)" }

# Verified via ListBucket, which the role has - it deliberately cannot GetObject
# on the world prefixes, so it can write and list its backups but never read or
# delete them.
$remote = & $awsExe s3api list-objects-v2 --bucket $bucket --prefix $key `
  --region $conf.AwsRegion --query "Contents[0].Size" --output text 2>$null
if ("$remote".Trim() -ne "$size") { Fail "size mismatch after upload: local=$size remote=$remote" }

Remove-Item $archive -Force -ErrorAction SilentlyContinue

if ($degraded) {
  # Stored, not blessed: the object is outside the prefix the monitor treats as
  # healthy AND this exits non-zero, so the failure has two independent ways to
  # be noticed rather than passing as a green run.
  Write-Output "BACKUP_DEGRADED $key $size - $degraded"
  exit 1
}
Write-Output "BACKUP_VERIFIED $key $size"
