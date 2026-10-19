@echo off
setlocal enabledelayedexpansion
title BlackoutMod - One-Click Installer
color 0A

echo ==========================================
echo    BlackoutMod - One-Click Installer
echo ==========================================
echo.
echo This installer will automatically install:
echo - UE4SS Experimental ^(includes BPModLoaderMod^)
echo - BlackoutMod ^(Lua + Blueprint^)
echo.
echo Press any key to continue...
pause >nul
cls

echo ==========================================
echo    Step 1/4: Configure Lobby Code
echo ==========================================
echo.
echo BlackoutMod uses a shared server with lobby codes.
echo This means NO complex setup - just enter a code!
echo.
echo How it works:
echo   - Host creates/chooses a 4-8 digit code
echo   - Host shares code with friends ^(voice/discord^)
echo   - Everyone enters the SAME code
echo   - You're all synchronized!
echo.
echo Enter your lobby code ^(4-8 letters/digits, 6-8 recommended^):
echo   - Joining friends? Enter THEIR code
echo   - Hosting? Just press Enter to get a random code
echo.

:ask_code
set "LOBBY_CODE="
set /p LOBBY_CODE="Lobby Code: "

REM Empty checks use "defined": substitutions on an undefined variable don't expand to ""
if not defined LOBBY_CODE goto :no_code

REM Remove quotes if user pasted them
set LOBBY_CODE=!LOBBY_CODE:"=!

REM Remove spaces
set "LOBBY_CODE=!LOBBY_CODE: =!"

if defined LOBBY_CODE goto :have_code

:no_code
REM Empty input: generate a random code (short codes are easy to guess)
call :random_code
echo.
echo Generated random code: !LOBBY_CODE!
echo Share this code with your friends!

:have_code

REM Limit to 8 characters
set "LOBBY_CODE=!LOBBY_CODE:~0,8!"

REM At least 4 characters, otherwise the mod ignores the code
if "!LOBBY_CODE:~3,1!"=="" (
    echo.
    echo ERROR: Code must be at least 4 characters!
    echo.
    goto :ask_code
)

if "!LOBBY_CODE:~5,1!"=="" (
    echo.
    echo WARNING: Short codes are easy to guess. 6-8 characters are safer.
)

echo.
echo [OK] Lobby code set: !LOBBY_CODE!
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    Step 2/5: Sabotage Limit
echo ==========================================
echo.
echo How many times can a Dissident sabotage per round?
echo.
echo   0 = Unlimited
echo   1 = Once per round ^(recommended^)
echo   2 = Twice per round
echo   3 = Three times per round
echo   etc.
echo.
set /p MAX_SABO="Max sabotages per round [1]: "

if "!MAX_SABO!"=="" set MAX_SABO=1

REM Validate: must be a number >= 0
set "VALID_NUM=true"
for /f "delims=0123456789" %%a in ("!MAX_SABO!") do set "VALID_NUM=false"
if "!VALID_NUM!"=="false" (
    echo.
    echo WARNING: Invalid input, using default: 1
    set MAX_SABO=1
)

echo.
if "!MAX_SABO!"=="0" (
    echo [OK] Sabotage limit: Unlimited
) else (
    echo [OK] Sabotage limit: !MAX_SABO!x per round
)
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    Step 3/5: Checking Files
echo ==========================================
echo.

REM Check if files are in the right place
if not exist "Dependencies\UE4SS\dwmapi.dll" (
    echo ERROR: UE4SS files not found!
    echo.
    echo Please make sure the installer package contains:
    echo - Dependencies\UE4SS\
    echo - Mods\BlackoutMod\
    echo - LogicMods\BlackoutMod.pak
    echo.
    pause
    exit /b 1
)

if not exist "Mods\BlackoutMod\Scripts\main.lua" (
    echo ERROR: BlackoutMod files not found!
    echo.
    pause
    exit /b 1
)

echo [OK] All files present
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    Step 4/5: Locating Game
echo ==========================================
echo.

