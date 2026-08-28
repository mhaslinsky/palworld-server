local utils = require("utils")

-- HARDENED (palworld-server, 2026-08-22). The stock file dereferences UObject pointers
-- without checking them, and holds one server-wide playerState that dangles once that
-- player leaves. On this dedicated server that produced EXCEPTION_ACCESS_VIOLATION
-- reading 0x1, twice, within 3 min of a player joining. See AGENTS.md rule 6.
--
-- Every change here is a guard or a breadcrumb. No gameplay logic is altered.

-- A dead UObject and a nil are the same thing to every caller here, and telling them
-- apart is exactly what the stock file failed to do. bUseUObjectArrayCache is false in
-- UE4SS-settings.ini, which is what makes IsValid() consult the real object array.
local function alive(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid
end

-- Breadcrumb: the last line in UE4SS.log before a crash names the hook that was running.
-- Without this a native access violation says only "somewhere in UE4SS".
local function trace(where)
    print("[AutoHatch/guard] " .. where .. "\n")
end

-- A hook that throws inside UE4SS is a Lua error; a hook that dereferences a dead pointer
-- is a process crash. pcall cannot stop the second, but it stops one bad hook from
-- leaving later ones unregistered, and it puts the failure in the log with a name.
local function guarded(name, body)
    return function(...)
        local args = table.pack(...)
        local ok, err = pcall(function() return body(table.unpack(args, 1, args.n)) end)
        if not ok then print("[AutoHatch/guard] " .. name .. " failed: " .. tostring(err) .. "\n") end
    end
end

local _ModActor = nil
local playerState = nil
local playerUId = nil
local fp = ".\\Mods\\AutoHatch\\Scripts\\AutoHatch.json"
local sentBytes = false

---@class UPalUtility
local PalUtility = nil

local function guidToString(guid)
    if guid == nil then return nil end
    return string.format("%08X%08X%08X%08X", guid.A & 0xffffffff, guid.B & 0xffffffff, guid.C & 0xffffffff,
        guid.D & 0xffffffff)
end

-- Stock sends a hatched character's archive to the blueprint once per server lifetime and
-- returns early thereafter. Flip to false to restore that behavior if per-hatch sends duplicate Pals.
local SEND_BYTES_EVERY_HATCH = true
local hatchCount = 0

-- The recipient arrives as an FGuid on some paths and a plain ID on others. Because this only
-- feeds a log line, a wrong guess must degrade to text rather than throw.
local function describeId(value)
    if value == nil then return "nil" end
    local ok, text = pcall(guidToString, value)
    if ok and text ~= nil then return text end
    return tostring(value)
end

local function loadJson(file)
    if file ~= nil then
        local json_data = decodeJSONFromFile(file)
        for _, entry in ipairs(json_data) do
            _ModActor:LoadPlayerSettings(entry[1], entry[2])
        end
        print("Settings loaded!")
    end
end

local function RegisterHooks()
    RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", guarded("possession", function(Context)
        trace("possession:enter")
        -- Ensure BP mod is gotten
        if not alive(_ModActor) then
            _ModActor = nil
            local all_mods = FindAllOf("ModActor_C")
            if all_mods ~= nil then
                for index, mod in ipairs(all_mods) do
                    if GetMod(mod) then
                        if mod:IsA("/Game/Mods/AutoHatch/ModActor.ModActor_C") then
                            _ModActor = mod
                            print("Found AutoHatch ModActor!")
                        end
                    end
                end
            end
        end
        if not alive(_ModActor) then trace("possession:no ModActor, skipping") return end

        -- Each of these can legitimately return nothing during a map transition, and the
        -- stock file handed the result straight to the blueprint regardless.
        local gameInstance = FindFirstOf("BP_PalPlayerManager_C")
        if alive(gameInstance) then _ModActor:GetPlayerManagerFromLua(gameInstance) end

        local objectManager = FindFirstOf("BP_PalMapObjectManager_C")
        if alive(objectManager) then _ModActor:GetObjectManagerFromLua(objectManager) end

        local gameState = FindFirstOf("BP_PalGameStateInGame_C")
        if alive(gameState) then _ModActor:GetGameStateFromLua(gameState) end
        trace("possession:done")
    end))

    RegisterHook("/Script/Pal.PalPlayerCharacter:OnCompleteInitializeParameter", guarded("initparam", function(self)
        trace("initparam:enter")
        -- The stock line was:
        --   if controller:GetPalPlayerState():GetFullName() == playerState:GetFullName()
        -- Four unchecked dereferences, and `playerState` is the module-level pointer to
        -- whichever PalPlayerState was created LAST, server-wide, which dangles the moment
        -- that player disconnects. Take this character's OWN state instead: it is what the
        -- comparison was approximating, it cannot be stale, and it is correct with more
        -- than one player online, which the original was not.
        local char = self:get()
        if not alive(char) then trace("initparam:no char") return end
        local controller = char:GetPalPlayerController()
        if not alive(controller) then trace("initparam:no controller") return end
        local state = controller:GetPalPlayerState()
        if not alive(state) then trace("initparam:no state") return end
        if not alive(_ModActor) then trace("initparam:no ModActor") return end

        local uid = guidToString(state.PlayerUId)
        if uid == nil then trace("initparam:no PlayerUId") return end
        playerUId = uid
        _ModActor:GetPlayerStateFromLua(uid, state)
        trace("initparam:registered " .. uid)
    end))

    RegisterHook("/Script/Pal.PalGameStateInGame:BroadcastChatMessage", guarded("chat", function(self, chatMessage)
    -- RegisterHook("/Script/Pal.PalPlayerController:EnterChat_Receive", function(self, chatMessage)
        if chatMessage:get() ~= nil then
            local messageStruct = chatMessage:get()

            -- local messageData = {
            --     ---@type integer
            --     category = messageStruct.Category,
            --     ---@type string
            --     sender = messageStruct.Sender:ToString(),
            --     ---@type string
            --     senderPlayerUId = guidToString(messageStruct.SenderPlayerUId),
            --     ---@type string
            --     message = messageStruct.Message:ToString(),
            --     ---@type string
            --     receiverPlayerUId = guidToString(messageStruct.ReceiverPlayerUId)
            -- }

            -- 'senderPlayerUId' with a lower-case s does not exist on the struct: the
            -- author's own commented-out reference block above spells it SenderPlayerUId.
            -- So the stock file passed nil here, and the !autohatch commands could never
            -- have worked. Prefer the correct name, fall back rather than assume.
            local senderGuid = messageStruct.SenderPlayerUId
            if senderGuid == nil then senderGuid = messageStruct.senderPlayerUId end
            local senderUId = guidToString(senderGuid)

            if not alive(_ModActor) then trace("chat:no ModActor") return end
            local text = messageStruct.Message:ToString()
            _ModActor:ChatReceived(messageStruct.Category, messageStruct.Sender:ToString(), senderUId, text)

            -- Only the toggle needs the sender's id, so a nil id must not reach saveToJson
            -- and write a malformed entry that loadJson then replays on every boot.
            if senderUId ~= nil then
                if string.find(text, "!autohatch off") then
                    saveToJson({ senderUId, false })
                elseif string.find(text, "!autohatch on") then
                    saveToJson({ senderUId, true })
                end
            end
        end
        
    end))

    RegisterHook("/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal", guarded("hatch", function(self, playerId, archive)
        hatchCount = hatchCount + 1
        trace("hatch:enter #" .. tostring(hatchCount))

        -- The game names the recipient right here, and the mod records it nowhere.
        -- A misroute can only be inferred from a Pal that failed to arrive.
        local ok, rawRecipient = pcall(function() return playerId:get() end)
        trace("hatch:recipient " .. (ok and describeId(rawRecipient) or "unreadable"))
        local egg = self:get()
        if alive(egg) then trace("hatch:egg " .. egg:GetFullName()) end

        if sentBytes and not SEND_BYTES_EVERY_HATCH then trace("hatch:bytes already sent") return end
        if not alive(_ModActor) then trace("hatch:no ModActor") return end
        local ar = archive:get()
        if ar == nil then trace("hatch:no archive") return end
        local bytes = ar.Bytes
        if bytes == nil then trace("hatch:no bytes") return end
        for byteIndex = 1, #bytes do
            _ModActor:GetBytes(bytes[byteIndex])
        end
        sentBytes = true
        trace("hatch:sent " .. tostring(#bytes) .. " bytes")
    end))

    
end

-- Kept so nothing else that reads `playerState` breaks, but it is no longer load-bearing:
-- the initparam hook derives the state from the character's own controller. This value is
-- a raw pointer to the last state created server-wide and goes stale without warning, so
-- treat it as a hint and never dereference it without alive().
NotifyOnNewObject("/Script/Pal.PalPlayerState", function(newPlayerState)
    playerState = newPlayerState
end)

RegisterCustomEvent("Lua_ModInitialized", function(ModActor)
    if ModActor:get() ~= nil and ModActor:get():IsValid() then
        _ModActor = ModActor:get()
        print("Blueprint Loaded!\n")
        loadJson(fp)
    else
        error("AutoHatch ModActor not valid!")
    end
end)

function GetMod(o)
    if o ~= nil then
        if o:IsValid() then
            -- print("FullName: " .. o:GetFullName())
            -- print("FName: " .. o:GetFName():ToString())
            -- print("IsUObject():" ..  tostring(o:IsA("/Script/CoreUObject.Object")))
            -- print("IsActor():" ..  tostring(o:IsA("/Script/Engine.Actor")))
            return true
        else
            print("Is Invalid")
        end
    else
        print("Is Nil")
    end
    return false
end

ExecuteAsync(function()
    local HUDService = FindFirstOf("PalHUDService")

    if HUDService ~= nil and HUDService:IsValid() then
        RegisterHooks()
        return
    end

    NotifyOnNewObject("/Script/Pal.PalHUDService", function(Context)
        RegisterHooks()
    end)
end)
