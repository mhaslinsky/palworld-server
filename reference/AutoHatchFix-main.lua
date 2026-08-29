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
-- ^ Confirmed against the built asset: generated_class().get_path_name() reports exactly this.

-- The Blueprint function's name contains a SPACE. UE named the UFunction from the display form
-- of the graph, so the compiled class exposes "Do Hatch" and NOT "DoHatch". Probing the class
-- default object is what settled it: "DoHatch" answers "Failed to find function", "Do Hatch"
-- answers with a missing-argument error, and only the second shape proves presence.
local BLUEPRINT_HATCH_FN = "Do Hatch"

local SETTINGS_FILE = ".\\Mods\\AutoHatchFix\\Scripts\\PlayerSettings.txt"
-- ^ Lua relative paths resolve against the server process's working directory (C:\PalServer),
--   NOT this script's own folder (AGENTS.md rule 6, "Auto Hatch's saveToJson"). The directory
--   must exist before the first write; ensureSettingsDir() below creates it defensively.

local POLL_INTERVAL_MS = 5000
local HATCH_RETRY_COOLDOWN_MS = 15000
-- ^ How long to wait before re-issuing DoHatch for the same incubator slot. A slot that is
--   still completed after the cooldown gets re-attempted; one that is not yet past cooldown
--   is skipped so a slow or failing bridge call cannot be hammered every 5s.

local VERBOSE_EVERY_N_CYCLES = 6
-- ^ 13 incubators of full per-slot detail every 5s is an unreadable, fast-rolling log. The
--   full per-incubator breakdown prints only every Nth cycle (~30s at the default poll
--   interval) OR immediately when the cycle summary's counts change from the previous one
--   (see summaryChanged / sweepOnce below); the one-line summary still prints every cycle.

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
    -- The function's real name carries a SPACE: "Do Hatch", not "DoHatch". UE's function graph
    -- named it from the display form, and it is what the compiled class exposes. Verified by
    -- probing the class default object: calling "DoHatch" gets "Failed to find function", while
    -- "Do Hatch" gets a wrong-argument-count error, which is the shape that proves it exists.
    --
    -- Colon-call syntax cannot express a name with a space, so index it and pass self manually.
    local ok, err = pcall(function()
        modActor[BLUEPRINT_HATCH_FN](modActor, eggModel, ownerPlayerId)
    end)
    if not ok then
        trace("hatch: " .. BLUEPRINT_HATCH_FN .. " call_ok=false err=" .. tostring(err))
    end
    -- ok only means the call did not throw. Whether anything HATCHED is decided by the slot
    -- disappearing on the next sweep, which is why this returns the call result and the caller
    -- keys its cooldown on the slot rather than on this boolean.
    return ok
end