REM Try to find Steam installation
set "GAME_PATH="

echo Searching for LOCKDOWN Protocol...
echo.

REM Check common Steam paths
for %%d in (C D E F G H I J) do (
    if exist "%%d:\SteamLibrary\steamapps\common\LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64" (
        set "GAME_PATH=%%d:\SteamLibrary\steamapps\common\LOCKDOWN Protocol"
        goto :found
    )
    if exist "%%d:\Steam\steamapps\common\LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64" (
        set "GAME_PATH=%%d:\Steam\steamapps\common\LOCKDOWN Protocol"
        goto :found
    )
    if exist "%%d:\Program Files (x86)\Steam\steamapps\common\LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64" (
        set "GAME_PATH=%%d:\Program Files (x86)\Steam\steamapps\common\LOCKDOWN Protocol"
        goto :found
    )
    if exist "%%d:\Program Files\Steam\steamapps\common\LOCKDOWN Protocol\LockdownProtocol\Binaries\Win64" (
        set "GAME_PATH=%%d:\Program Files\Steam\steamapps\common\LOCKDOWN Protocol"
        goto :found
    )
)

REM Manual input
echo Could not automatically find LOCKDOWN Protocol.
echo.
:input_path
set /p "GAME_PATH=Enter game folder path: "
set "GAME_PATH=!GAME_PATH:"=!"
if "!GAME_PATH:~-1!"=="\" set "GAME_PATH=!GAME_PATH:~0,-1!"

if not exist "!GAME_PATH!\LockdownProtocol\Binaries\Win64" (
    echo.
    echo ERROR: Invalid path!
    echo.
    goto :input_path
)

:found
echo [OK] Found: !GAME_PATH!
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    Step 5/5: Installing BlackoutMod
echo ==========================================
echo.

set "BIN_PATH=!GAME_PATH!\LockdownProtocol\Binaries\Win64"

REM Check if UE4SS already installed
if exist "!BIN_PATH!\dwmapi.dll" (
    echo UE4SS is already installed.
    set /p "REINSTALL=Reinstall? (Y/N): "
    if /i not "!REINSTALL!"=="Y" (
        echo Skipping UE4SS installation.
        goto :skip_ue4ss
    )
)

echo [1/4] Installing UE4SS Experimental Latest...
echo ^(includes BPModLoaderMod^)
echo.

REM Copy UE4SS files
xcopy /Y /E /I "Dependencies\UE4SS\*" "!BIN_PATH!\" >nul 2>&1

if errorlevel 1 (
    echo ERROR: Failed to install UE4SS!
    pause
    exit /b 1
)

echo [OK] UE4SS installed successfully
echo [OK] BPModLoaderMod included with UE4SS
:skip_ue4ss
echo.

REM Install Lua Mod
set "LUA_TARGET=!BIN_PATH!\ue4ss\Mods\BlackoutMod"

if not exist "!LUA_TARGET!" mkdir "!LUA_TARGET!"
if not exist "!LUA_TARGET!\Scripts" mkdir "!LUA_TARGET!\Scripts"

echo [2/4] Installing Lua files...
xcopy /Y /E /I "Mods\BlackoutMod\*" "!LUA_TARGET!\" >nul 2>&1

if errorlevel 1 (
    echo ERROR: Failed to install Lua mod!
    pause
    exit /b 1
)

echo [OK] Lua mod installed
echo.

REM Create config.txt with lobby code and sabotage limit
echo [3/4] Configuring mod settings...

(
    echo !LOBBY_CODE!
    echo !MAX_SABO!
)>"!LUA_TARGET!\config.txt"

if errorlevel 1 (
    echo WARNING: Could not create config.txt
    echo You'll need to manually create it
    pause
) else (
    echo [OK] Lobby code configured: !LOBBY_CODE!
    if "!MAX_SABO!"=="0" (
        echo [OK] Sabotage limit: Unlimited
    ) else (
        echo [OK] Sabotage limit: !MAX_SABO!x per round
    )
)

