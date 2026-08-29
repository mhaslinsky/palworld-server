@echo off
REM Headless Python against the project. -unattended and -nullrhi keep it off the GPU and stop
REM it waiting on any dialog, which is what makes this viable from an SSH session that has no
REM console session to draw into.
set "UE=D:\Program Files\Epic Games\UE_5.1"
set "PROJ=C:\Dev\PalworldModdingKit\Pal.uproject"
set "SCRIPT=%~1"

echo === running %SCRIPT% headless ===
"%UE%\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "%PROJ%" -run=pythonscript -script="%SCRIPT%" -unattended -nopause -nosplash -nullrhi -stdout -FullStdOutLogOutput
echo === PY_EXIT=%ERRORLEVEL% ===