---------------------------------------------------------------------------------------------
-- The sweep. One pass builds the owner map once (not per-egg), enumerates every incubator in
-- the world (not a join-time map, so an offline owner's incubators are still found), and for
-- each COMPLETED slot whose owner has auto-hatch enabled, dispatches ONE DoHatch call, then
-- records the attempt so a fast repeat sweep does not re-issue it inside the cooldown.
---------------------------------------------------------------------------------------------

local lastAttemptAt = {} -- "modelId:slot" -> os-clock-ms of the last DoHatch call
local cycleCount = 0
local lastSummaryCounts = nil -- previous cycle's summary table, for the change-detection rate limit

local function nowMs()
    return math.floor(os.clock() * 1000)
end

local function summaryChanged(current, previous)
    if previous == nil then return true end
    return current.incubators ~= previous.incubators
        or current.ownersResolved ~= previous.ownersResolved
        or current.ownersOnline ~= previous.ownersOnline
        or current.occupiedSlots ~= previous.occupiedSlots
        or current.completedSlots ~= previous.completedSlots
        or current.hatchesAttempted ~= previous.hatchesAttempted
end

-- Third return value is diagnostic only (one line per OCCUPIED slot, per the task brief) and
-- does not change occupied/completedSlots, which are computed exactly as before. It separates
-- a read's SUCCESS from its VALUE per AGENTS.md/brief: an unreadable GetWorkProgress and a
-- genuinely empty slot must never look the same in the log, and likewise for IsCompleted.
local function occupiedAndCompletedSlots(model, slotNum)
    local occupied, completedSlots, slotDetails = 0, {}, {}
    for slot = 0, slotNum - 1 do
        local progress = nil
        local progressReadOk = pcall(function() progress = model:GetWorkProgress(slot) end)
        -- An occupied slot returns a live UPalWorkProgress; an empty one returns nil.
        -- IsWorkable() is NOT readiness: it read false on every incubator in the measured
        -- sweep, including ones actively hatching, because it reports whether the
        -- STRUCTURE is operable rather than whether an egg is ready.
        if progress ~= nil and alive(progress) then
            occupied = occupied + 1
            local completed = nil
            local completedReadOk = pcall(function() completed = progress:IsCompleted() end)
            if completed == true then completedSlots[#completedSlots + 1] = slot end
            slotDetails[#slotDetails + 1] = string.format(
                "    slot=%d progress_read_ok=%s completed_read_ok=%s completed=%s",
                slot, tostring(progressReadOk), tostring(completedReadOk), tostring(completed))
        end
    end
    return occupied, completedSlots, slotDetails
end

local function sweepOnce(modActor)
    local ownerByModelId = buildOwnerByModelId()
    local eggs = findHatchingEggModels()
    trace("poll: " .. tostring(#eggs) .. " incubator(s) in the world")

    cycleCount = cycleCount + 1
    local summary = {
        incubators = #eggs, ownersResolved = 0, ownersOnline = 0,
        occupiedSlots = 0, completedSlots = 0, hatchesAttempted = 0,
    }
    local detailLines = {}

    for index = 1, #eggs do
        local model = eggs[index]
        if alive(model) then
            -- Diagnostics below are read-only and gathered for EVERY incubator regardless of
            -- which gate later skips it, so the log distinguishes: (a) nothing is completed
            -- yet, (b) the readiness read itself is failing/unreadable, or (c) the owner gate
            -- or the UId->PlayerId lookup is what rejects it. They do not change which
            -- incubators get a DoHatch call: the decision sequence right after this block is
            -- the same one that shipped before, just reading these already-computed values
            -- instead of recomputing them.
            local modelId = nil
            pcall(function() modelId = guidText(model:GetModelInstanceId()) end)
            local owner = modelId ~= nil and ownerByModelId[modelId] or nil
            if owner ~= nil then summary.ownersResolved = summary.ownersResolved + 1 end

            local gateEnabled = isEnabledFor(owner) -- true for owner==nil too; harmless, unused by the gate below in that case

            local slotNum = nil
            local okSlots = pcall(function() slotNum = model:GetItemSlotNum() end)
            local slotsReadable = okSlots and type(slotNum) == "number" and slotNum > 0

            local occupied, completedSlots, slotDetails = 0, {}, {}
            if slotsReadable then
                occupied, completedSlots, slotDetails = occupiedAndCompletedSlots(model, slotNum)
            end
            summary.occupiedSlots = summary.occupiedSlots + occupied
            summary.completedSlots = summary.completedSlots + #completedSlots

            local ownerPlayerId, ownerOnline = nil, false
            if owner ~= nil then
                ownerPlayerId = playerIdForUid(modActor, owner)
                ownerOnline = ownerPlayerId ~= nil
                if ownerOnline then summary.ownersOnline = summary.ownersOnline + 1 end
            end

            detailLines[#detailLines + 1] = string.format(
                "poll.detail: incubator[%d] model=%s owner=%s gate_enabled=%s slots=%s online=%s player_id=%s",
                index, tostring(modelId), owner ~= nil and owner or "UNRESOLVED",
                tostring(gateEnabled), slotsReadable and tostring(slotNum) or "unreadable",
                tostring(ownerOnline), tostring(ownerPlayerId))
            for _, line in ipairs(slotDetails) do
                detailLines[#detailLines + 1] = line
            end

            -- ACTUAL SWEEP DECISION — identical to the pre-instrumentation version.
            if owner == nil then
                -- Unresolved ownership: a map object this incubator's InstanceId does not
                -- match. Not necessarily an error (a structure mid-placement can transiently
                -- lack a builder record), but never delivered blind.
                goto continue
            end

            if not gateEnabled then goto continue end

            if not slotsReadable then goto continue end

            if #completedSlots == 0 then goto continue end

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
                    summary.hatchesAttempted = summary.hatchesAttempted + 1
                    trace("hatch: owner=" .. tostring(owner) .. " playerId=" .. tostring(ownerPlayerId)
                          .. " model=" .. tostring(modelId) .. " slot=" .. tostring(slot))
                    callDoHatch(modActor, model, ownerPlayerId)
                end
            end
        end
        ::continue::
    end

    local verbose = summaryChanged(summary, lastSummaryCounts) or (cycleCount % VERBOSE_EVERY_N_CYCLES == 0)
    if verbose then
        for _, line in ipairs(detailLines) do trace(line) end
    end
    -- completed>0 with attempted=0 points at the gate (owner disabled or offline); completed=0
    -- means there is simply nothing ready yet. Prints every cycle regardless of `verbose`.
    trace(string.format(
        "poll.summary: incubators=%d owners_resolved=%d owners_online=%d occupied=%d completed=%d attempted=%d",
        summary.incubators, summary.ownersResolved, summary.ownersOnline,
        summary.occupiedSlots, summary.completedSlots, summary.hatchesAttempted))
    lastSummaryCounts = summary
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

-- NOT IMPLEMENTED: an in-game chat reply. Neither this file, reference/AutoHatch-main.lua,
-- nor AutoHatch-ModActor.hpp exposes a verified way to SEND a chat line back to a player —
-- BroadcastChatMessage above is hooked as an inbound event (its handler receives an
-- already-constructed FPalChatMessage), not called as an outbound send, and constructing that
-- struct from scratch would be guessing at a signature this codebase has never confirmed
-- (AGENTS.md/brief: never guess a property or function name). Player-visible confirmation
-- would need either a verified send API added to the companion Blueprint ModActor, or a
-- different, confirmed game hook; this file still only writes to the server log (`trace`).
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
        -- "!AH" is the alias the operator actually types; matched case-insensitively and
        -- as a leading command token (not a bare substring search) so it can also take no
        -- argument and fall through to a status report instead of doing nothing.
        local cmd, arg = text:lower():match("^%s*!(%a+)%s*(%a*)")

        if cmd == "autohatch" or cmd == "ah" then
            if arg == "off" then
                playerEnabled[senderUId] = false
                savePlayerSettings()
                trace("chat: " .. senderUId .. " -> disabled")
            elseif arg == "on" then
                playerEnabled[senderUId] = true
                savePlayerSettings()
                trace("chat: " .. senderUId .. " -> enabled")
            else
                -- "!AH" / "!autohatch" with no (or an unrecognized) argument: report state.
                trace("chat: " .. senderUId .. " status enabled=" .. tostring(isEnabledFor(senderUId)))
            end
        elseif cmd == "hatchstatus" then
            trace("chat: " .. senderUId .. " status enabled=" .. tostring(isEnabledFor(senderUId)))
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
