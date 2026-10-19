local ModName = "BlackoutMod"
local ServerUrl = "https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies"
local LobbyCode = "0000"  -- Default, loaded from config.txt

-- ============================================
-- CONFIGURATION
-- ============================================
local MaxSabotagesPerRound = 1  -- 0 = unlimited, any other number = max sabotages per round per dissident
local DebugForceDissident = false  -- TESTING ONLY: always treat local player as Dissident (keep false for release!)
local MaxBlackoutDuration = 0  -- Seconds until lights come back automatically (0 = off, e.g. 180)
local AllowManualRepair = false  -- P key repair (always allowed while DebugForceDissident is on)
local SabotageCooldown = 0  -- Seconds after the lights come back before the next sabotage (0 = off)
local FlickerBeforeBlackout = true  -- Lights flicker briefly before going out
local FlickerSoundPath = "/Game/World/Bullet_Travel/MS_BulletImpact_Spark.MS_BulletImpact_Spark"  -- Played on each flicker, "" = no sound
local FlickerSoundVolume = 1.0
-- ============================================
-- CONFIGURATION END
-- ============================================

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

function LoadConfig()
    local configPath = "ue4ss/Mods/BlackoutMod/config.txt"

    local success, file = pcall(function()
        return io.open(configPath, "r")
    end)

    if success and file then
        -- Line 1: Lobby Code
        local code = file:read("*l")
        -- Line 2: Max Sabotages Per Round
        local maxSabo = file:read("*l")
        -- Line 3: Cooldown in seconds (optional, missing in v2.5 configs)
        local cooldown = file:read("*l")
        file:close()

        if code then
            -- Same truncation as v2.5 so existing codes still match; only characters
            -- that are safe in the server URL and the curl command line are kept
            local cleaned = code:sub(1, 8):gsub("[^%w_%-]", "")
            if #cleaned >= 4 then
                LobbyCode = cleaned
                print("BlackoutMod: Loaded Lobby Code: " .. LobbyCode)
                if #LobbyCode < 6 then
                    print("BlackoutMod: WARNING: Short lobby codes are easy to guess, use 6-8 characters!")
                end
            else
                print("BlackoutMod: Invalid lobby code in config.txt (need 4-8 letters/digits)")
            end
        end

        if maxSabo then
            local cleaned = maxSabo:gsub("[^%d]", "")
            local num = tonumber(cleaned)
            if num and num >= 0 then
                MaxSabotagesPerRound = math.floor(num)
                print("BlackoutMod: Max Sabotages Per Round: " .. (MaxSabotagesPerRound == 0 and "unlimited" or tostring(MaxSabotagesPerRound)))
            end
        end

        if cooldown then
            local num = tonumber((cooldown:gsub("[^%d]", "")))
            if num and num >= 0 then
                SabotageCooldown = math.floor(num)
                print("BlackoutMod: Sabotage Cooldown: " .. (SabotageCooldown == 0 and "off" or (SabotageCooldown .. "s")))
            end
        end

        return true
    end

    print("BlackoutMod: No config found, using defaults (Code: " .. LobbyCode .. ", MaxSabo: " .. MaxSabotagesPerRound .. ")")
    print("BlackoutMod: Run install.bat to configure!")
    return false
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

-- Sends sabotage/repair without blocking the calling (game) thread
function SendHttpRequestAsync(action)
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
-- SOUND
-- ============================================

local SoundErrorsLogged = {}

function FindSound(path)
    local sound = StaticFindObject(path)
    if not sound or not sound:IsValid() then
        sound = LoadAsset(path)
    end
    if not sound or not sound:IsValid() then
        error("sound not found")
    end
    return sound
end

