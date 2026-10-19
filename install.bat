@echo off
setlocal enabledelayedexpansion
title BlackoutMod v3.0 - Installer
color 0A
cd /d "%~dp0"

set "SERVER=https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies"

echo ==========================================
echo    BlackoutMod v3.0 - Installer
echo ==========================================
echo.
echo   1 = Install / Update
echo   2 = Uninstall
echo.
set "MODE="
set /p MODE="Choose [1]: "
if not defined MODE set "MODE=1"
cls

REM ==========================================================
REM  Locate game
REM ==========================================================
echo ==========================================
echo    Locating LOCKDOWN Protocol
echo ==========================================
echo.
call :find_game

if defined GAME_PATH (
    echo [OK] Found: !GAME_PATH!
) else (
    echo Could not automatically find LOCKDOWN Protocol.
    echo Steam: right-click the game, Manage, Browse local files
    echo.
    call :ask_game_path
)

set "BIN_PATH=!GAME_PATH!\LockdownProtocol\Binaries\Win64"
set "LUA_TARGET=!BIN_PATH!\ue4ss\Mods\BlackoutMod"
set "PAK_TARGET=!GAME_PATH!\LockdownProtocol\Content\Paks\LogicMods"
set "CFG=!LUA_TARGET!\config.txt"
echo.

tasklist 2>nul | findstr /i "LockdownProtocol" >nul
if not errorlevel 1 (
    echo WARNING: The game is running. Please close it first.
    echo.
    pause
)

if "!MODE!"=="2" goto :uninstall

REM ==========================================================
REM  Check package
REM ==========================================================
if not exist "Dependencies\UE4SS\dwmapi.dll" goto :missing_files
if not exist "Mods\BlackoutMod\Scripts\main.lua" goto :missing_files
if not exist "LogicMods\BlackoutMod.pak" goto :missing_files

timeout /t 1 >nul
cls

REM ==========================================================
REM  Existing settings
REM ==========================================================
set "CODE="
set "OWNER_KEY="
set "SABO=1"
set "COOLDOWN=0"
set "DURATION=0"

if exist "!CFG!" call :read_config "!CFG!"

if not defined CODE goto :setup

echo ==========================================
echo    Existing settings found
echo ==========================================
echo.
echo   Lobby code: !CODE!
if defined OWNER_KEY (
    echo   You are the host of this lobby.
)
echo.

set "KEEP_DEFAULT=1"
if "!CODE:~5,1!"=="" (
    set "KEEP_DEFAULT=2"
    echo   WARNING: This code is short and easy to guess.
    echo   Short codes also can't have shared lobby settings.
    echo   Recommended: the host creates a NEW lobby with option 2
    echo   and tells everyone the new code.
    echo.
)

echo   1 = Keep these settings, just update the mod
echo   2 = New setup ^(create or join a lobby^)
echo.
set "KEEP="
set /p KEEP="Choose [!KEEP_DEFAULT!]: "
if not defined KEEP set "KEEP=!KEEP_DEFAULT!"
if "!KEEP!"=="1" goto :install
cls

REM ==========================================================
REM  Setup: create or join
REM ==========================================================
:setup
set "OWNER_KEY="
set "SABO=1"
set "COOLDOWN=0"
set "DURATION=0"

echo ==========================================
echo    Lobby
echo ==========================================
echo.
echo Everyone in your group uses the same lobby code.
echo The host creates the lobby and chooses the settings,
echo everyone else just joins with the code.
echo.
echo   1 = Create a new lobby ^(you are the host^)
echo   2 = Join a lobby ^(your host gave you a code^)
echo.
set "ROLE="
set /p ROLE="Choose [1]: "
if not defined ROLE set "ROLE=1"
cls
if "!ROLE!"=="2" goto :join

