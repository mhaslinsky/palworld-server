-- AutoHatchFix / main.lua — clean-rewrite replacement for Nexus mod 1959 (Auto Hatch).
--
-- THE BUG THIS REPLACES: the original mod runs ONE collection context, shared by every
-- player, under a single global `UseAutoHatch` bool (its own per-player `PlayerSettings`
-- map reads EMPTY at hatch time and gates nothing). So it does not misroute — it correctly
-- resolves each egg's true owner — but it then DELIVERS every hatch through whichever
-- player's context is active, so player B's eggs arrive as though player A collected them.
-- Proven by a controlled test: with A logged fully out, B's eggs deliver to B correctly and
-- do not auto-hatch at all. See reference/README.md "Who an auto-hatched Pal belongs to"
-- and the AIDB replacement-spec (2026-08-29) for the full measurement trail.
--
-- THE FIX: resolve ownership from WORLD state every sweep (not a join-time map, so an
-- offline owner still resolves), and gate delivery on THAT OWNER's own on/off setting,
-- keeping one collection context per owner instead of one shared context for the server.
--
-- WHAT LUA CANNOT DO: deliver the hatch itself. Measured on the live server, ten
-- COMPLETED eggs, addressed to the tester's own live PlayerId while connected —
-- `ObtainHatchedCharacter_ServerInternal`, `RequestObtainSingleHatchedCharacter` and
-- `RequestObtainAllHatchedCharacter` all returned call_ok=true and consumed nothing
-- (occupied slots 10 before, 10 after). So delivery is driven by a companion Blueprint
-- ModActor exposing `DoHatch(EggModel, PlayerId)`. callDoHatch() below is the ONLY place
-- that calls into it — repoint there if the Blueprint's path or signature changes.

local MOD_ACTOR_BLUEPRINT_PATH = "/Game/Mods/AutoHatchFix/ModActor.ModActor_C"
-- ^ REPOINT HERE once the companion Blueprint's real package path is known. Nothing else
--   in this file needs to change to retarget it.

local SETTINGS_FILE = ".\\Mods\\AutoHatchFix\\Scripts\\PlayerSettings.txt"
-- ^ Lua relative paths resolve against the server process's working directory (C:\PalServer),
--   NOT this script's own folder (AGENTS.md rule 6, "Auto Hatch's saveToJson"). The directory
--   must exist before the first write; ensureSettingsDir() below creates it defensively.

local POLL_INTERVAL_MS = 5000
local HATCH_RETRY_COOLDOWN_MS = 15000
-- ^ How long to wait before re-issuing DoHatch for the same incubator slot. A slot that is
--   still completed after the cooldown gets re-attempted; one that is not yet past cooldown
--   is skipped so a slow or failing bridge call cannot be hammered every 5s.

---------------------------------------------------------------------------------------------
-- Guards, shared with reference/AutoHatch-main.lua's hardening style: a dead UObject and a
-- nil are the same thing to every caller here, and telling them apart is what stops a
-- dereference of a stale pointer from crashing the process instead of just failing a hook.
---------------------------------------------------------------------------------------------