-- Playback methods, tried via J to find one that is audible in this game
local SoundMethods = {
    {"PlaySound2D (world context)", function(sound, volume)
        UEHelpers.GetGameplayStatics():PlaySound2D(UEHelpers.GetWorldContextObject(), sound, volume, 1.0, 0.0, nil, nil, true)
    end},
    {"SpawnSound2D (player controller)", function(sound, volume)
        local component = UEHelpers.GetGameplayStatics():SpawnSound2D(GetPlayerController(), sound, volume, 1.0, 0.0, nil, false, true)
        local valid = component ~= nil and component:IsValid()
        print("BlackoutMod:   AudioComponent valid: " .. tostring(valid))
        if valid then
            ExecuteInGameThreadWithDelay(300, function()
                pcall(function()
                    print("BlackoutMod:   IsPlaying after 300ms: " .. tostring(component:IsPlaying()))
                end)
            end)
        end
    end},
    {"PlaySoundAtLocation (player position)", function(sound, volume)
        local loc = GetPlayerLocation()
        if not loc then error("no player location") end
        UEHelpers.GetGameplayStatics():PlaySoundAtLocation(GetPlayerController(), sound,
            {X = loc.X, Y = loc.Y, Z = loc.Z}, {Pitch = 0, Yaw = 0, Roll = 0}, volume, 1.0, 0.0, nil, nil, nil, nil)
    end},
}
local SoundMethodIndex = 1  -- Used by PlaySound2D, switch once we know which one works

-- Must run on the game thread. Plays a game sound asset for the local player only
-- (every client plays it itself when the blackout syncs).
function PlaySound2D(path, volume, methodIndex)
    if not path or path == "" then return end
    local method = SoundMethods[methodIndex or SoundMethodIndex]

    local success, err = pcall(function()
        method[2](FindSound(path), volume)
    end)

    if not success and not SoundErrorsLogged[path .. method[1]] then
        print("BlackoutMod: ERROR playing sound " .. path .. " (" .. method[1] .. "): " .. tostring(err))
        SoundErrorsLogged[path .. method[1]] = true
    end