REM ---------------- create ----------------
:create
set "SETTINGS_DONE="
echo ==========================================
echo    Create a lobby
echo ==========================================
echo.
echo Press Enter for a random code ^(recommended^),
echo or type your own code: 6-8 letters/digits, - and _ allowed.
echo.
:create_code
set "CODE="
set /p CODE="Lobby code: "
if not defined CODE (
    call :random_code
    echo Generated code: !CODE!
)
set "CODE=!CODE: =!"
call :valid_code
if "!CODE_OK!"=="0" goto :create_code
if "!CODE:~5,1!"=="" (
    echo ERROR: A new lobby needs at least 6 characters.
    goto :create_code
)
if not "!CODE:~8,1!"=="" (
    echo ERROR: At most 8 characters.
    goto :create_code
)
echo.
if defined SETTINGS_DONE goto :create_on_server

echo ------------------------------------------
echo  Lobby settings ^(shared with all players^)
echo ------------------------------------------
echo.
echo HOW OFTEN: How many times can a Dissident sabotage per round?
echo   0 = unlimited
call :ask_number SABO "Max sabotages per round" 1 99
echo.
echo HOW OFTEN: After the lights come back, how many seconds must pass
echo before the next sabotage is possible?
echo   0 = no waiting
call :ask_number COOLDOWN "Cooldown in seconds" 0 3600
echo.
echo HOW LONG: After how many seconds do the lights come back by themselves,
echo even if nobody dies and no batteries are inserted?
echo   0 = never, only by a death, batteries or returning to the lobby
call :ask_number DURATION "Max blackout duration in seconds" 0 3600
echo.
set "SETTINGS_DONE=1"

:create_on_server

REM Secret key: only the host can change the lobby settings later
set "OWNER_KEY="
for /f %%g in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString('N')"') do set "OWNER_KEY=%%g"
if not defined OWNER_KEY (
    echo ERROR: Could not generate a host key ^(PowerShell missing?^).
    pause
    exit /b 1
)

set "LOBBY_JSON=%TEMP%\blackoutmod_lobby.json"
>"!LOBBY_JSON!" echo {"owner":"!OWNER_KEY!","settings":{"key":"!OWNER_KEY!","values":{"maxSabotages":!SABO!,"cooldown":!COOLDOWN!,"maxDuration":!DURATION!}}}

echo Creating lobby on the server...
set "HTTP="
for /f %%s in ('curl -s -o nul -w "%%{http_code}" -X PATCH -H "Content-Type: application/json" -d @"!LOBBY_JSON!" "!SERVER!/!CODE!.json"') do set "HTTP=%%s"
del "!LOBBY_JSON!" >nul 2>&1

if "!HTTP!"=="200" (
    echo [OK] Lobby !CODE! created. You are the host.
) else if "!HTTP!"=="401" (
    echo.
    echo ERROR: The code !CODE! is already taken. Please choose another one.
    echo.
    goto :create_code
) else (
    echo.
    echo ERROR: Could not reach the server ^(HTTP !HTTP!^).
    echo Check your internet connection. curl is needed ^(included in Windows 10/11^).
    pause
    exit /b 1
)
echo.
goto :join_done

REM ---------------- join ----------------
:join
echo ==========================================
echo    Join a lobby
echo ==========================================
echo.
:join_code
set "CODE="
set /p CODE="Lobby code from your host: "
if not defined CODE goto :join_code
set "CODE=!CODE: =!"
call :valid_code
if "!CODE_OK!"=="0" goto :join_code
if "!CODE:~3,1!"=="" (
    echo ERROR: Codes have at least 4 characters.
    goto :join_code
)
set "CODE=!CODE:~0,8!"
echo.
echo Checking lobby...
powershell -NoProfile -Command "try { $v = Invoke-RestMethod '!SERVER!/!CODE!/settings/values.json' } catch { $v = $null }; if ($v -and $v -isnot [string] -and $v.maxSabotages -ne $null) { Write-Host '[OK] Lobby found. Host settings:'; Write-Host ('  Sabotages per round: ' + $(if ($v.maxSabotages -eq 0) {'unlimited'} else {$v.maxSabotages})); Write-Host ('  Cooldown: ' + $(if ($v.cooldown -eq 0) {'off'} else {[string]$v.cooldown + 's'})); Write-Host ('  Max blackout duration: ' + $(if ($v.maxDuration -eq 0) {'off'} else {[string]$v.maxDuration + 's'})) } else { Write-Host 'This lobby has no shared settings (older lobby or code typo).'; Write-Host 'Default settings will be used. Double-check the code with your host.' }"
echo.
if "!CODE:~5,1!"=="" (
    echo NOTE: Short code. Ask your host to create a new lobby with 6-8 characters.
    echo.
)