local function alive(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid
end

-- Every trace line names its origin: "poll" (the sweep loop), "hatch" (a delivery attempt),
-- "chat" (a player command) or "init" (mod bring-up). Untagged hook lines have already
-- produced two false conclusions in this codebase (a UE4SS hook fires for ANY caller,
-- including this file's own probes), so nothing here logs without a tag.
local function trace(where)
    print("[AutoHatchFix] " .. where .. "\n")
end

-- Propagating the wrapped function's return value is load-bearing, not tidiness. LoopAsync
-- STOPS when its callback returns true and continues on false, so a wrapper that swallowed the
-- return handed it nil instead, leaving the poll loop's continuation resting on however UE4SS
-- happens to coerce nil at that boundary. That is unverified, and if it coerces the wrong way
-- the sweep runs exactly once and then stops with no error anywhere.
--
-- On a caught error the loop must keep going, so return false explicitly rather than nil: a
-- transient failure in one sweep should not end the mod for the rest of the server's life.
local function guarded(name, body)
    return function(...)
        local args = table.pack(...)
        local ok, result = pcall(function() return body(table.unpack(args, 1, args.n)) end)
        if not ok then
            trace(name .. " failed: " .. tostring(result))
            return false
        end
        return result
    end
end

local function guidToString(guid)
    if guid == nil then return nil end
    return string.format("%08X%08X%08X%08X", guid.A & 0xffffffff, guid.B & 0xffffffff, guid.C & 0xffffffff,
        guid.D & 0xffffffff)
end

local function guidText(value)
    local ok, text = pcall(guidToString, value)
    if ok then return text end
    return nil
end

-- TMap iteration in this UE4SS fork hands back wrapper objects; :get() unwraps to the real
-- UObject/value. Some values are plain (e.g. already a table or primitive), so unwrap is a
-- best-effort pcall rather than an assumed method.
local function unwrap(value)
    local inner = value
    pcall(function() inner = value:get() end)
    return inner
end

local function readProperty(object, name)
    if not alive(object) then return false, nil end
    local ok, value = pcall(function() return object[name] end)
    if not ok then return false, nil end
    return true, value
end

---------------------------------------------------------------------------------------------
-- Per-player enable/disable. This is OUR OWN state, deliberately not the Blueprint's dead
-- `PlayerSettings` map (which reads empty at hatch time in the original mod and gates
-- nothing). A player who has never sent a command defaults to enabled=true, mirroring the
-- original's always-on global — anyone who wants it off says so with `!autohatch off`.
---------------------------------------------------------------------------------------------

local playerEnabled = {} -- PlayerUId (hex string) -> bool

local function ensureSettingsDir()
    -- io.open never creates a missing DIRECTORY (only a missing file), and this exact
    -- failure already cost a night of confusion on the original mod (AGENTS.md rule 6:
    -- "No such file or directory" means the directory is missing, not the file). Best
    -- effort: os.execute a silent mkdir; a failure here just means the first save also
    -- fails, loudly, rather than being masked.
    pcall(function() os.execute('mkdir ".\\Mods\\AutoHatchFix\\Scripts" 2>nul') end)
end

local function loadPlayerSettings()
    local file = io.open(SETTINGS_FILE, "r")
    if file == nil then
        trace("init: no settings file yet at " .. SETTINGS_FILE .. " (defaults apply)")
        return
    end
    local loaded = 0
    for line in file:lines() do
        local uid, flag = line:match("^(%x+)=([01])$")
        if uid ~= nil then
            playerEnabled[uid] = (flag == "1")
            loaded = loaded + 1
        end
    end
    file:close()
    trace("init: loaded " .. tostring(loaded) .. " player setting(s)")
end

local function savePlayerSettings()
    ensureSettingsDir()
    local file = io.open(SETTINGS_FILE, "w")
    if file == nil then
        trace("save: FAILED to open " .. SETTINGS_FILE .. " for write")
        return false
    end
    for uid, enabled in pairs(playerEnabled) do
        file:write(uid .. "=" .. (enabled and "1" or "0") .. "\n")
    end
    file:close()
    return true
end

local function isEnabledFor(ownerUId)
    local value = playerEnabled[ownerUId]
    if value == nil then return true end -- never-configured player: on by default
    return value
end

---------------------------------------------------------------------------------------------
-- Ownership from WORLD state (not a join-time map — this is the entire point of the
-- rewrite; see reference/README.md "Ownership is a two-step join"). An egg is a CONCRETE
-- model (UPalMapObjectConcreteModelBase -> ...HatchingEggModelBase -> ...MultiHatchingEggModel)
-- while BuildPlayerUId is declared on UPalMapObjectModel, a DIFFERENT object — reading it off
-- the egg returns a TrivialObject (UE4SS's answer for ANY unknown name, so it looks exactly
-- like an unreadable field rather than a wrong-object read). The join is
-- egg:GetModelInstanceId() against the map object's own InstanceId.
---------------------------------------------------------------------------------------------

local function buildOwnerByModelId()
    local ownerByModelId = {}
    local models = nil
    local okModels = pcall(function() models = FindAllOf("PalMapObjectModel") end)
    if not okModels or models == nil then
        trace("poll: FindAllOf PalMapObjectModel ok=" .. tostring(okModels) .. " result=nil")
        return ownerByModelId
    end
    local mapped = 0
    for index = 1, #models do
        local mapObject = models[index]
        local instanceId, builder = nil, nil
        pcall(function() instanceId = guidText(mapObject.InstanceId) end)
        pcall(function() builder = guidText(mapObject.BuildPlayerUId) end)
        if instanceId ~= nil and builder ~= nil then
            ownerByModelId[instanceId] = builder
            mapped = mapped + 1
        end
    end
    trace("poll: map objects=" .. tostring(#models) .. " with a readable builder=" .. tostring(mapped))
    return ownerByModelId
end

local function findHatchingEggModels()
    -- The base class may be abstract in this build (measured: FindAllOf on it returned
    -- nothing while incubators were visibly present in the world), so fall back to the
    -- concrete multi-slot model rather than concluding the world holds none.
    local found = nil
    local ok = pcall(function() found = FindAllOf("PalMapObjectHatchingEggModelBase") end)
    if not ok or found == nil or #found == 0 then
        ok = pcall(function() found = FindAllOf("PalMapObjectMultiHatchingEggModel") end)
    end
    if not ok or found == nil then return {} end
    return found
end

---------------------------------------------------------------------------------------------
-- PlayerId lookup. GameState.PlayerArray holds only CONNECTED players (AGENTS.md /
-- replacement-spec constraint), so an offline owner has no PlayerId and cannot be addressed
-- by that int32. This is not a bug to work around: an egg whose owner resolves but who has
-- no PlayerId is simply left uncollected in the world, and the next sweep after that owner
-- reconnects picks it up automatically, since the egg itself is untouched by a skip.
---------------------------------------------------------------------------------------------

local function getGameState(modActor)
    local gameState = nil
    pcall(function() gameState = modActor["Game State"] end)
    if gameState == nil then pcall(function() gameState = modActor:GetGameStateFromLua() end) end
    return gameState
end

local function playerIdForUid(modActor, ownerUId)
    local gameState = getGameState(modActor)
    if gameState == nil then return nil end
    local okArr, playerArray = readProperty(gameState, "PlayerArray")
    if not okArr or playerArray == nil then return nil end
    local count = nil
    if not pcall(function() count = #playerArray end) or type(count) ~= "number" then return nil end

    for index = 1, count do
        local entry = nil
        if pcall(function() entry = playerArray[index] end) and entry ~= nil then
            local state = unwrap(entry)
            local uid = nil
            pcall(function() uid = guidText(state.PlayerUId) end)
            if uid == ownerUId then
                local okId, playerId = readProperty(state, "PlayerId")
                if okId then return playerId end
            end
        end
    end
    return nil -- owner is offline; not an error
end

---------------------------------------------------------------------------------------------
-- The bridge. THIS IS THE ONLY FUNCTION THAT CALLS INTO THE BLUEPRINT. Everything above
-- builds the (eggModel, ownerPlayerId) pair; everything below decides WHEN to call. If the
-- companion Blueprint's function name or parameter order changes, this is the one place
-- to edit.
--
-- call_ok=true is worthless as evidence by itself (measured three times over on the game's
-- own reflected obtain functions: pcall succeeded and consumed nothing). The caller is
-- responsible for comparing occupied-slot counts before and after; this function only
-- reports whether the call THREW.
---------------------------------------------------------------------------------------------

local function callDoHatch(modActor, eggModel, ownerPlayerId)
    if not alive(modActor) then
        trace("hatch: no ModActor, cannot deliver")
        return false
    end
    local ok, err = pcall(function() modActor:DoHatch(eggModel, ownerPlayerId) end)
    if not ok then
        trace("hatch: DoHatch call_ok=false err=" .. tostring(err))
    end
    return ok
end

---------------------------------------------------------------------------------------------
-- The sweep. One pass builds the owner map once (not per-egg), enumerates every incubator in
-- the world (not a join-time map, so an offline owner's incubators are still found), and for
-- each COMPLETED slot whose owner has auto-hatch enabled, dispatches ONE DoHatch call, then
-- records the attempt so a fast repeat sweep does not re-issue it inside the cooldown.
---------------------------------------------------------------------------------------------

local lastAttemptAt = {} -- "modelId:slot" -> os-clock-ms of the last DoHatch call

local function nowMs()
    return math.floor(os.clock() * 1000)
end

local function occupiedAndCompletedSlots(model, slotNum)
    local occupied, completedSlots = 0, {}
    for slot = 0, slotNum - 1 do
        local progress = nil
        pcall(function() progress = model:GetWorkProgress(slot) end)
        -- An occupied slot returns a live UPalWorkProgress; an empty one returns nil.
        -- IsWorkable() is NOT readiness: it read false on every incubator in the measured
        -- sweep, including ones actively hatching, because it reports whether the
        -- STRUCTURE is operable rather than whether an egg is ready.
        if progress ~= nil and alive(progress) then
            occupied = occupied + 1
            local completed = nil
            pcall(function() completed = progress:IsCompleted() end)
            if completed == true then completedSlots[#completedSlots + 1] = slot end
        end
    end
    return occupied, completedSlots
end

local function sweepOnce(modActor)
    local ownerByModelId = buildOwnerByModelId()
    local eggs = findHatchingEggModels()
    trace("poll: " .. tostring(#eggs) .. " incubator(s) in the world")

    for index = 1, #eggs do
        local model = eggs[index]
        if alive(model) then
            local modelId = nil
            pcall(function() modelId = guidText(model:GetModelInstanceId()) end)
            local owner = modelId ~= nil and ownerByModelId[modelId] or nil

            if owner == nil then
                -- Unresolved ownership: a map object this incubator's InstanceId does not
                -- match. Not necessarily an error (a structure mid-placement can transiently
                -- lack a builder record), but never delivered blind.
                goto continue
            end

            if not isEnabledFor(owner) then goto continue end

            local slotNum = nil
            local okSlots = pcall(function() slotNum = model:GetItemSlotNum() end)
            if not okSlots or type(slotNum) ~= "number" or slotNum <= 0 then goto continue end

            local _, completedSlots = occupiedAndCompletedSlots(model, slotNum)
            if #completedSlots == 0 then goto continue end

            local ownerPlayerId = playerIdForUid(modActor, owner)
            if ownerPlayerId == nil then
                -- Owner is offline. Nothing to address delivery to; the egg stays put and
                -- the next sweep after they reconnect will pick it up. This is a design
                -- choice, not a failure: holding beats hatching to nobody.
                goto continue
            end

            for slotIndex = 1, #completedSlots do
                local slot = completedSlots[slotIndex]
                local key = tostring(modelId) .. ":" .. tostring(slot)
                local last = lastAttemptAt[key]
                local now = nowMs()
                if last == nil or (now - last) >= HATCH_RETRY_COOLDOWN_MS then
                    lastAttemptAt[key] = now
                    trace("hatch: owner=" .. tostring(owner) .. " playerId=" .. tostring(ownerPlayerId)
                          .. " model=" .. tostring(modelId) .. " slot=" .. tostring(slot))
                    callDoHatch(modActor, model, ownerPlayerId)
                end
            end
        end
        ::continue::
    end
end

---------------------------------------------------------------------------------------------
-- Mod bring-up and chat commands. Finding the ModActor does not depend on a player joining
-- (unlike the original's possession hook) — the sweep loop itself looks for it until found,
-- so an empty server still enumerates the world once the Blueprint exists.
---------------------------------------------------------------------------------------------

local _ModActor = nil

local function findModActor()
    if alive(_ModActor) then return _ModActor end
    local candidates = nil
    if pcall(function() candidates = FindAllOf("ModActor_C") end) and candidates ~= nil then
        for index = 1, #candidates do
            local candidate = candidates[index]
            local isOurs = nil
            pcall(function() isOurs = candidate:IsA(MOD_ACTOR_BLUEPRINT_PATH) end)
            if isOurs then
                _ModActor = candidate
                trace("init: found ModActor at " .. MOD_ACTOR_BLUEPRINT_PATH)
                return _ModActor
            end
        end
    end
    return nil
end

local function RegisterChatHook()
    RegisterHook("/Script/Pal.PalGameStateInGame:BroadcastChatMessage", guarded("chat", function(self, chatMessage)
        if chatMessage:get() == nil then return end
        local messageStruct = chatMessage:get()

        -- The field is `SenderPlayerUId` (capital S). The original mod's stock file read a
        -- lower-case `senderPlayerUId`, which does not exist on the struct and returns nil —
        -- see reference/README.md and AGENTS.md rule 6. Prefer the correct name, fall back
        -- rather than assume this build matches.
        local senderGuid = messageStruct.SenderPlayerUId
        if senderGuid == nil then senderGuid = messageStruct.senderPlayerUId end
        local senderUId = guidText(senderGuid)
        if senderUId == nil then return end

        local text = messageStruct.Message:ToString()
        if string.find(text, "!autohatch off") then
            playerEnabled[senderUId] = false
            savePlayerSettings()
            trace("chat: " .. senderUId .. " -> disabled")
        elseif string.find(text, "!autohatch on") then
            playerEnabled[senderUId] = true
            savePlayerSettings()
            trace("chat: " .. senderUId .. " -> enabled")
        elseif string.find(text, "!hatchstatus") then
            local enabled = isEnabledFor(senderUId)
            trace("chat: " .. senderUId .. " status enabled=" .. tostring(enabled))
        end
    end))
end

local function RegisterPollLoop()
    LoopAsync(POLL_INTERVAL_MS, guarded("poll", function()
        local modActor = findModActor()
        if modActor == nil then
            trace("poll: no ModActor yet, waiting")
            return false -- keep looping; do not stop on a transient absence
        end
        sweepOnce(modActor)
        return false
    end))
end

ExecuteAsync(function()
    loadPlayerSettings()
    RegisterChatHook()
    RegisterPollLoop()
    trace("init: AutoHatchFix loaded")
end)
