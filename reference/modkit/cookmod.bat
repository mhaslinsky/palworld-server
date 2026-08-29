@echo off
REM Cook and package the LogicMod pak headlessly.
REM
REM -iostore is deliberately ABSENT: the wiki's GUI steps say to UNCHECK "Use Io Store", because
REM UE4SS's BPModLoader mounts a plain .pak and cannot read an .ucas/.utoc pair. Adding it here
REM would produce files that look like a successful package and load nothing.
REM
REM -manifests is what emits the chunk manifest the PrimaryAssetLabel drives; without it the
REM chunk id is ignored and everything lands in pakchunk0 with the whole game.
set "UE=D:\Program Files\Epic Games\UE_5.1"
set "PROJ=C:\Dev\PalworldModdingKit\Pal.uproject"
set "OUT=C:\Dev\modbuild"

echo === cooking ===
call "%UE%\Engine\Build\BatchFiles\RunUAT.bat" BuildCookRun ^
  -project="%PROJ%" ^
  -noP4 -platform=Win64 -clientconfig=Shipping ^
  -cook -pak -manifests -stage ^
  -build=false -compressed ^
  -archive -archivedirectory="%OUT%" ^
  -utf8output -nocompileeditor
set RC=%ERRORLEVEL%
echo === UAT_EXIT=%RC% ===

echo === paks produced ===
dir /s /b "%OUT%\*.pak" 2>nul
exit /b %RC%
