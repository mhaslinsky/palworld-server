# Red/green proof for deploy-autohatch.ps1's Enable-ByRename.
#
# Run it on the BOX, with powershell.exe, not only with pwsh on a laptop:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PalServer\scripts\tests\Test-EnableByRename.ps1
#
# WINDOWS POWERSHELL 5.1 ONLY, like its sibling. No ternaries, no PS6+ automatics.
#
# What it exists to catch, from a real run on 2026-08-28: the function wrote its success
# line with Write-Output and then returned $null. PowerShell collects a function's whole
# output stream, so the caller received a two-element array, tested it for truthiness, and
# reported three successful renames as six problems. Reporting failure on success is the
# safe direction of the house bug, and still wrong: the next person reads FAILED and
# re-runs a deploy that had already worked.
#
# So the GREEN cases assert the return is $null and nothing else, which is the assertion
# the old code fails. Both RED cases assert a problem string comes back, because a rename
# that silently does nothing is the failure this function was written to make visible.
#
# The function is parsed directly out of the shipped script, never retyped here: a test
# that exercises a paraphrase proves nothing about the code.

$ErrorActionPreference = "Stop"
$failures = 0

$scriptPath = Join-Path $PSScriptRoot "..\deploy-autohatch.ps1"
if (-not (Test-Path $scriptPath)) { Write-Output "FAIL: cannot find '$scriptPath'"; exit 1 }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath).Path, [ref]$null, [ref]$null)
$fn = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enable-ByRename'
}, $true)
if (-not $fn) { Write-Output "FAIL: Enable-ByRename not found in '$scriptPath'"; exit 1 }
Invoke-Expression $fn.Extent.Text

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("enable-by-rename-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
  # GREEN: a staged .disabled file is renamed, and the function returns nothing at all.
  $disabled = Join-Path $tmp "enabled.txt.disabled"
  $enabled = Join-Path $tmp "enabled.txt"
  Set-Content -Path $disabled -Value "x"
  $result = Enable-ByRename -DisabledPath $disabled -EnabledPath $enabled -Label "green"
  if ($null -ne $result) {
    Write-Output "FAIL green: expected nothing, got [$($result.GetType().Name)] with $(@($result).Count) element(s)"
    $failures++
  } elseif (-not (Test-Path $enabled)) {
    Write-Output "FAIL green: returned nothing but the file was not renamed"
    $failures++
  } else {
    Write-Output "PASS green: renamed, returned nothing"
  }

  # GREEN: already enabled. A re-run of the deploy must not manufacture a problem.
  $result = Enable-ByRename -DisabledPath $disabled -EnabledPath $enabled -Label "already enabled"
  if ($null -ne $result) { Write-Output "FAIL already-enabled: expected nothing, got '$result'"; $failures++ }
  else { Write-Output "PASS already-enabled: no-op, returned nothing" }

  # RED: neither name exists, so there is nothing to enable and the caller must hear so.
  $missing = Join-Path $tmp "absent"
  $result = Enable-ByRename -DisabledPath "$missing.disabled" -EnabledPath $missing -Label "missing"
  if ($result -isnot [string]) { Write-Output "FAIL missing: expected a problem string, got '$result'"; $failures++ }
  else { Write-Output "PASS missing: reported a problem" }

  # RED: the move cannot land (no parent directory), which is how a locked pak fails on
  # the box. Move-Item is called with -ErrorAction SilentlyContinue, so the ONLY thing
  # standing between this and a false success is the Test-Path after it.
  $blockedDisabled = Join-Path $tmp "blocked.pak.disabled"
  Set-Content -Path $blockedDisabled -Value "x"
  $result = Enable-ByRename -DisabledPath $blockedDisabled -EnabledPath (Join-Path $tmp "no-such-dir\blocked.pak") -Label "blocked"
  if ($result -isnot [string]) { Write-Output "FAIL blocked: expected a problem string, got '$result'"; $failures++ }
  else { Write-Output "PASS blocked: reported a problem" }
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Output "RESULT: $failures failure(s)"; exit 1 }
Write-Output "RESULT: all 4 cases passed"
exit 0
