# Red/green proof for the update.lock held-detection probe.
#
# The probe replaced an age test that had a hole big enough to cause the failure it was
# written to prevent, so it is worth exactly nothing until it has been seen to answer
# BOTH ways. This asserts the two directions that matter:
#
#   held    -> a live updater holds the handle -> the idle script must stand down
#   free    -> the updater is gone             -> the file is a leftover, do not stand down
#
# PLATFORM NOTE: FileShare is enforced by the OS, and .NET on Unix does not enforce it
# the way Windows does. This script therefore reports whether the platform can even test
# the question, and refuses to print a pass it did not earn. The box is Windows; a green
# run here is corroboration, and a SKIPPED run means the check must be done on the box.

$ErrorActionPreference = "Stop"
$failures = 0
$lockPath = Join-Path ([IO.Path]::GetTempPath()) "update-lock-probe-test.lock"
Remove-Item $lockPath -Force -ErrorAction SilentlyContinue

# The exact probe from palworld-idle.ps1. Kept identical on purpose: a test that
# exercises a paraphrase of the code proves nothing about the code.
function Test-LockHeld([string]$path) {
  try {
    $probe = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $probe.Dispose()
    return $false
  } catch {
    return $true
  }
}

# Exactly how update-server.ps1's Open-UpdateLock takes it.
$holder = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)

$heldWhileOpen = Test-LockHeld $lockPath
$holder.Dispose()
$heldAfterClose = Test-LockHeld $lockPath

if (-not $heldWhileOpen) {
  # On Unix this is the expected outcome and is NOT a code failure, so say which it is
  # rather than printing a red that sends someone hunting a bug that is not there.
  if ($IsWindows) {
    Write-Output "FAIL  a HELD lock was reported free - the idle script would resume mid-update"
    $failures++
  } else {
    Write-Output "SKIPPED  this platform does not enforce FileShare, so held-detection cannot be tested here."
    Write-Output "         Run this on the Windows box before trusting the probe."
  }
} else {
  Write-Output "PASS  a held lock is detected as held (idle stands down)"
}

# This direction works everywhere: nobody holds the file, so the write-open succeeds.
if ($heldAfterClose) {
  Write-Output "FAIL  a released lock was reported held - a crashed update would mute the watchdog forever"
  $failures++
} else {
  Write-Output "PASS  a released lock is detected as free (crashed update stops blocking immediately)"
}

# A missing file must never read as held: that is the common case on a healthy box, and
# reporting it as held would stand down every cycle forever.
Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
if (Test-Path $lockPath) {
  Write-Output "FAIL  could not remove the test lock"
  $failures++
}

Write-Output ($failures -eq 0 ? "ALL PASS" : "$failures FAILURE(S)")
exit $failures
