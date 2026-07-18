# RESTORE DRILL: prove an S3 backup of the live world actually restores and serves.
#
# An untested backup is a guess. This exercises the real artifact on the Windows box
# (isolated - nothing the players touch), and doubles as a rehearsal of the M3
# cutover, which is the same operation: take the Linux world, land it on Windows,
# point the server at it.
#
# The trap this is specifically testing for: on 2026-07-18 a restore "succeeded"
# while the server quietly served a freshly generated EMPTY world, because Palworld
# records which save to load in GameUserSettings.ini and does not just pick up an
# existing directory. Checking the served world GUID is the whole point.
$ErrorActionPreference = "Continue"
$expectedGuid = "E02C5819443F44ED89133A6C03B43E25"
$saveRoot = "D:\PalServer\SaveGames"
$gus = "C:\PalServer\Pal\Saved\Config\WindowsServer\GameUserSettings.ini"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-Output "=== 1. stop server ==="
Get-Process -Name PalServer-Win64-Shipping -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 8

Write-Output "=== 2. download backup ==="
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest -Uri $env:BACKUP_URL -OutFile C:\Windows\Temp\drill.tgz
$size = (Get-Item C:\Windows\Temp\drill.tgz).Length
Write-Output "downloaded: $size bytes"
if ($size -lt 10000000) { Write-Output "DRILL FAILED: download too small"; exit 1 }

Write-Output "=== 3. set the test world aside ==="
if (Test-Path "$saveRoot\0") {
  Move-Item "$saveRoot\0" "D:\PalServer\testworld-$stamp" -Force
  Write-Output "test world parked at D:\PalServer\testworld-$stamp"
}
New-Item -ItemType Directory -Force -Path $saveRoot | Out-Null

Write-Output "=== 4. extract ==="
# bsdtar ships with Windows Server 2022 and handles .tgz natively.
tar -xzf C:\Windows\Temp\drill.tgz -C $saveRoot
if (-not (Test-Path "$saveRoot\0\$expectedGuid\Level.sav")) {
  Write-Output "DRILL FAILED: Level.sav missing after extract"
  exit 1
}
$levelSize = (Get-Item "$saveRoot\0\$expectedGuid\Level.sav").Length
$players = (Get-ChildItem "$saveRoot\0\$expectedGuid\Players\*.sav" -ErrorAction SilentlyContinue).Count
Write-Output "Level.sav: $levelSize bytes, player saves: $players"
if ($players -lt 1) { Write-Output "DRILL FAILED: no player saves in the backup"; exit 1 }

Write-Output "=== 5. point the server at the restored world ==="
(Get-Content $gus) -replace '^DedicatedServerName=.*', "DedicatedServerName=$expectedGuid" | Set-Content $gus
Select-String -Path $gus -Pattern '^DedicatedServerName=' | ForEach-Object { $_.Line }

Write-Output "=== 6. start and see what it actually serves ==="
Start-Process -FilePath "C:\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe" `
  -ArgumentList "Pal", "-port=8211", "-players=16", "-log" -WorkingDirectory "C:\PalServer" -WindowStyle Hidden
Start-Sleep -Seconds 150

$conf = Get-Content C:\PalServer\idle.conf.json -Raw | ConvertFrom-Json
$sec = ConvertTo-SecureString $conf.AdminPassword -AsPlainText -Force
$cred = New-Object PSCredential("admin", $sec)
try {
  $info = Invoke-RestMethod -Uri "http://127.0.0.1:8212/v1/api/info" -Credential $cred -TimeoutSec 10 -ErrorAction Stop
  Write-Output "served worldguid: $($info.worldguid)"
  if ($info.worldguid -eq $expectedGuid) {
    Write-Output "DRILL PASSED: restored world is being served"
  } else {
    Write-Output "DRILL FAILED: serving $($info.worldguid), expected $expectedGuid (the empty-world trap)"
    exit 1
  }
} catch {
  Write-Output "DRILL FAILED: REST did not answer: $($_.Exception.Message)"
  exit 1
}
Remove-Item C:\Windows\Temp\drill.tgz -Force -ErrorAction SilentlyContinue
