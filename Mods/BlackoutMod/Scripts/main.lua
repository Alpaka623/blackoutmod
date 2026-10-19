local ModName = "BlackoutMod"
local ModVersion = "3.0.0"
local ServerUrl = "https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies"

-- ============================================
-- CONFIGURATION
-- ============================================
local DebugForceDissident = false  -- TESTING ONLY: always treat local player as Dissident (keep false for release!)
local AllowManualRepair = false  -- P key repair (always allowed while DebugForceDissident is on)
local FlickerSoundFile = "ue4ss/Mods/BlackoutMod/Sounds/flicker.wav"
-- ============================================
-- CONFIGURATION END
-- ============================================

-- Settings below come from config.txt (see LoadConfig). The lobby settings
-- (sabotages, cooldown, duration) are replaced by the lobby host's
-- values from the server when the lobby has some.
local LobbyCode = "0000"
local OwnerKey = ""  -- Only the lobby host has one; allows changing the shared settings
local MaxSabotagesPerRound = 1  -- 0 = unlimited, any other number = max sabotages per round per dissident
local SabotageCooldown = 0  -- Seconds after the lights come back before the next sabotage (0 = off)
local MaxBlackoutDuration = 0  -- Seconds until lights come back automatically (0 = off)

local UEHelpers = require("UEHelpers")

local InteractionDistance = 300.0
local PollInterval = 1000  -- 1 second polling

-- Runs a callback off the game thread (for blocking curl calls)
local RunAsync = ExecuteAsync or function(callback) ExecuteWithDelay(0, callback) end

-- Performance optimizations
-- Role caching (reduces FindAllOf calls)
local CachedRole = nil
local LastRoleCheck = 0
local RoleCacheTimeout = 2000     -- Cache for 2 seconds

local CurrentServerState = false
local SabotageCount = 0
local LastSabotageTime = -100
local LastBlackoutEndTime = -100000  -- os.clock() when the lights last came back (for the cooldown)
local PlayersAliveAtStart = 0
local LivingPawnsAtStart = {}  -- FullName -> true, pawns alive when the blackout started

-- Local state changes win over the server for a few seconds, so an
-- async PUT that hasn't landed yet doesn't get reverted by the next poll
local LastLocalChangeTime = -100
local LocalChangeGrace = 5.0

-- Graphics values from before the blackout (restored afterwards)
local SavedGraphics = nil

-- HUD Variables
local IsNearCharger = false
local ModActor = nil

-- ============================================
-- LOBBY CODE LOADING
-- ============================================

function ParseBool(value)
    value = value:lower()
    if value == "true" or value == "1" or value == "yes" or value == "on" then return true end
    if value == "false" or value == "0" or value == "no" or value == "off" then return false end
    return nil
end

function ParseCount(value, max)
    local num = tonumber((value:gsub("[^%d]", "")))
    if num then return math.min(math.floor(num), max) end
    return nil
end

function SetLobbyCode(code)
    -- Same truncation as v2.5 so existing codes still match; only characters
    -- that are safe in the server URL and the curl command line are kept
    local cleaned = code:sub(1, 8):gsub("[^%w_%-]", "")
    if #cleaned >= 4 then
        LobbyCode = cleaned
        return true
    end
    print("BlackoutMod: Invalid lobby code in config.txt (need 4-8 letters/digits)")
    return false
end