:join_done
timeout /t 1 >nul
cls

REM ==========================================================
REM  Install
REM ==========================================================
:install
echo ==========================================
echo    Installing BlackoutMod
echo ==========================================
echo.

if exist "!BIN_PATH!\dwmapi.dll" (
    echo UE4SS is already installed.
    set "REINSTALL="
    set /p REINSTALL="Reinstall UE4SS? (Y/N) [N]: "
    if /i not "!REINSTALL!"=="Y" (
        echo Skipping UE4SS.
        goto :skip_ue4ss
    )
)

echo [1/4] Installing UE4SS...
xcopy /Y /E /I "Dependencies\UE4SS\*" "!BIN_PATH!\" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Failed to install UE4SS. Try running as administrator.
    pause
    exit /b 1
)
echo [OK] UE4SS installed
:skip_ue4ss
echo.

echo [2/4] Installing Lua mod...
if not exist "!LUA_TARGET!" mkdir "!LUA_TARGET!"
xcopy /Y /E /I "Mods\BlackoutMod\*" "!LUA_TARGET!\" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Failed to install the Lua mod. Try running as administrator.
    pause
    exit /b 1
)
echo [OK] Lua mod installed
echo.

echo [3/4] Writing settings...
(
    echo # BlackoutMod v3 settings, written by install.bat
    echo # Edit and press F5 in-game to reload.
    echo LobbyCode=!CODE!
    echo.
    if defined OWNER_KEY (
        echo # You are the lobby host: these settings are shared with everyone in the lobby.
        echo # Keep the OwnerKey secret, it allows changing the lobby settings.
        echo OwnerKey=!OWNER_KEY!
    ) else (
        echo # Only used if the lobby has no shared settings from a host:
    )
    echo MaxSabotagesPerRound=!SABO!
    echo Cooldown=!COOLDOWN!
    echo MaxBlackoutDuration=!DURATION!
)>"!CFG!"
if errorlevel 1 (
    echo ERROR: Could not write !CFG!
    pause
    exit /b 1
)
echo [OK] Settings saved
echo.

echo [4/4] Installing Blueprint mod...
if not exist "!PAK_TARGET!" mkdir "!PAK_TARGET!"
copy /Y "LogicMods\BlackoutMod.pak" "!PAK_TARGET!\" >nul 2>&1 || goto :pak_failed
copy /Y "LogicMods\BlackoutMod.ucas" "!PAK_TARGET!\" >nul 2>&1 || goto :pak_failed
copy /Y "LogicMods\BlackoutMod.utoc" "!PAK_TARGET!\" >nul 2>&1 || goto :pak_failed
echo [OK] Blueprint mod installed
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    INSTALLATION COMPLETE
echo ==========================================
echo.
echo   Game:       !GAME_PATH!
echo   Lobby code: !CODE!
if defined OWNER_KEY (
    echo   You are the host. Share the code with your friends,
    echo   they choose "Join a lobby" in this installer.
)
echo   Settings:   !CFG!
echo.
echo KEYS IN-GAME:
echo   O  = Sabotage ^(Dissident only, near a defibrillator^)
echo   L  = Lobby code and settings
echo   I  = Debug info ^(check code and sync^)
echo   F5 = Reload config.txt
echo.
echo Lights come back when someone dies, batteries are inserted,
echo players return to the lobby, or the max duration is reached.
echo.
echo Need help? See README.txt or the Nexus Mods page.
echo.
pause
exit /b 0

