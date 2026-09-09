@echo off
REM Run as a FILE on the box. Passing this through ssh -> cmd -> Build.bat inline breaks on the
REM space in "D:\Program Files": the nested quoting collapses and cmd reports
REM 'D:\Program' is not recognized, while STILL exiting 0. A silent success on a build is the
REM worst possible failure mode, hence both the file and the explicit exit code below.
set "UE=D:\Program Files\Epic Games\UE_5.1"
set "PROJ=C:\Dev\PalworldModdingKit\Pal.uproject"

echo === building PalEditor Win64 Development ===
call "%UE%\Engine\Build\BatchFiles\Build.bat" PalEditor Win64 Development -Project="%PROJ%" -WaitMutex -FromMsBuild
set BUILD_EXIT=%ERRORLEVEL%
echo === BUILD_EXIT=%BUILD_EXIT% ===
exit /b %BUILD_EXIT%