-- config.txt is "Key=Value" per line (written by install.bat, # = comment).
-- Old v2.5 configs (line 1 code, line 2 max sabotages, line 3 cooldown) still work.
function LoadConfig()
    local configPath = "ue4ss/Mods/BlackoutMod/config.txt"

    -- Defaults, also when reloading
    LobbyCode = "0000"
    OwnerKey = ""
    MaxSabotagesPerRound = 1
    SabotageCooldown = 0
    MaxBlackoutDuration = 0

    local success, file = pcall(function()
        return io.open(configPath, "r")
    end)

    if not (success and file) then
        print("BlackoutMod: No config found, using defaults (Code: " .. LobbyCode .. ")")
        print("BlackoutMod: Run install.bat to configure!")
        return false
    end

    local lines = {}
    for line in file:lines() do
        line = line:gsub("\r", "")
        if not line:match("^%s*#") and line:match("%S") then
            table.insert(lines, line)
        end
    end
    file:close()

    local isKeyValue = false
    for _, line in ipairs(lines) do
        if line:find("=", 1, true) then isKeyValue = true end
    end

    if isKeyValue then
        for _, line in ipairs(lines) do
            local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key then
                key = key:lower()
                if key == "lobbycode" then
                    SetLobbyCode(value)
                elseif key == "ownerkey" then
                    OwnerKey = value:gsub("[^%w_%-]", "")
                elseif key == "maxsabotagesperround" then
                    MaxSabotagesPerRound = ParseCount(value, 99) or MaxSabotagesPerRound
                elseif key == "cooldown" then
                    SabotageCooldown = ParseCount(value, 3600) or SabotageCooldown
                elseif key == "maxblackoutduration" then
                    MaxBlackoutDuration = ParseCount(value, 3600) or MaxBlackoutDuration
                end
            end
        end
    else
        -- v2.5 format
        if lines[1] then SetLobbyCode(lines[1]) end
        if lines[2] then MaxSabotagesPerRound = ParseCount(lines[2], 99) or MaxSabotagesPerRound end
        if lines[3] then SabotageCooldown = ParseCount(lines[3], 3600) or SabotageCooldown end
    end

    print("BlackoutMod: Loaded Lobby Code: " .. LobbyCode)
    if #LobbyCode < 6 then
        print("BlackoutMod: WARNING: Short lobby codes are easy to guess and can't have shared settings.")
        print("BlackoutMod:          The lobby host should create a new lobby with install.bat (6-8 characters).")
    end
    return true
end

-- Load config on startup
LoadConfig()

-- ============================================
-- ROLE DETECTION (WITH CACHING)
-- ============================================

function IsPlayerDissident()
    if DebugForceDissident then
        return true
    end

    -- Return cached result if still valid
    local currentTime = os.clock() * 1000
    if CachedRole ~= nil and (currentTime - LastRoleCheck < RoleCacheTimeout) then
        return CachedRole
    end
    
    LastRoleCheck = currentTime
    
    local textBlocks = FindAllOf("TextBlock")
    
    if not textBlocks then
        CachedRole = false
        return false
    end
    
    for _, textBlock in ipairs(textBlocks) do
        if textBlock:IsValid() then
            -- Check if widget is visible
            local isVisible = false
            pcall(function()
                local visibility = textBlock:GetVisibility()
                isVisible = (visibility == 0)
            end)
            
            if not isVisible then
                goto continue
            end
            
            -- Widget is visible, check text
            local success, ftext = pcall(function()
                return textBlock:GetText()
            end)
            
            if success and ftext then
                local textSuccess, textStr = pcall(function()
                    return ftext:ToString()
                end)
                
                if textSuccess and textStr then
                    local str = tostring(textStr)
                    
                    if str == "DISSIDENT" then
                        CachedRole = true
                        return true
                    end
                    
                    if str == "EMPLOYEE" then
                        CachedRole = false
                        return false
                    end
                end
            end
            
            ::continue::
        end
    end
    
    CachedRole = false
    return false
end

-- ============================================
-- HTTP & JSON FUNCTIONS (FIREBASE)
-- ============================================

function SendHttpRequest(action, waitForResponse)
    local randomId = math.random(1, 100000)
    local url = ServerUrl .. "/" .. LobbyCode .. "/blackout.json"
    
    if action == "sabotage" then
        -- Write true to Firebase
        local data = '{\\"isBlackout\\":true,\\"timestamp\\":' .. os.time() .. '}'
        local cmd = string.format('curl -s -L -X PUT -H "Content-Type: application/json" -d "%s" "%s"', data, url)
        
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
        end
        return nil
    elseif action == "repair" then
        -- Write false to Firebase
        local data = '{\\"isBlackout\\":false,\\"timestamp\\":' .. os.time() .. '}'
        local cmd = string.format('curl -s -L -X PUT -H "Content-Type: application/json" -d "%s" "%s"', data, url)
        
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
        end
        return nil
    elseif action == "status" and waitForResponse then
        -- Read from Firebase
        local fullUrl = url .. "?nocache=" .. tostring(randomId)
        local cmd = string.format('curl -s -L "%s"', fullUrl)
        local handle = io.popen(cmd)
        if not handle then return nil end
        local result = handle:read("*a")
        handle:close()
        return result
    end
    
    return nil
end

-- Sends sabotage/repair without blocking the calling (game) thread:
-- through the helper's open connection when it works, otherwise with curl
function SendHttpRequestAsync(action)
    if ReadHelperState() and HelperSend(string.format("put %s %d", action == "sabotage" and "true" or "false", os.time())) then
        return
    end

    RunAsync(function()
        local success, err = pcall(function()
            SendHttpRequest(action, false)
        end)
        if not success then
            print("BlackoutMod: ERROR sending " .. action .. " request: " .. tostring(err))
        end
    end)
end

function ParseJsonNumber(jsonString, key)
    if not jsonString then return nil end

    local value = jsonString:match('"' .. key .. '"%s*:%s*(%-?%d+%.?%d*)')
    return tonumber(value)
end

function ParseJsonBool(jsonString, key)
    if not jsonString then return nil end
    
    -- Remove whitespace and newlines
    jsonString = jsonString:gsub("%s+", "")
    
    local pattern = '"' .. key .. '":true'
    if string.find(jsonString, pattern) then return true end
    
    pattern = '"' .. key .. '":false'
    if string.find(jsonString, pattern) then return false end
    
    return nil
end

-- Runs curl and returns body, HTTP status. Blocking: call off the game thread.
function CurlRequest(method, url, jsonBody)
    local cmd
    if jsonBody then
        local escaped = jsonBody:gsub('"', '\\"')
        cmd = string.format('curl -s -L -X %s -H "Content-Type: application/json" -d "%s" -w "\\n%%{http_code}" "%s"',
            method, escaped, url)
    else
        cmd = string.format('curl -s -L -w "\\n%%{http_code}" "%s"', url)
    end

    local handle = io.popen(cmd)
    if not handle then return nil, nil end
    local result = handle:read("*a")
    handle:close()

    local body, status = result:match("^(.*)\n(%d+)%s*$")
    return body, tonumber(status)
end

-- ============================================
-- SHARED LOBBY SETTINGS
-- ============================================
-- The lobby host (has OwnerKey in config.txt) uploads their settings, everyone
-- else downloads them. Only at start and on F5. The server rules only accept
-- uploads with the host's key, and the key itself can't be read.

function DescribeLobbySettings()
    return string.format("Sabotages/round: %s, Cooldown: %s, Max duration: %s",
        MaxSabotagesPerRound == 0 and "unlimited" or tostring(MaxSabotagesPerRound),
        SabotageCooldown == 0 and "off" or (SabotageCooldown .. "s"),
        MaxBlackoutDuration == 0 and "off" or (MaxBlackoutDuration .. "s"))
end

function SyncLobbySettings()
    RunAsync(function()
        local success, err = pcall(function()
            local url = ServerUrl .. "/" .. LobbyCode .. "/settings"

            if OwnerKey ~= "" then
                local values = string.format('{"maxSabotages":%d,"cooldown":%d,"maxDuration":%d}',
                    MaxSabotagesPerRound, SabotageCooldown, MaxBlackoutDuration)
                local _, status = CurlRequest("PUT", url .. ".json", '{"key":"' .. OwnerKey .. '","values":' .. values .. '}')
                if status == 200 then
                    print("BlackoutMod: You are the lobby host, settings shared with all players:")
                else
                    print("BlackoutMod: WARNING: Could not share lobby settings (HTTP " .. tostring(status) .. ").")
                    print("BlackoutMod:          OwnerKey doesn't match this lobby? Using your settings only locally:")
                end
                print("BlackoutMod:   " .. DescribeLobbySettings())
                return
            end

            local body = CurlRequest("GET", url .. "/values.json")
            local maxSabotages = ParseJsonNumber(body, "maxSabotages")
            local cooldown = ParseJsonNumber(body, "cooldown")
            local maxDuration = ParseJsonNumber(body, "maxDuration")

            if maxSabotages and cooldown and maxDuration then
                MaxSabotagesPerRound = math.floor(maxSabotages)
                SabotageCooldown = math.floor(cooldown)
                MaxBlackoutDuration = math.floor(maxDuration)
                print("BlackoutMod: Using the lobby host's settings:")
            else
                print("BlackoutMod: This lobby has no shared settings, using config.txt:")
            end
            print("BlackoutMod:   " .. DescribeLobbySettings())
        end)
        if not success then
            print("BlackoutMod: ERROR syncing lobby settings: " .. tostring(err))
        end
    end)
end

-- ============================================
-- GAME UTILITY FUNCTIONS
-- ============================================

function RunCommand(cmd)
    local Kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pcs = FindAllOf("PlayerController")
    local Context = nil
    if pcs and #pcs > 0 then Context = pcs[1] end
    if Kismet and Context then Kismet:ExecuteConsoleCommand(Context, cmd, nil) end
end

function GetPlayerController()
    local controllers = FindAllOf("PlayerController")
    if controllers and #controllers > 0 then
        for _, pc in ipairs(controllers) do
            if pc:IsValid() and pc:IsLocalPlayerController() then
                return pc
            end
        end
    end
    return nil
end

function GetPlayerLocation()
    local pc = GetPlayerController()
    if pc and pc:IsValid() then
        local pawn = nil
        pcall(function() pawn = pc:K2_GetPawn() end)
        if pawn and pawn:IsValid() then 
            return pawn:K2_GetActorLocation() 
        end
    end
    return nil
end

-- ============================================
-- BLUEPRINT MOD ACTOR FUNCTIONS
-- ============================================

function FindModActor()
    local success, err = pcall(function()
        local actors = FindAllOf("ModActor_C")
        
        if actors and #actors > 0 then
            for i = #actors, 1, -1 do
                local actor = actors[i]
                if actor:IsValid() then
                    local hasWidget = false
                    pcall(function()
                        local widget = actor:GetPropertyValue("TextWidget")
                        if widget then
                            hasWidget = true
                        end
                    end)
                    
                    if hasWidget then
                        ModActor = actor
                        print("BlackoutMod: Actor loaded")
                        return true
                    end
                end
            end
            
            ModActor = actors[1]
            return true
        else
            return false
        end
    end)
    
    return success
end

function ShowPromptWidget()
    if not ModActor or not ModActor:IsValid() then
        return
    end
    
    pcall(function()
        ModActor:ShowPrompt()
    end)
end

function HidePromptWidget()
    if not ModActor or not ModActor:IsValid() then
        return
    end
    
    pcall(function()
        ModActor:HidePrompt()
    end)
end

-- ============================================
-- HELPER PROCESS (Scripts/blackout_helper.ps1)
-- ============================================
-- One PowerShell process runs for the whole game session and
-- - polls the blackout state over a kept-alive HTTPS connection and writes it to
--   HelperStateFile. Starting curl every second cost a TLS handshake per request
--   (~5 KB), most of the Firebase download quota.
-- - sends sabotage/repair writes over the same connection
-- - plays the WAV (game sound assets stay silent when played through UE4SS)
-- - turns off QuickEdit for the shared UE4SS console (a click froze the game)
-- Commands go to its stdin, it exits when the game closes (stdin closes).
-- If it doesn't work (e.g. blocked by antivirus), polling and writes fall back to curl.
local HelperScript = "ue4ss/Mods/BlackoutMod/Scripts/blackout_helper.ps1"
local HelperStateFile = "ue4ss/Mods/BlackoutMod/state.txt"
local HelperStateMaxAge = 5  -- seconds; an older state means the helper isn't working
local HelperPipe = nil
local HelperErrorLogged = false

function ToWindowsPath(path)
    return (path:gsub("/", "\\"))
end

function StartHelper()
    for _, required in ipairs({HelperScript, FlickerSoundFile}) do
        local file = io.open(required, "rb")
        if not file then
            print("BlackoutMod: File not found: " .. required)
            return
        end
        file:close()
    end

    -- No -WindowStyle Hidden: the helper shares the UE4SS console and would hide it
    local cmd = string.format('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s"',
        ToWindowsPath(HelperScript), ToWindowsPath(FlickerSoundFile), ServerUrl, ToWindowsPath(HelperStateFile))
    local success, pipe = pcall(io.popen, cmd, "w")
    if success then HelperPipe = pipe end
end

-- Returns true if the line was handed to the helper
function HelperSend(line)
    if not HelperPipe then return false end

    local success, err = pcall(function()
        HelperPipe:write(line .. "\n")
        HelperPipe:flush()
    end)
    if not success then
        HelperPipe = nil
        if not HelperErrorLogged then
            print("BlackoutMod: Helper stopped (" .. tostring(err) .. "), using curl")
            HelperErrorLogged = true
        end
    end
    return success
end

-- Latest blackout state from the helper: {isBlackout, timestamp}, or nil if the
-- helper isn't working or the state belongs to another lobby
function ReadHelperState()
    local file = io.open(HelperStateFile, "r")
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    if not line then return nil end

    local lobby, isBlackout, timestamp, writtenAt = line:match("^1;([^;]*);([^;]*);([^;]*);(%d+);end")
    if lobby ~= LobbyCode then return nil end
    if os.time() - tonumber(writtenAt) > HelperStateMaxAge then return nil end

    local state = {timestamp = tonumber(timestamp)}
    if isBlackout == "true" then
        state.isBlackout = true
    elseif isBlackout == "false" then
        state.isBlackout = false
    end
    return state
end

function PlayBlackoutSound()
    HelperSend("play")
end

-- Started at load time so the first blackout has no PowerShell startup delay
StartHelper()
HelperSend("lobby " .. LobbyCode)

-- ============================================
-- PROXIMITY & PLAYER FUNCTIONS
-- ============================================

-- Cache charger locations to avoid accessing destroyed UObjects
local CachedChargerLocations = {}
local LastChargerScan = 0
local ChargerScanErrorLogged = false
local ChargerScanInterval = 2000  -- Rescan chargers every 2 seconds

function ScanChargerLocations()
    local now = os.clock() * 1000
    if now - LastChargerScan < ChargerScanInterval then
        return  -- Use cached locations
    end
    LastChargerScan = now
    CachedChargerLocations = {}

    local scanSuccess, scanErr = pcall(function()
        local chargers = FindAllOf("RezCharger_C")
        if not chargers then return end

        for _, charger in ipairs(chargers) do
            local ok, loc = pcall(function()
                if charger and charger:IsValid() then
                    return charger:K2_GetActorLocation()
                end
                return nil
            end)
            if ok and loc then
                table.insert(CachedChargerLocations, {X = loc.X, Y = loc.Y, Z = loc.Z})
            end
        end
    end)

    if not scanSuccess then
        -- Plain local flag: a field on the function value (v2.5) raised a Lua error itself
        if not ChargerScanErrorLogged then
            print("BlackoutMod: ERROR scanning chargers: " .. tostring(scanErr))
            ChargerScanErrorLogged = true
        end
    end
end

function CheckChargerProximity()
    local playerLoc = GetPlayerLocation()
    if not playerLoc then
        IsNearCharger = false
        return false
    end

    -- Use cached charger positions (safe plain Lua data, no UObject access)
    ScanChargerLocations()

    for _, cL in ipairs(CachedChargerLocations) do
        local dist = math.sqrt(
            (playerLoc.X - cL.X)^2 +
            (playerLoc.Y - cL.Y)^2 +
            (playerLoc.Z - cL.Z)^2
        )
        if dist < InteractionDistance then
            IsNearCharger = true
            return true
        end
    end

    IsNearCharger = false
    return false
end

function CountLivingPlayers()
    local livingCount = 0
    local controllers = FindAllOf("PlayerController")
    if controllers then
        for i, pc in ipairs(controllers) do
            if pc:IsValid() then
                local pawn = nil
                pcall(function() pawn = pc:K2_GetPawn() end)
                if pawn and pawn:IsValid() then
                    local health = pawn:GetPropertyValue("Health")
                    if health and type(health) == "number" and health > 0 then
                        livingCount = livingCount + 1
                    end
                end
            end
        end
    end
    return livingCount
end

function GetPawnHealth(pawn)
    local health = nil
    pcall(function() health = pawn:GetPropertyValue("Health") end)
    if type(health) == "number" then return health end
    return nil
end

-- Clients only own their local PlayerController, so CountLivingPlayers can't see
-- other players there. PlayerStates are replicated to everyone, so remember which
-- pawns were alive (by name, no UObject refs kept) and watch for their health hitting 0.
-- Pawns that disappear are ignored: they may just be out of network relevancy range.
function SnapshotLivingPawns()
    LivingPawnsAtStart = {}
    for _, pawn in ipairs(UEHelpers.GetAllPlayers()) do
        local health = GetPawnHealth(pawn)
        if health and health > 0 then
            LivingPawnsAtStart[pawn:GetFullName()] = true
        end
    end
end

function FindDeadKnownPawn()
    for _, pawn in ipairs(UEHelpers.GetAllPlayers()) do
        local name = pawn:GetFullName()
        if LivingPawnsAtStart[name] then
            local health = GetPawnHealth(pawn)
            if health and health <= 0 then
                return name
            end
        end
    end
    return nil
end

-- ============================================
-- BLACKOUT FUNCTIONS
-- ============================================

-- FindAllOf needs short class names; the v2.5 full paths ("/Script/Engine.PointLightComponent")
-- found nothing, so only exposure/gamma made it dark
local LightClasses = {"PointLightComponent", "SpotLightComponent", "RectLightComponent"}

-- Full names of the lights the blackout (or flicker) turned off, so a repair only
-- turns those back on and leaves lights alone that were off on purpose
local HiddenLightNames = {}

local PawnClass = nil

-- Lights owned by a player (e.g. flashlights) stay on during the blackout
function IsPlayerLight(light)
    if not PawnClass or not PawnClass:IsValid() then
        PawnClass = StaticFindObject("/Script/Engine.Pawn")
    end
    local isPlayer = false
    pcall(function()
        local owner = light:GetOwner()
        if owner and owner:IsValid() then
            if owner:IsA(PawnClass) then
                isPlayer = true
                return
            end
            -- Held items: owner of the owner is the pawn
            local ownerOwner = owner:GetOwner()
            if ownerOwner and ownerOwner:IsValid() and ownerOwner:IsA(PawnClass) then
                isPlayer = true
            end
        end
    end)
    return isPlayer
end

function GetAllLights()
    local result = {}
    for _, className in ipairs(LightClasses) do
        local success, err = pcall(function()
            local lights = FindAllOf(className)
            if lights then
                for _, l in ipairs(lights) do
                    table.insert(result, l)
                end
            end
        end)
        if not success then
            print("BlackoutMod: ERROR finding lights (" .. className .. "): " .. tostring(err))
        end
    end
    return result
end

-- Lights that are currently on and not owned by a player
function GetBlackoutLights()
    local result = {}
    local skipped = 0
    for _, l in ipairs(GetAllLights()) do
        pcall(function()
            if l:IsValid() and l:IsVisible() then
                if IsPlayerLight(l) then
                    skipped = skipped + 1
                else
                    table.insert(result, l)
                end
            end
        end)
    end
    return result, skipped
end

function RememberHiddenLights(lights)
    for _, l in ipairs(lights) do
        pcall(function()
            HiddenLightNames[l:GetFullName()] = true
        end)
    end
end

function RestoreHiddenLights()
    local restored = 0
    for _, l in ipairs(GetAllLights()) do
        pcall(function()
            if l:IsValid() and HiddenLightNames[l:GetFullName()] then
                l:SetVisibility(true, false)
                restored = restored + 1
            end
        end)
    end
    HiddenLightNames = {}
    return restored
end

function SetLightsVisible(lights, visible)
    for _, l in ipairs(lights) do
        -- Double-check validity with pcall per light to avoid C++ crash on destroyed components
        pcall(function()
            if l and l:IsValid() then
                l:SetVisibility(visible, false)
            end
        end)
    end
end

function SetBlackout(active)
    if active then
        local lights, skipped = GetBlackoutLights()
        RememberHiddenLights(lights)
        SetLightsVisible(lights, false)
        print("BlackoutMod: Lights off: " .. #lights .. " (player lights kept on: " .. skipped .. ")")
    else
        print("BlackoutMod: Lights restored: " .. RestoreHiddenLights())
    end

    if active then
        local countSuccess, countErr = pcall(function()
            PlayersAliveAtStart = CountLivingPlayers()
            SnapshotLivingPawns()
        end)
        if countSuccess then
            print("BlackoutMod: Blackout started. Living Players: " .. PlayersAliveAtStart)
        else
            print("BlackoutMod: Blackout started. (Player count failed: " .. tostring(countErr) .. ")")
            PlayersAliveAtStart = 0
            LivingPawnsAtStart = {}
        end
    end

    local cmdSuccess, cmdErr = pcall(function()
        if active then
            if not SavedGraphics then
                SavedGraphics = ReadGraphicsSettings()
            end
            RunCommand("r.ExposureOffset -15")
            RunCommand("r.Lumen.DiffuseIndirect.Allow 0")
            RunCommand("gamma 0.5")
        elseif SavedGraphics then
            RunCommand(string.format("r.ExposureOffset %g", SavedGraphics.ExposureOffset))
            RunCommand(string.format("r.Lumen.DiffuseIndirect.Allow %d", SavedGraphics.LumenDiffuse))
            RunCommand(string.format("gamma %g", SavedGraphics.Gamma))
            SavedGraphics = nil
        end
    end)
    if not cmdSuccess then
        print("BlackoutMod: ERROR running console commands: " .. tostring(cmdErr))
    end
end

-- Reads the player's current values so the blackout doesn't overwrite their settings.
-- Falls back to the previous hardcoded defaults if a value can't be read.
function ReadGraphicsSettings()
    local settings = {ExposureOffset = 0, LumenDiffuse = 1, Gamma = 2.2}

    pcall(function()
        local Kismet = UEHelpers.GetKismetSystemLibrary()
        if Kismet and Kismet:IsValid() then
            local exposure = Kismet:GetConsoleVariableFloatValue("r.ExposureOffset")
            if type(exposure) == "number" then settings.ExposureOffset = exposure end
            local lumen = Kismet:GetConsoleVariableIntValue("r.Lumen.DiffuseIndirect.Allow")
            if type(lumen) == "number" then settings.LumenDiffuse = math.floor(lumen) end
        end
    end)

    pcall(function()
        local Engine = UEHelpers.GetEngine()
        if Engine and Engine:IsValid() then
            local gamma = Engine.DisplayGamma
            if type(gamma) == "number" and gamma > 0 then settings.Gamma = gamma end
        end
    end)

    print(string.format("BlackoutMod: Saved graphics (Exposure %g, Lumen %d, Gamma %g)",
        settings.ExposureOffset, settings.LumenDiffuse, settings.Gamma))
    return settings
end

-- Flicker pattern before the blackout: {ms after start, lights visible}
local FlickerPattern = {{0, false}, {120, true}, {300, false}, {420, true}, {700, false}, {800, true}}
local FlickerDuration = 1200  -- ms until the actual blackout
local FlickerId = 0  -- Increments per blackout so steps of an older flicker get dropped

-- Must run on the game thread. Flickers the lights, then calls SetBlackout(true),
-- unless the blackout was repaired in the meantime.
function StartBlackout()
    PlayBlackoutSound()

    FlickerId = FlickerId + 1
    local myId = FlickerId
    local lights = GetBlackoutLights()
    -- Remembered right away, so a repair during an "off" step still turns them back on
    RememberHiddenLights(lights)

    -- Only a few real light components exist and exposure changes fade in via eye
    -- adaptation, so the flicker also switches gamma, which applies instantly.
    -- SetBlackout keeps these saved values.
    if not SavedGraphics then
        SavedGraphics = ReadGraphicsSettings()
    end
    local normalExposure = SavedGraphics.ExposureOffset
    local normalGamma = SavedGraphics.Gamma

    print("BlackoutMod: Flicker started (" .. #lights .. " lights)")

    local function stillWanted()
        return myId == FlickerId and CurrentServerState
    end

    -- Game-thread timers: ExecuteWithDelay shares the async thread with the blocking
    -- curl calls, so its steps arrived bunched together after ~800ms
    for _, step in ipairs(FlickerPattern) do
        ExecuteInGameThreadWithDelay(step[1], function()
            if not stillWanted() then return end
            local visible = step[2]
            SetLightsVisible(lights, visible)
            RunCommand(string.format("r.ExposureOffset %g", visible and normalExposure or -15))
            RunCommand(string.format("gamma %g", visible and normalGamma or 0.5))
        end)
    end

    ExecuteInGameThreadWithDelay(FlickerDuration, function()
        if not stillWanted() then return end
        local success, err = pcall(SetBlackout, true)
        if not success then
            print("BlackoutMod: FATAL ERROR in SetBlackout: " .. tostring(err))
        end
    end)
end

function GetCooldownRemaining()
    if SabotageCooldown <= 0 then return 0 end
    return math.max(0, SabotageCooldown - (os.clock() - LastBlackoutEndTime))
end

-- Must run on the game thread; the HTTP request itself runs async
function ForceRepair(reason)
    print("BlackoutMod: REPAIR! Reason: " .. reason)
    SendHttpRequestAsync("repair")
    LastLocalChangeTime = os.clock()
    if CurrentServerState then
        LastBlackoutEndTime = os.clock()
    end
    CurrentServerState = false
    SetBlackout(false)
end

function CheckWinConditions()
    if not CurrentServerState then return end

    -- Grace period: don't check win conditions during the first 8 seconds after blackout
    -- With multiple clients, player counts can fluctuate briefly due to replication delays
    local elapsed = os.clock() - LastSabotageTime
    if elapsed < 8.0 then return end

    if MaxBlackoutDuration > 0 and elapsed >= MaxBlackoutDuration then
        ForceRepair("Time limit reached (" .. MaxBlackoutDuration .. "s)")
        return
    end

    local playerLoc = GetPlayerLocation()
    if playerLoc and playerLoc.Z >= 500 then
        ForceRepair("Lobby detected (Z >= 500)")
        return
    end

    local currentLiving = CountLivingPlayers()
    if currentLiving < PlayersAliveAtStart then
        ForceRepair("Player died (Prev: " .. PlayersAliveAtStart .. ", Now: " .. currentLiving .. ")")
        return
    end

    local deadPawn = nil
    pcall(function() deadPawn = FindDeadKnownPawn() end)
    if deadPawn then
        ForceRepair("Player died (" .. deadPawn .. ")")
        return
    end

    -- Wrap charger check in pcall to prevent crashes
    pcall(function()
        local chargers = FindAllOf("RezCharger_C")
        if chargers then
            for _, charger in ipairs(chargers) do
                if charger:IsValid() then
                    local cL = charger:GetPropertyValue("Charge L")
                    local cR = charger:GetPropertyValue("Charge R")
                    if not cL then cL = 0 end
                    if not cR then cR = 0 end
                    
                    if (type(cL) == "number" and cL > 0) and (type(cR) == "number" and cR > 0) then
                        ForceRepair("Batteries inserted")
                        return
                    end
                end
            end
        end
    end)
end

function CheckLobbyReset()
    if MaxSabotagesPerRound == 0 then return end

    local playerLoc = GetPlayerLocation()
    if playerLoc and playerLoc.Z >= 500 then
        if SabotageCount > 0 then
            SabotageCount = 0
            print("BlackoutMod: Back in lobby - Sabotage available again")
        end
    end
end

-- ============================================
-- INITIALIZATION
-- ============================================

NotifyOnNewObject("/Script/Engine.PlayerController", function(ConstructedObject)
    ExecuteInGameThread(function()
        ExecuteWithDelay(3000, function()
            FindModActor()
        end)
    end)
end)

-- ============================================
-- MAIN LOOPS
-- ============================================

-- Applies the polled server state. Must run on the game thread.
function ApplyServerState(serverBlackout, serverTimestamp)
    if serverBlackout == nil then return end

    -- Our own sabotage/repair may not have reached the server yet
    if (os.clock() - LastLocalChangeTime) < LocalChangeGrace then return end

    -- Leftover blackout, e.g. someone crashed or quit during one
    -- (+10s tolerance because the timestamp comes from another PC's clock)
    if serverBlackout and MaxBlackoutDuration > 0 and serverTimestamp
        and (os.time() - serverTimestamp) > MaxBlackoutDuration + 10 then
        ForceRepair("Blackout on server expired")
        return
    end

    if serverBlackout ~= CurrentServerState then
        CurrentServerState = serverBlackout

        if serverBlackout then
            print("BlackoutMod: SYNC -> Blackout ACTIVATED (lights OFF)")
            -- Set LastSabotageTime on ALL clients (not just saboteur) so the
            -- win-condition grace period works for everyone
            LastSabotageTime = os.clock()
        else
            print("BlackoutMod: SYNC -> Blackout DEACTIVATED (lights ON)")
            LastBlackoutEndTime = os.clock()
        end

        if serverBlackout then
            StartBlackout()
        else
            SetBlackout(false)
        end
    end
end

-- Server Sync Loop (1 second)
-- Reads the helper's state file; only when the helper isn't working, curl asks the
-- server directly (on this async thread). Everything touching UObjects runs on the game thread.
LoopAsync(PollInterval, function()
    local serverBlackout, serverTimestamp
    local state = ReadHelperState()
    if state then
        serverBlackout, serverTimestamp = state.isBlackout, state.timestamp
    else
        local response = SendHttpRequest("status", true)
        serverBlackout = ParseJsonBool(response, "isBlackout")
        serverTimestamp = ParseJsonNumber(response, "timestamp")
    end

    ExecuteInGameThread(function()
        local syncSuccess, syncErr = pcall(function()
            ApplyServerState(serverBlackout, serverTimestamp)
            CheckWinConditions()
            CheckLobbyReset()
        end)
        if not syncSuccess then
            print("BlackoutMod: ERROR in sync loop: " .. tostring(syncErr))
        end
    end)

    return false
end)

-- HUD Update Loop (200ms instead of 50ms for better performance)
LoopAsync(200, function()
    -- Charger scan (every 2s, ChargerScanInterval) happens inside CheckChargerProximity on the game thread
    ExecuteInGameThread(function()
        local hudSuccess, hudErr = pcall(function()
            local nearCharger = CheckChargerProximity()

            -- Only check role if near charger
            -- (Changing the prompt text from Lua is not possible: UE4SS can't construct
            -- an FText in this game and the game crashes, so it is hidden during cooldown)
            local shouldShow = false
            if nearCharger then
                local isDissident = IsPlayerDissident()  -- Now cached!

                shouldShow = isDissident and (not CurrentServerState) and (GetCooldownRemaining() <= 0)
                if MaxSabotagesPerRound > 0 then
                    shouldShow = shouldShow and (SabotageCount < MaxSabotagesPerRound)
                end
            end

            if shouldShow then
                ShowPromptWidget()
            else
                HidePromptWidget()
            end
        end)
        if not hudSuccess then
            print("BlackoutMod: ERROR in HUD loop: " .. tostring(hudErr))
        end
    end)

    return false
end)

-- ============================================
-- KEY BINDINGS
-- ============================================

-- P = Manual Repair (disabled unless AllowManualRepair or DebugForceDissident)
RegisterKeyBind(Key.P, function()
    if not (AllowManualRepair or DebugForceDissident) then
        print("BlackoutMod: Manual repair is disabled (AllowManualRepair = false)")
        return
    end

    ExecuteInGameThread(function()
        print("BlackoutMod: Manual Repair")
        ForceRepair("Manual P")
    end)
end)

-- O = Sabotage
function TrySabotage()
    if not IsPlayerDissident() then
        print("BlackoutMod: Only Dissident can sabotage!")
        return
    end

    if CurrentServerState then
        print("BlackoutMod: Blackout already active!")
        return
    end

    local cooldownLeft = GetCooldownRemaining()
    if cooldownLeft > 0 then
        print("BlackoutMod: Cooldown active, wait " .. math.ceil(cooldownLeft) .. "s")
        return
    end

    if MaxSabotagesPerRound > 0 and SabotageCount >= MaxSabotagesPerRound then
        print("BlackoutMod: Already sabotaged " .. SabotageCount .. "/" .. MaxSabotagesPerRound .. " this round!")
        return
    end

    if not IsNearCharger then
        print("BlackoutMod: Too far away from charger!")
        return
    end

    SabotageCount = SabotageCount + 1
    if MaxSabotagesPerRound > 0 then
        print("BlackoutMod: Sabotage activated! (" .. SabotageCount .. "/" .. MaxSabotagesPerRound .. " this round)")
    else
        print("BlackoutMod: Sabotage activated!")
    end

    LastSabotageTime = os.clock()
    LastLocalChangeTime = os.clock()

    SendHttpRequestAsync("sabotage")
    CurrentServerState = true

    local blSuccess, blErr = pcall(StartBlackout)
    if not blSuccess then
        print("BlackoutMod: FATAL ERROR in StartBlackout: " .. tostring(blErr))
    end
end

RegisterKeyBind(Key.O, function()
    ExecuteInGameThread(TrySabotage)
end)

-- L = Lobby Code Info
RegisterKeyBind(Key.L, function()
    print("==========================================")
    print("BlackoutMod: LOBBY CODE INFO")
    print("==========================================")
    print("Current code: " .. LobbyCode .. (OwnerKey ~= "" and " (you are the host)" or ""))
    print("Settings: " .. DescribeLobbySettings())
    print("")
    print("To change code or settings:")
    print("- Run install.bat again (create or join a lobby)")
    print("- OR edit ue4ss/Mods/BlackoutMod/config.txt and press F5 in-game")
    print("")
    print("Make sure everyone uses the SAME code!")
    print("==========================================")
end)

-- I = Debug Info
RegisterKeyBind(Key.I, function()
    ExecuteInGameThread(function()
        print("==========================================")
        print("BlackoutMod: DEBUG INFO")
        print("==========================================")
        print("Lobby Code: " .. LobbyCode)
        print("Player Role: " .. (IsPlayerDissident() and "DISSIDENT" or "EMPLOYEE"))
        print("ServerUrl: " .. ServerUrl .. "/" .. LobbyCode)
        print("CurrentServerState: " .. tostring(CurrentServerState))
        if MaxSabotagesPerRound > 0 then
            print("Sabotage Count: " .. SabotageCount .. "/" .. MaxSabotagesPerRound)
        else
            print("Sabotage Count: " .. SabotageCount .. " (unlimited)")
        end

        local playerLoc = GetPlayerLocation()
        if playerLoc then
            print("Player Z Position: " .. tostring(playerLoc.Z))
            if playerLoc.Z >= 500 then
                print("  -> In LOBBY")
            else
                print("  -> In GAME")
            end
        end

        print("Helper: " .. (ReadHelperState() and "running (kept-alive connection)" or "not running, using curl"))
        print("")
        print("Checking server right now...")

        -- Server check runs async so the game doesn't freeze while curl waits
        RunAsync(function()
            local response = SendHttpRequest("status", true)
            local serverBlackout = ParseJsonBool(response, "isBlackout")

            print("Server Response: " .. tostring(response))
            print("Server isBlackout: " .. tostring(serverBlackout))

            if serverBlackout ~= CurrentServerState then
                print("")
                print("WARNING: Out of sync!")
                print("Local state: " .. tostring(CurrentServerState))
                print("Server state: " .. tostring(serverBlackout))
            else
                print("")
                print("Status: IN SYNC")
            end
            print("==========================================")
        end)
    end)
end)

-- F5 = Reload config.txt (and the lobby settings) without restarting the game
RegisterKeyBind(Key.F5, function()
    ExecuteInGameThread(function()
        print("BlackoutMod: Reloading config...")
        local oldCode = LobbyCode
        LoadConfig()
        HelperSend("lobby " .. LobbyCode)

        -- Leaving a lobby during its blackout: lights back on locally only
        if LobbyCode ~= oldCode and CurrentServerState then
            CurrentServerState = false
            SetBlackout(false)
        end

        SyncLobbySettings()
    end)
end)

print("==========================================")
print("BlackoutMod v" .. ModVersion .. " LOADED")
print("==========================================")
print("Current Lobby Code: " .. LobbyCode)
print("")
print("Press O to Sabotage (Dissident only, when near defibrillator)")
if AllowManualRepair or DebugForceDissident then
    print("Press P for Manual Repair (emergency)")
end
print("Press L for Lobby Code Info")
print("Press I for Debug Info (check role & sync status)")
print("Press F5 to reload config.txt")
print("(Lobby settings follow once loaded from the server)")
print("==========================================")
if DebugForceDissident then
    print("")
    print(" DEBUG: DebugForceDissident is ON - you are always Dissident!")
    print("")
end
if LobbyCode == "0000" then
    print("")
    print(" WARNING: Using default lobby code!")
    print("Run install.bat to set your own code!")
    print("")
end

-- Last, so everything it uses is defined
SyncLobbySettings()