REM ==========================================================
REM  Uninstall
REM ==========================================================
:uninstall
echo ==========================================
echo    Uninstall BlackoutMod
echo ==========================================
echo.
echo This removes:
echo   !LUA_TARGET!
echo   !PAK_TARGET!\BlackoutMod.*
echo.
set "CONFIRM="
set /p CONFIRM="Uninstall BlackoutMod? (Y/N): "
if /i not "!CONFIRM!"=="Y" (
    echo Cancelled.
    pause
    exit /b 0
)

if exist "!LUA_TARGET!" rmdir /s /q "!LUA_TARGET!"
del /q "!PAK_TARGET!\BlackoutMod.pak" "!PAK_TARGET!\BlackoutMod.ucas" "!PAK_TARGET!\BlackoutMod.utoc" >nul 2>&1
echo [OK] BlackoutMod removed
echo.

if exist "!BIN_PATH!\dwmapi.dll" (
    echo UE4SS is the mod loader. Only remove it if no other mods use it.
    set "REMOVE_UE4SS="
    set /p REMOVE_UE4SS="Also remove UE4SS? (Y/N) [N]: "
    if /i "!REMOVE_UE4SS!"=="Y" (
        del /q "!BIN_PATH!\dwmapi.dll" >nul 2>&1
        if exist "!BIN_PATH!\ue4ss" rmdir /s /q "!BIN_PATH!\ue4ss"
        echo [OK] UE4SS removed
    )
)
echo.
echo Uninstall complete.
pause
exit /b 0

REM ==========================================================
REM  Errors
REM ==========================================================
:missing_files
echo ERROR: Installer files not found.
echo Extract the whole package first. It must contain:
echo   Dependencies\UE4SS\
echo   Mods\BlackoutMod\
echo   LogicMods\BlackoutMod.pak
echo.
pause
exit /b 1

:pak_failed
echo ERROR: Failed to install the Blueprint mod. Try running as administrator.
pause
exit /b 1

REM ==========================================================
REM  Subroutines
REM ==========================================================

REM Finds the game through Steam's registry entry and all Steam libraries
:find_game
set "GAME_PATH="
set "STEAM_PATH="
for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Valve\Steam" /v SteamPath 2^>nul ^| findstr /c:"SteamPath"') do set "STEAM_PATH=%%b"
if not defined STEAM_PATH (
    for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\WOW6432Node\Valve\Steam" /v InstallPath 2^>nul ^| findstr /c:"InstallPath"') do set "STEAM_PATH=%%b"
)
if defined STEAM_PATH (
    set "STEAM_PATH=!STEAM_PATH:/=\!"
    call :check_library "!STEAM_PATH!"
    if not defined GAME_PATH if exist "!STEAM_PATH!\steamapps\libraryfolders.vdf" (
        for /f "usebackq tokens=1,*" %%a in ("!STEAM_PATH!\steamapps\libraryfolders.vdf") do (
            if /i "%%~a"=="path" if not defined GAME_PATH call :check_library "%%~b"
        )
    )
)
if defined GAME_PATH exit /b 0

REM Fallback: common library locations
for %%d in (C D E F G H I J) do (
    if not defined GAME_PATH call :check_library "%%d:\SteamLibrary"
    if not defined GAME_PATH call :check_library "%%d:\Steam"
    if not defined GAME_PATH call :check_library "%%d:\Program Files (x86)\Steam"
    if not defined GAME_PATH call :check_library "%%d:\Program Files\Steam"
)
exit /b 0

