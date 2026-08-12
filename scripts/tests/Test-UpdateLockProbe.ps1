# Red/green proof for the update.lock held-detection probe.
#
# Run it on the BOX, with powershell.exe, not only with pwsh on a laptop:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PalServer\scripts\tests\Test-UpdateLockProbe.ps1
#
# WINDOWS POWERSHELL 5.1 ONLY, deliberately. An earlier version of this file used the
# PS7 ternary and $IsWindows, which meant it could not even PARSE on the runtime it
# exists to validate - and once that was fixed, $IsWindows being $null on 5.1 sent a
# genuinely broken probe down the "SKIPPED" branch and exited 0. A guard that cannot run
# on the target platform, and then reports success when it does not run, is the exact
# defect this whole PR is about. No ternaries, no PS6+ automatic variables.
#
# The probe decides whether the watchdog and idle-shutdown stand down, so both directions
# matter and both are asserted:
#   held    -> a live updater holds the handle -> idle must stand down
#   free    -> the updater is gone             -> a leftover file must NOT block recovery

$ErrorActionPreference = "Stop"
$failures = 0
$lockPath = Join-Path ([IO.Path]::GetTempPath()) "update-lock-probe-test.lock"
Remove-Item $lockPath -Force -ErrorAction SilentlyContinue

# The tri-state probe from palworld-idle.ps1, kept identical on purpose: a test that
# exercises a paraphrase of the code proves nothing about the code.
function Get-LockState([string]$path) {
  try {
    $probe = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $probe.Dispose()
    return 'free'
  } catch {
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -is [System.IO.FileNotFoundException] -or $inner -is [System.IO.DirectoryNotFoundException]) { return 'free' }
    if ($inner -is [System.UnauthorizedAccessException]) { return 'unknown' }
    if ($inner -is [System.IO.IOException]) { return 'held' }
    return 'unknown'
  }
}

# Exactly how update-server.ps1's Open-UpdateLock takes it.
$holder = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$stateWhileOpen = Get-LockState $lockPath
$holder.Dispose()
$stateAfterClose = Get-LockState $lockPath

# FAILS on every platform, with no escape hatch. There WAS one, gated on being
# Windows, and it made the test worthless where it was actually being run: an inverted
# held-probe took the skip branch on macOS and exited 0, so the mutation proof this file
# exists to provide could not go red. Measured instead of assumed: .NET enforces
# FileShare on Darwin as well as Windows (the exception differs only in HResult, 35
# versus 0x80070020, which is why the probe classifies by type). If some future platform
# genuinely does not enforce it, a loud failure is the right outcome - the probe would be
# unsafe there, and skipping would hide exactly that.
if ($stateWhileOpen -ne 'held') {
  Write-Output "FAIL  a HELD lock reported '$stateWhileOpen' - the idle script would resume mid-update"
  $failures++
} else {
  Write-Output "PASS  a held lock reports 'held' (idle stands down)"
}

if ($stateAfterClose -ne 'free') {
  Write-Output "FAIL  a released lock reported '$stateAfterClose' - a crashed update would mute the watchdog"
  $failures++
} else {
  Write-Output "PASS  a released lock reports 'free' (a crashed update stops blocking immediately)"
}

# The contract the idle script actually relies on. Get-LockState alone returns 'free'
# for a missing file, but the caller still guards with Test-Path, and this asserts the
# COMBINATION rather than the helper in isolation: an earlier version of this file
# claimed to cover this case and only checked that Remove-Item had worked.
Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
$missingBlocks = (Test-Path $lockPath) -and ((Get-LockState $lockPath) -eq 'held')
if ($missingBlocks) {
  Write-Output "FAIL  a missing lock would block the cycle - a healthy box would never run the watchdog"
  $failures++
} else {
  Write-Output "PASS  a missing lock does not block the cycle"
}

if ($failures -eq 0) {
  Write-Output "ALL PASS"
} else {
  Write-Output "$failures FAILURE(S)"
}
exit $failures
