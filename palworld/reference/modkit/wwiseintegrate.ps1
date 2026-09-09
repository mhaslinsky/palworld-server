$ErrorActionPreference = "Stop"
$archive = "C:\Users\mhasl\OneDrive\Documents\Wwise_Unreal_Integration_2021.1.11.2437\Unreal.5.0.tar.xz"
$kit     = "C:\Dev\PalworldModdingKit"
$sdk     = "D:\Audiokinetic\Wwise_2021.1.11.7933\SDK"
$stage   = "C:\Dev\wwise-stage"

function Say($msg) { Write-Output ("[wwise] " + $msg) }

if (-not (Test-Path $archive)) { Say "ARCHIVE MISSING"; exit 1 }
if (-not (Test-Path $sdk))     { Say "SDK MISSING"; exit 1 }

# 1. Unpack. Windows ships bsdtar as tar.exe, which reads .tar.xz directly. The guide warns it
# may need unpacking twice, so unpack and then look for a nested .tar rather than assuming.
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
Say "unpacking"
& tar -xf $archive -C $stage
$nested = Get-ChildItem $stage -Filter "*.tar" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nested) { Say ("second unpack: " + $nested.Name); & tar -xf $nested.FullName -C $stage; Remove-Item $nested.FullName -Force }
Say ("stage contains: " + ((Get-ChildItem $stage -Directory).Name -join ", "))

# 2. Locate the plugin root by its descriptor, not by an assumed folder name.
$uplugin = Get-ChildItem $stage -Recurse -Filter "Wwise.uplugin" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uplugin) { Say "NO Wwise.uplugin IN ARCHIVE"; exit 1 }
$src = $uplugin.Directory.FullName
Say ("plugin root: " + $src)

$dest = Join-Path $kit "Plugins\Wwise"
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Say "copying plugin into the kit"
Copy-Item $src $dest -Recurse -Force

# 3 and 4. ThirdParty, built from the SDK.
$third = Join-Path $dest "ThirdParty"
New-Item -ItemType Directory -Path $third -Force | Out-Null
foreach ($name in @("Win32_vc170", "x64_vc170", "include")) {
  $from = Join-Path $sdk $name
  if (-not (Test-Path $from)) { Say ("SDK PIECE MISSING: " + $name); exit 1 }
  Say ("copying " + $name)
  Copy-Item $from (Join-Path $third $name) -Recurse -Force
}

# 5. The guide wants vc160 duplicates alongside the vc170 ones.
foreach ($pair in @(@("Win32_vc170","Win32_vc160"), @("x64_vc170","x64_vc160"))) {
  $from = Join-Path $third $pair[0]
  $to   = Join-Path $third $pair[1]
  if (-not (Test-Path $to)) { Say ("duplicating " + $pair[0] + " -> " + $pair[1]); Copy-Item $from $to -Recurse -Force }
}

# 6. Patch EngineVersion with a targeted text replace written WITHOUT a BOM. A JSON round trip
# reformatted Pal.uproject earlier and Set-Content -Encoding UTF8 added a BOM, which the Wwise
# Launcher rejected as "not a valid Unreal Engine project".
$upath = Join-Path $dest "Wwise.uplugin"
$text = [System.IO.File]::ReadAllText($upath)
$before = ([regex]::Match($text, '"EngineVersion"\s*:\s*"([^"]+)"')).Groups[1].Value
$text = [regex]::Replace($text, '("EngineVersion"\s*:\s*")[^"]+(")', '${1}5.1${2}')
[System.IO.File]::WriteAllText($upath, $text, (New-Object System.Text.UTF8Encoding($false)))
$after = ([regex]::Match([System.IO.File]::ReadAllText($upath), '"EngineVersion"\s*:\s*"([^"]+)"')).Groups[1].Value
Say ("EngineVersion " + $before + " -> " + $after)

$bytes = [System.IO.File]::ReadAllBytes($upath)
Say ("uplugin BOM " + ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF))
Say ("ThirdParty: " + ((Get-ChildItem $third -Directory).Name -join ", "))
Say "DONE"