echo.

REM Install Blueprint Mod
set "PAK_TARGET=!GAME_PATH!\LockdownProtocol\Content\Paks\LogicMods"

if not exist "!PAK_TARGET!" mkdir "!PAK_TARGET!"

echo [4/4] Installing Blueprint files...
copy /Y "LogicMods\BlackoutMod.pak" "!PAK_TARGET!\" >nul 2>&1
copy /Y "LogicMods\BlackoutMod.ucas" "!PAK_TARGET!\" >nul 2>&1
copy /Y "LogicMods\BlackoutMod.utoc" "!PAK_TARGET!\" >nul 2>&1

if errorlevel 1 (
    echo ERROR: Failed to install Blueprint mod!
    pause
    exit /b 1
)

echo [OK] Blueprint mod installed
echo.
timeout /t 1 >nul
cls

echo ==========================================
echo    INSTALLATION COMPLETE!
echo ==========================================
echo.
echo Successfully installed:
echo [X] UE4SS Experimental Latest
echo [X] BPModLoaderMod ^(included with UE4SS^)
echo [X] BlackoutMod Lua
echo [X] BlackoutMod Blueprint
echo [X] Lobby Code: !LOBBY_CODE!
if "!MAX_SABO!"=="0" (
    echo [X] Sabotage Limit: Unlimited
) else (
    echo [X] Sabotage Limit: !MAX_SABO!x per round
)
echo.
echo Installation location:
echo !GAME_PATH!
echo.
echo Config file location:
echo !LUA_TARGET!\config.txt
echo.
echo ==========================================
echo    IMPORTANT: LOBBY CODE
echo ==========================================
echo.
echo Your current lobby code: !LOBBY_CODE!
echo.
echo To play with friends:
echo   1. Share this code with your friends
echo   2. Everyone must use the SAME code
echo   3. All players will be synchronized!
echo.
echo To change settings:
echo   Option 1: Edit config.txt manually
echo            ^(!LUA_TARGET!\config.txt^)
echo            Line 1 = Lobby Code
echo            Line 2 = Max Sabotages ^(0 = unlimited^)
echo   Option 2: Run this installer again
echo   Option 3: Press L in-game for lobby code instructions
echo.
echo Note: Restart game after changing settings!
echo.
echo ==========================================
echo    HOW TO USE
echo ==========================================
echo.
echo 1. Launch LOCKDOWN Protocol
echo 2. Look for "BlackoutMod LOADED" in UE4SS console
echo 3. Verify your lobby code matches friends ^(Press I^)
echo 4. Join a game as DISSIDENT
echo 5. Walk to a defibrillator
echo 6. Press O to sabotage!
echo.
echo KEYBINDS:
echo - O = Sabotage ^(Dissident only, near defibrillator^)
echo - P = Manual Repair ^(emergency^)
echo - I = Debug Info ^(check code ^& sync status^)
echo.
echo ==========================================
echo    TROUBLESHOOTING
echo ==========================================
echo.
echo Mod doesn't work?
echo 1. Check UE4SS console for errors ^(opens with game^)
echo 2. Press I in-game to verify lobby code is correct
echo 3. Make sure all players use the SAME lobby code
echo.
echo Not syncing with friends?
echo 1. Check everyone has the SAME lobby code ^(Press I^)
echo 2. Lobby codes are case-sensitive!
echo 3. Make sure everyone restarted after setting code
echo.
echo Need help? Check the README.md or Nexus Mods page.
echo.
echo Press any key to exit...
pause >nul
exit /b 0

REM Generates an 8 character code (no l/o/0/1 to avoid mix-ups)
:random_code
set "CHARS=abcdefghijkmnpqrstuvwxyz23456789"
set "LOBBY_CODE="
for /l %%i in (1,1,8) do (
    set /a "IDX=!RANDOM! %% 32"
    for %%j in (!IDX!) do set "LOBBY_CODE=!LOBBY_CODE!!CHARS:~%%j,1!"
)
exit /b 0
