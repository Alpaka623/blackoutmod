@echo off
REM Builds Mods\BlackoutMod\Scripts\BlackoutHelper.exe from tools\helper\BlackoutHelper.cs
REM with the C# compiler that ships with .NET Framework 4.x (part of Windows 10/11).
setlocal
cd /d "%~dp0.."

set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    echo ERROR: .NET Framework 4 C# compiler not found.
    exit /b 1
)

REM /target:winexe = never opens a console window of its own
"%CSC%" /nologo /optimize+ /target:winexe /platform:anycpu ^
    /reference:System.Net.Http.dll ^
    /out:"Mods\BlackoutMod\Scripts\BlackoutHelper.exe" ^
    "tools\helper\BlackoutHelper.cs"
if errorlevel 1 (
    echo ERROR: Build failed.
    exit /b 1
)
echo [OK] Mods\BlackoutMod\Scripts\BlackoutHelper.exe
