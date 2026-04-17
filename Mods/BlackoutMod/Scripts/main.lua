local ModName = "BlackoutMod"
local ServerUrl = "https://blackoutmod-shared-default-rtdb.firebaseio.com/lobbies"
local LobbyCode = "0000"  -- Default, loaded from config.txt

-- ============================================
-- CONFIGURATION
-- ============================================
local MaxSabotagesPerRound = 1  -- 0 = unlimited, any other number = max sabotages per round per dissident
-- ============================================
-- CONFIGURATION END
-- ============================================

local InteractionDistance = 300.0
local PollInterval = 1000  -- 1 second polling

-- Performance optimizations
-- Role caching (reduces FindAllOf calls)
local CachedRole = nil
local LastRoleCheck = 0
local RoleCacheTimeout = 2000     -- Cache for 2 seconds

local CurrentServerState = false
local SabotageCount = 0
local LastSabotageTime = -100
local PlayersAliveAtStart = 0 

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
        file:close()

        if code and #code >= 4 then
            LobbyCode = code:sub(1, 8):gsub("%s+", "")
            print("BlackoutMod: Loaded Lobby Code: " .. LobbyCode)
        end

        if maxSabo then
            local cleaned = maxSabo:gsub("[^%d]", "")
            local num = tonumber(cleaned)
            if num and num >= 0 then
                MaxSabotagesPerRound = math.floor(num)
                print("BlackoutMod: Max Sabotages Per Round: " .. (MaxSabotagesPerRound == 0 and "unlimited" or tostring(MaxSabotagesPerRound)))
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
        local cmd = string.format('curl -s -L -k -X PUT -H "Content-Type: application/json" -d "%s" "%s"', data, url)
        
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
        end
        return nil
    elseif action == "repair" then
        -- Write false to Firebase
        local data = '{\\"isBlackout\\":false,\\"timestamp\\":' .. os.time() .. '}'
        local cmd = string.format('curl -s -L -k -X PUT -H "Content-Type: application/json" -d "%s" "%s"', data, url)
        
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()
        end
        return nil
    elseif action == "status" and waitForResponse then
        -- Read from Firebase
        local fullUrl = url .. "?nocache=" .. tostring(randomId)
        local cmd = string.format('curl -s -L -k "%s"', fullUrl)
        local handle = io.popen(cmd)
        if not handle then return nil end
        local result = handle:read("*a")
        handle:close()
        return result
    end
    
    return nil
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
-- PROXIMITY & PLAYER FUNCTIONS
-- ============================================

-- Cache charger locations to avoid accessing destroyed UObjects
local CachedChargerLocations = {}
local LastChargerScan = 0
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
        if not ScanChargerLocations.errorLogged then
            print("BlackoutMod: ERROR scanning chargers: " .. tostring(scanErr))
            ScanChargerLocations.errorLogged = true
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

-- ============================================
-- BLACKOUT FUNCTIONS
-- ============================================

function SetBlackout(active)
    local LightClasses = {"/Script/Engine.PointLightComponent", "/Script/Engine.SpotLightComponent", "/Script/Engine.RectLightComponent"}

    for _, path in ipairs(LightClasses) do
        local success, err = pcall(function()
            local lights = FindAllOf(path)
            if lights then
                for _, l in ipairs(lights) do
                    -- Double-check validity with pcall per light to avoid C++ crash on destroyed components
                    pcall(function()
                        if l and l:IsValid() then
                            l:SetVisibility(not active, false)
                        end
                    end)
                end
            end
        end)
        if not success then
            print("BlackoutMod: ERROR toggling lights (" .. path .. "): " .. tostring(err))
        end
    end

    if active then
        local countSuccess, countErr = pcall(function()
            PlayersAliveAtStart = CountLivingPlayers()
        end)
        if countSuccess then
            print("BlackoutMod: Blackout started. Living Players: " .. PlayersAliveAtStart)
        else
            print("BlackoutMod: Blackout started. (Player count failed: " .. tostring(countErr) .. ")")
            PlayersAliveAtStart = 0
        end
    end

    local cmdSuccess, cmdErr = pcall(function()
        if active then
            RunCommand("r.ExposureOffset -15")
            RunCommand("r.Lumen.DiffuseIndirect.Allow 0")
            RunCommand("gamma 0.5")
        else
            RunCommand("r.ExposureOffset 0")
            RunCommand("r.Lumen.DiffuseIndirect.Allow 1")
            RunCommand("gamma 2.2")
        end
    end)
    if not cmdSuccess then
        print("BlackoutMod: ERROR running console commands: " .. tostring(cmdErr))
    end
end

function ForceRepair(reason)
    print("BlackoutMod: REPAIR! Reason: " .. reason)
    SendHttpRequest("repair", false)
    CurrentServerState = false 
    SetBlackout(false)
end

function CheckWinConditions()
    if not CurrentServerState then return end

    -- Grace period: don't check win conditions during the first 8 seconds after blackout
    -- With multiple clients, player counts can fluctuate briefly due to replication delays
    if (os.clock() - LastSabotageTime) < 8.0 then return end

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

-- Server Sync Loop (1 second)
LoopAsync(PollInterval, function()
    local response = SendHttpRequest("status", true)
    local serverBlackout = ParseJsonBool(response, "isBlackout")

    if serverBlackout ~= nil then
        if (serverBlackout == false) and (os.clock() - LastSabotageTime < 5.0) then
            serverBlackout = true
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
            end

            SetBlackout(CurrentServerState)
        end
    end

    CheckWinConditions()
    CheckLobbyReset()
    return false
end)

-- HUD Update Loop (200ms instead of 50ms for better performance)
LoopAsync(200, function()
    -- Charger scan happens OUTSIDE ExecuteInGameThread to reduce risk
    -- Only scan every 2 seconds (ChargerScanInterval), uses cached plain Lua tables
    pcall(ScanChargerLocations)

    ExecuteInGameThread(function()
        local hudSuccess, hudErr = pcall(function()
            local nearCharger = CheckChargerProximity()

            -- Only check role if near charger
            local shouldShow = false
            if nearCharger then
                local isDissident = IsPlayerDissident()  -- Now cached!

                shouldShow = isDissident and (not CurrentServerState)
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

-- P = Manual Repair
RegisterKeyBind(Key.P, function()
    print("BlackoutMod: Manual Repair")
    ForceRepair("Manual P")
end)

-- O = Sabotage
RegisterKeyBind(Key.O, function()
    if not IsPlayerDissident() then
        print("BlackoutMod: Only Dissident can sabotage!")
        return
    end

    if CurrentServerState then
        print("BlackoutMod: Blackout already active!")
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

    local success, err = pcall(function()
        SendHttpRequest("sabotage", false)
    end)
    if not success then
        print("BlackoutMod: ERROR sending sabotage request: " .. tostring(err))
    end
    CurrentServerState = true

    local blSuccess, blErr = pcall(function()
        SetBlackout(true)
    end)
    if not blSuccess then
        print("BlackoutMod: FATAL ERROR in SetBlackout: " .. tostring(blErr))
    end
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
print("Press P for Manual Repair (emergency)")
print("Press L for Lobby Code Info")
print("Press I for Debug Info (check role & sync status)")
print("==========================================")
if LobbyCode == "0000" then
    print("")
    print(" WARNING: Using default lobby code!")
    print("Run install.bat to set your own code!")
    print("")
end