end

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
    if not FlickerBeforeBlackout then
        SetBlackout(true)
        return
    end

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
            if not visible then
                PlaySound2D(FlickerSoundPath, FlickerSoundVolume)
            end
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
-- The HTTP request stays on this async thread, everything touching UObjects runs on the game thread
LoopAsync(PollInterval, function()
    local response = SendHttpRequest("status", true)
    local serverBlackout = ParseJsonBool(response, "isBlackout")
    local serverTimestamp = ParseJsonNumber(response, "timestamp")

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
    print("Current code: " .. LobbyCode)
    print("")
    print("To change code:")
    print("1. Exit game")
    print("2. Edit: Mods/BlackoutMod/config.txt")
    print("3. Enter your 4-8 digit lobby code")
    print("4. Save and restart game")
    print("")
    print("OR run install.bat to set code automatically")
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

-- J = Preview sound candidates (DebugForceDissident only), to pick FlickerSoundPath
local SoundCandidates = {
    "/Game/World/Bullet_Travel/MS_BulletImpact_Spark.MS_BulletImpact_Spark",
    "/Game/World/MapCommunication/AlarmSound_01.AlarmSound_01",
    "/Game/Audio/Files/Interactions/Buttons/Kitchen_Button_Click_1.Kitchen_Button_Click_1",
    "/Game/Audio/Files/Interactions/ContainerSlot/ContainerSlot_Click.ContainerSlot_Click",
    "/Game/Audio/Files/Weapons/Light_Shot.Light_Shot",
    "/Game/Character/Audio/MS_LightFall.MS_LightFall",
}
-- Each press plays the next sound with the next method:
-- first all methods with the alarm (loud and long), then the other candidates
local SoundTests = {}
for methodIndex = 1, #SoundMethods do
    table.insert(SoundTests, {SoundCandidates[2], methodIndex})
end
for i, path in ipairs(SoundCandidates) do
    if i ~= 2 then
        for methodIndex = 1, #SoundMethods do
            table.insert(SoundTests, {path, methodIndex})
        end
    end
end
local SoundTestIndex = 0

RegisterKeyBind(Key.J, function()
    if not DebugForceDissident then return end

    ExecuteInGameThread(function()
        SoundTestIndex = SoundTestIndex % #SoundTests + 1
        local test = SoundTests[SoundTestIndex]
        print("BlackoutMod: Sound test " .. SoundTestIndex .. "/" .. #SoundTests .. ": "
            .. test[1]:match("[^/]+$") .. " via " .. SoundMethods[test[2]][1])
        PlaySound2D(test[1], 1.0, test[2])
    end)
end)

-- K = Diagnose (DebugForceDissident only): dumps the prompt widget and loaded sounds,
-- needed to decide how in-game messages and the blackout sound can be done
function PrintClassMembers(label, obj)
    pcall(function()
        local class = obj:GetClass()
        print(label .. " class: " .. class:GetFullName())
        local names = {}
        class:ForEachFunction(function(func)
            table.insert(names, func:GetFName():ToString())
        end)
        print("  Functions: " .. table.concat(names, ", "))
        names = {}
        class:ForEachProperty(function(prop)
            table.insert(names, prop:GetFName():ToString())
        end)
        print("  Properties: " .. table.concat(names, ", "))
    end)
end

local SoundKeywords = {"light", "power", "elec", "buzz", "switch", "spark", "fuse", "generat",
    "hum", "alarm", "shut", "flicker", "breaker", "lamp", "neon", "blackout", "down", "click", "zap"}

function PrintSounds(className)
    local all = FindAllOf(className) or {}
    print(className .. ": " .. #all .. " loaded")
    local shown = 0
    for _, sound in ipairs(all) do
        local name = ""
        pcall(function() name = sound:GetFullName() end)
        local lower = name:lower()
        for _, keyword in ipairs(SoundKeywords) do
            if lower:find(keyword, 1, true) then
                print("  " .. name)
                shown = shown + 1
                break
            end
        end
        if shown >= 60 then
            print("  ... (more)")
            break
        end
    end
end

RegisterKeyBind(Key.K, function()
    if not DebugForceDissident then return end

    ExecuteInGameThread(function()
        print("==========================================")
        print("BlackoutMod: DIAGNOSE")
        print("==========================================")

        if not ModActor or not ModActor:IsValid() then
            FindModActor()
        end

        if ModActor and ModActor:IsValid() then
            PrintClassMembers("ModActor", ModActor)

            local widget = nil
            pcall(function() widget = ModActor:GetPropertyValue("TextWidget") end)
            if widget and widget:IsValid() then
                PrintClassMembers("TextWidget", widget)

                local widgetName = widget:GetFName():ToString()
                for _, textBlock in ipairs(FindAllOf("TextBlock") or {}) do
                    local fullName = textBlock:GetFullName()
                    if fullName:find(widgetName, 1, true) then
                        local text = "?"
                        pcall(function() text = textBlock:GetText():ToString() end)
                        print("  TextBlock: " .. fullName .. " = \"" .. tostring(text) .. "\"")
                    end
                end
            else
                print("TextWidget: not found")
            end
        else
            print("ModActor: not found")
        end

        print("")
        PrintSounds("SoundCue")
        PrintSounds("SoundWave")
        PrintSounds("MetaSoundSource")
        print("==========================================")
    end)
end)

print("==========================================")
print("BlackoutMod LOADED")
print("==========================================")
print("v2.5.0 - Bugfix Update (Crash Prevention)")
print("Current Lobby Code: " .. LobbyCode)
print("")
print("Press O to Sabotage (Dissident only, when near defibrillator)")
if MaxSabotagesPerRound > 0 then
    print("Limited to " .. MaxSabotagesPerRound .. "x per round")
else
    print("Unlimited sabotage enabled")
end
if AllowManualRepair or DebugForceDissident then
    print("Press P for Manual Repair (emergency)")
end
if MaxBlackoutDuration > 0 then
    print("Blackouts end automatically after " .. MaxBlackoutDuration .. "s")
end
if SabotageCooldown > 0 then
    print("Cooldown between blackouts: " .. SabotageCooldown .. "s")
end
print("Press L for Lobby Code Info")
print("Press I for Debug Info (check role & sync status)")
if DebugForceDissident then
    print("Press K for Diagnose (widget & sounds)")
    print("Press J to preview sounds")
end
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