:check_library
REM %%~f normalizes the path (libraryfolders.vdf uses double backslashes)
for %%p in ("%~1") do set "LIBRARY=%%~fp"
if exist "!LIBRARY!\steamapps\common\LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64" (
    set "GAME_PATH=!LIBRARY!\steamapps\common\LOCKDOWN Protocol"
)
exit /b 0

:ask_game_path
set "GAME_PATH="
set /p "GAME_PATH=Enter the game folder path: "
if not defined GAME_PATH goto :ask_game_path
set "GAME_PATH=!GAME_PATH:"=!"
if "!GAME_PATH:~-1!"=="\" set "GAME_PATH=!GAME_PATH:~0,-1!"
if not exist "!GAME_PATH!\LockdownProtocol\Binaries\Win64" (
    echo ERROR: Not the game folder. It must contain LockdownProtocol\Binaries\Win64
    goto :ask_game_path
)
echo [OK] Found: !GAME_PATH!
exit /b 0

REM Reads config.txt: Key=Value (v3) or line 1 code, 2 max sabotages, 3 cooldown (v2.5)
:read_config
set "LINE_NO=0"
set "LEGACY_1="
set "LEGACY_2="
set "LEGACY_3="
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~1") do (
    set /a LINE_NO+=1
    if "%%b"=="" (
        set "LEGACY_!LINE_NO!=%%a"
    ) else (
        if /i "%%a"=="LobbyCode" set "CODE=%%b"
        if /i "%%a"=="OwnerKey" set "OWNER_KEY=%%b"
        if /i "%%a"=="MaxSabotagesPerRound" set "SABO=%%b"
        if /i "%%a"=="Cooldown" set "COOLDOWN=%%b"
        if /i "%%a"=="MaxBlackoutDuration" set "DURATION=%%b"
    )
)
if not defined CODE if defined LEGACY_1 (
    set "CODE=!LEGACY_1: =!"
    if defined LEGACY_2 set "SABO=!LEGACY_2: =!"
    if defined LEGACY_3 set "COOLDOWN=!LEGACY_3: =!"
)
exit /b 0

REM Sets CODE_OK=1 if CODE only has letters, digits, - and _
:valid_code
set "CODE_OK=1"
REM Everything allowed is a delimiter: any token left means a forbidden character
for /f "delims=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" %%x in ("!CODE!") do set "CODE_OK=0"
if "!CODE_OK!"=="0" echo ERROR: Only letters, digits, - and _ are allowed.
exit /b 0

REM Generates an 8 character code (no l/o/0/1 to avoid mix-ups)
:random_code
set "CHARS=abcdefghijkmnpqrstuvwxyz23456789"
set "CODE="
for /l %%i in (1,1,8) do (
    set /a "IDX=!RANDOM! %% 32"
    for %%j in (!IDX!) do set "CODE=!CODE!!CHARS:~%%j,1!"
)
exit /b 0

REM call :ask_number VAR "Prompt" default max
:ask_number
set "NUM_INPUT="
set /p NUM_INPUT="%~2 [%~3]: "
if not defined NUM_INPUT set "NUM_INPUT=%~3"
set "NUM_INPUT=!NUM_INPUT: =!"
set "NUM_OK=1"
for /f "delims=0123456789" %%x in ("!NUM_INPUT!") do set "NUM_OK=0"
if not "!NUM_INPUT:~5,1!"=="" set "NUM_OK=0"
if "!NUM_OK!"=="1" (
    REM Strip leading zeros, set /a would read "08" as octal
    for /f "tokens=* delims=0" %%z in ("!NUM_INPUT!") do set "NUM_INPUT=%%z"
    if not defined NUM_INPUT set "NUM_INPUT=0"
    if !NUM_INPUT! GTR %~4 set "NUM_OK=0"
)
if "!NUM_OK!"=="0" (
    echo   Please enter a number from 0 to %~4.
    goto :ask_number
)
set "%~1=!NUM_INPUT!"
exit /b 0
