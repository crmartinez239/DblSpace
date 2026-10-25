@echo off
rem build.bat - builds dist\dblspace.exe, then the installer into dist\
rem Needs FreeBASIC 1.10 (64-bit) and Inno Setup 6.
setlocal
cd /d "%~dp0"

set "FBC=C:\Program Files\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\fbc64.exe"
set "ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"
if not exist "%ISCC%" set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"

if not exist dist mkdir dist

rem If dist\dblspace.exe is running it's locked - ask it to exit first.
rem (An installed copy elsewhere is left alone.)
powershell -NoProfile -Command "$p = [IO.Path]::GetFullPath('dist\dblspace.exe'); Get-Process dblspace -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $p } | ForEach-Object { taskkill /pid $_.Id | Out-Null; $_.WaitForExit(5000) | Out-Null }"

rem GoRC needs Windows (CRLF) line endings in the .rc - editors sometimes
rem change them, so fix them every time
powershell -NoProfile -Command "$t = [IO.File]::ReadAllText('src\dblspace.rc') -replace '\r?\n', ([string][char]13 + [char]10); [IO.File]::WriteAllText('src\dblspace.rc', $t)"

echo === Building dist\dblspace.exe
rem Run from src so the .rc finds its icons and manifest
pushd src
"%FBC%" -s gui -mt -w all dblspace.bas dblspace.rc -x ..\dist\dblspace.exe
set "ERR=%ERRORLEVEL%"
popd
if not "%ERR%"=="0" goto :fail

echo === Building installer
"%ISCC%" /Q installer\dblspace.iss || goto :fail

echo.
echo Done. Program and installer are in the "dist" folder.
exit /b 0

:fail
echo.
echo BUILD FAILED
exit /b 1
