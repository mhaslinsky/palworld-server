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

-- THIS FLAG IS THE BUG FIX, not a diagnostic. Stock sends a hatched character's archive to
-- the blueprint once per server lifetime and returns early forever after, so every later
-- hatch reaches ObtainHatchedCharacter_ServerInternal(RequestPlayerId, Archive) carrying
-- the FIRST hatch's archive. The game resolves the destination from that archive rather
-- than from RequestPlayerId, which is why the id is always correct and always ignored, and
-- why whoever hatches first after a server start collects everyone's Pals.
--
-- Measured 2026-08-29, both players in one session: hatch #1 logged "sent 21 bytes" and
-- hatches #2 to #10 logged "bytes already sent", while the mod addressed all seven of the
-- second player's hatches correctly to 5C104B96 / Player ID 257 and they landed with
-- 084390E6 anyway.
--
-- It was set true once before, on 2026-08-28, and wedged the server: the archive DOUBLED
-- every hatch (6.8 MB, 13.7 MB, 27.5 MB over hatches 21-23) and the send loop makes one
-- call per byte, so each hatch took twice as long as the last until the game thread stopped
-- answering the REST API. That growth was a SEPARATE defect: nothing emptied the
-- blueprint's ByteArray between sends. The clear below fixes it and is measured flat at 21
-- bytes, so the two have never run together until now. If the archive ever grows across
-- hatches again, the clear has stopped working and this flag must go back to false.
local SEND_BYTES_EVERY_HATCH = false
local hatchCount = 0
local BYTE_CEILING = 10000000
-- Writing the true owner into WorkProgress_To_PlayerUId__Map read back correctly and
-- changed nothing, so it is a live mutation with no benefit. Off unless re-testing.
local APPLY_OWNER_FIX = false

-- The recipient arrives as an FGuid on some paths and a plain ID on others. Because this only
-- feeds a log line, a wrong guess must degrade to text rather than throw.
local function describeId(value)
    if value == nil then return "nil" end
    local ok, text = pcall(guidToString, value)
    if ok and text ~= nil then return text end
    return tostring(value)
end

-- INTROSPECTION, temporary (2026-08-28). The routing decision lives in the compiled
-- ModActor blueprint and the pak is Oodle-compressed, so it cannot be read statically
-- without a decompressor. It is decompressed in memory here, so ask it directly.
-- Remove once the recipient is identified.
--
-- There is deliberately no "dump only the first N hatches" budget here. That gate existed,
-- keyed on a server-wide hatch counter, and it is what invalidated three findings: with two
-- players hatching, the budget was spent on whoever hatched first, so the misrouting hatch
-- ran with the probes already exhausted. Reads that never happened were recorded as reads
-- that came back empty. Probes are cheap; a wrong negative costs a live test round.
local RAN_GLOBAL_DUMPERS = false

-- A cached recipient on the ModActor would live under one of these.
local PROBE_MODACTOR = {
    "PlayerState", "PlayerStates", "PlayerStateMap", "PlayerStateArray",
    "TargetPlayer", "TargetPlayerState", "TargetPlayerUId", "CurrentPlayer",
    "Owner", "OwnerPlayerUId", "PlayerUId", "PlayerUID", "LastPlayer",
    "PlayerManager", "ObjectManager", "GameState",
    "EggArray", "PalEggArray", "Eggs", "Incubators", "BreedFarms", "Bytes",
}

-- The egg map object is the better routing signal: the mod prints a correct per-incubator
-- PlayerUId at discovery, so the truth is carried somewhere on the object.
local PROBE_EGG = {
    "OwnerPlayerUId", "BuildPlayerUId", "BuilderPlayerUId", "CreatePlayerUId",
    "PlayerUId", "OwnerPlayerUID", "BaseCampId", "OwnerBaseCampId", "BaseCampIdBelongTo",
    "GroupId", "GuildId", "OwnerGroupId", "MapObjectId", "MapObjectConcreteModelId",
    "WorkProgress", "PalEggArray", "Eggs",
}

local function describeValue(value)
    local kind = type(value)
    if value == nil then return "nil" end
    if kind == "number" or kind == "boolean" or kind == "string" then
        return kind .. " " .. tostring(value)
    end
    if kind == "userdata" then
        local unwrapped = nil
        local okUnwrap = pcall(function() unwrapped = value:get() end)
        if okUnwrap and unwrapped ~= nil and unwrapped ~= value then
            local okFull, full = pcall(function() return unwrapped:GetFullName() end)
            if okFull and full ~= nil then return "obj " .. tostring(full) end
            local okInnerGuid, innerText = pcall(guidToString, unwrapped)
            if okInnerGuid and innerText ~= nil then return "guid " .. innerText end
        end
        local okGuid, text = pcall(guidToString, value)
        if okGuid and text ~= nil and text ~= "00000000000000000000000000000000" then
            return "guid " .. text
        end
        local okFull, full = pcall(function() return value:GetFullName() end)
        if okFull and full ~= nil then
            if okGuid and text ~= nil then return "guid " .. text .. " (" .. tostring(full) .. ")" end
            return "obj " .. tostring(full)
        end
        if okGuid and text ~= nil then return "guid " .. text end
        return "userdata " .. tostring(value)
    end
    if kind == "table" then
        local okLen, len = pcall(function() return #value end)
        return "table len=" .. (okLen and tostring(len) or "?")
    end
    return kind .. " " .. tostring(value)
end

local function readProperty(object, name)
    local value = nil
    local ok = pcall(function() value = object:GetPropertyValue(name) end)
    if ok then return true, value end
    ok = pcall(function() value = object[name] end)
    if ok then return true, value end
    return false, nil
end

-- Raw UE units, not in-game map coordinates. The two bases are far enough apart that
-- clustering raw values separates them without needing the conversion.
local function describeLocation(object)
    local text = nil
    pcall(function()
        local loc = object:K2_GetActorLocation()
        if loc ~= nil then text = string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) end
    end)
    if text == nil then
        pcall(function()
            local loc = object.RootComponent.RelativeLocation
            if loc ~= nil then text = string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) end
        end)
    end
    return text or "unknown"
end

-- ForEachProperty only walks properties declared on the struct itself, so inherited ones
-- need the SuperStruct chain climbed by hand (UE4SS docs, UStruct).
local function dumpObject(label, object, probeNames)
    if not alive(object) then trace("dump:" .. label .. " object not alive") return end

    local okClass, cls = pcall(function() return object:GetClass() end)
    if not okClass or cls == nil then trace("dump:" .. label .. " GetClass FAILED") return end
    local okName, clsName = pcall(function() return cls:GetFullName() end)
    trace("dump:" .. label .. " class " .. (okName and tostring(clsName) or "?"))

    local total = 0
    local depth = 0
    local current = cls
    while current ~= nil and depth < 8 and total < 400 do
        local okDepthName, depthName = pcall(function() return current:GetFullName() end)
        trace("dump:" .. label .. " -- depth " .. depth .. " " .. (okDepthName and tostring(depthName) or "?"))
        local okEach = pcall(function()
            current:ForEachProperty(function(prop)
                total = total + 1
                if total > 400 then return true end
                local name = nil
                pcall(function() name = prop:GetFName():ToString() end)
                local ptype = "?"
                pcall(function() ptype = prop:GetClass():GetFName():ToString() end)
                local line = "dump:" .. label .. " prop " .. tostring(name) .. " : " .. tostring(ptype)
                if name ~= nil then
                    local okValue, value = readProperty(object, name)
                    line = line .. " = " .. (okValue and describeValue(value) or "<unreadable>")
                end
                trace(line)
            end)
        end)
        if not okEach then trace("dump:" .. label .. " ForEachProperty UNAVAILABLE at depth " .. depth) break end
        local okSuper, super = pcall(function() return current:GetSuperStruct() end)
        if not okSuper or super == nil or not alive(super) then break end
        current = super
        depth = depth + 1
    end
    trace("dump:" .. label .. " property total " .. tostring(total) .. " over " .. tostring(depth + 1) .. " level(s)")

    for _, name in ipairs(probeNames) do
        local okValue, value = readProperty(object, name)
        if okValue and value ~= nil then
            trace("dump:" .. label .. " probe " .. name .. " = " .. describeValue(value))
        end
    end
end

-- UE4SS's own dumpers write full reflection data to files. They exist from 4.0.0 in the
-- docs and this build is a 3.0.1 fork, so each is checked for rather than assumed.
local function runGlobalDumpers()
    if RAN_GLOBAL_DUMPERS then return end
    RAN_GLOBAL_DUMPERS = true
    local names = { "GenerateSDK", "DumpAllObjects", "GenerateLuaTypes", "DumpJMAP", "DumpUSMAP" }
    for _, name in ipairs(names) do
        local fn = _G[name]
        if type(fn) == "function" then
            trace("dump:global " .. name .. " calling")
            local ok, err = pcall(fn)
            trace("dump:global " .. name .. (ok and " OK" or (" FAILED " .. tostring(err))))
        else
            trace("dump:global " .. name .. " ABSENT")
        end
    end
end

-- ROUTING PROBE, temporary (2026-08-28). The CXX dump gives the blueprint's resolution
-- chain: GetEggOwnerUId* resolves the true owner, GetLoggedInPlayerUId then maps it to a
-- logged-in player, and AutoHatch delivers. If step two collapses every owner onto one
-- player, that is the misrouting bug. This calls each step and logs what it returns.

-- UE4SS writes an 'Out' parameter into a table passed in that slot and returns nothing,
-- so the answer is read back out of the table rather than from a return value. Proved by
-- the 2026-08-28 probe: passing nil says "no table was on the stack", passing a table
-- succeeds silently.
-- A UE4SS hook fires for ANY caller, including this file. Without this counter the probe's
-- own calls come back through the hooks and read as the blueprint's behaviour, which is
-- exactly the circular evidence that made GetLoggedInPlayerUId look cleared twice.
local ownCallDepth = 0

local function callBlueprint(object, name, ...)
    local fn = nil
    local okLookup = pcall(function() fn = object[name] end)
    if not okLookup or fn == nil then trace("route:" .. name .. " ABSENT") return nil end

    local out = {}
    local args = table.pack(...)
    args[args.n + 1] = out
    args.n = args.n + 1

    ownCallDepth = ownCallDepth + 1
    local okCall, err = pcall(function() object[name](object, table.unpack(args, 1, args.n)) end)
    ownCallDepth = ownCallDepth - 1
    if not okCall then trace("route:" .. name .. " FAILED: " .. tostring(err)) return nil end

    local found = false
    for key, value in pairs(out) do
        found = true
        trace("route:" .. name .. " out." .. tostring(key) .. " = " .. describeValue(value))
    end
    if not found then trace("route:" .. name .. " out table EMPTY") end
    return out
end

-- TMap access from Lua is not documented for this build, so each shape is attempted and
-- the one that works is reported rather than assumed.
local function dumpMap(object, name, limit)
    local map = nil
    local okGet = pcall(function() map = object[name] end)
    if not okGet or map == nil then trace("map:" .. name .. " UNREADABLE") return end

    local num = nil
    pcall(function() num = map:Num() end)
    if num == nil then pcall(function() num = #map end) end
    trace("map:" .. name .. " num=" .. tostring(num))

    local shown = 0
    local okEach = pcall(function()
        map:ForEach(function(key, value)
            if shown >= limit then return true end
            shown = shown + 1
            local rawKey, rawValue = key, value
            pcall(function() rawKey = key:get() end)
            pcall(function() rawValue = value:get() end)
            trace("map:" .. name .. " " .. describeValue(rawKey) .. " => " .. describeValue(rawValue))
        end)
    end)
    if not okEach then trace("map:" .. name .. " ForEach UNAVAILABLE") end
end

-- OWNERSHIP FIX (2026-08-28). The mod resolves an egg's owner through
-- WorkProgress_To_PlayerUId__Map, EggToPlayerMap and PlayerBreedFarms, and all three are
-- empty at hatch time, so GetEggOwnerUId* returns a null GUID and delivery falls back to
-- whichever player registered first since server start. That is the "everyone's eggs
-- hatch to me" bug.
--
-- The correct owner IS known: PlayerEggIncubators maps each incubator's PalMapObjectModel
-- to its owner, and it is populated and accurate. The hatching object is the CONCRETE
-- model, whose ModelInstanceId is that PalMapObjectModel's InstanceId. That is the join.
--
-- This populates the map the blueprint already reads rather than calling AutoHatch
-- directly, so there is no second delivery path to race and no duplicate Pal.
local function guidText(value)
    local ok, text = pcall(guidToString, value)
    if ok then return text end
    return nil
end

local function unwrap(value)
    local inner = value
    pcall(function() inner = value:get() end)
    return inner
end

local function ownerForEgg(egg)
    local modelId = nil
    pcall(function() modelId = guidText(egg.ModelInstanceId) end)
    if modelId == nil then trace("fix: egg has no ModelInstanceId") return nil end

    local incubators = nil
    pcall(function() incubators = _ModActor.PlayerEggIncubators end)
    if incubators == nil then trace("fix: PlayerEggIncubators unreadable") return nil end

    local owner = nil
    pcall(function()
        incubators:ForEach(function(key, value)
            local model = unwrap(key)
            local instanceId = nil
            pcall(function() instanceId = guidText(model.InstanceId) end)
            if instanceId ~= nil and instanceId == modelId then
                owner = unwrap(value)
                return true
            end
        end)
    end)
    if owner == nil then trace("fix: no incubator matched model " .. tostring(modelId)) end
    return owner
end

local function workProgressesForEgg(egg)
    local found = {}
    local incubatorMap = nil
    pcall(function() incubatorMap = _ModActor.WorkProgress_To_Incubator_Map end)
    if incubatorMap == nil then return found end
    local eggName = nil
    pcall(function() eggName = egg:GetFullName() end)
    if eggName == nil then return found end
    pcall(function()
        incubatorMap:ForEach(function(key, value)
            local incubator = unwrap(value)
            local name = nil
            pcall(function() name = incubator:GetFullName() end)
            if name == eggName then found[#found + 1] = unwrap(key) end
        end)
    end)
    return found
end

local function applyOwnerFix(egg)
    if not alive(_ModActor) or not alive(egg) then return end

    local owner = ownerForEgg(egg)
    if owner == nil then return end
    local ownerId = guidText(owner)
    trace("fix: resolved owner " .. tostring(ownerId))

    local ownerMap = nil
    pcall(function() ownerMap = _ModActor.WorkProgress_To_PlayerUId__Map end)
    if ownerMap == nil then trace("fix: WorkProgress_To_PlayerUId__Map unreadable") return end

    local targets = workProgressesForEgg(egg)
    if #targets == 0 then trace("fix: no WorkProgress maps to this egg") return end

    -- Add() is the documented TMap mutator; index assignment is the fallback if this
    -- UE4SS fork does not expose it. Whichever lands is reported, never assumed.
    local written = 0
    for _, workProgress in ipairs(targets) do
        local okAdd = pcall(function() ownerMap:Add(workProgress, owner) end)
        if not okAdd then okAdd = pcall(function() ownerMap[workProgress] = owner end) end
        if okAdd then written = written + 1 end
    end

    local num = nil
    pcall(function() num = ownerMap:Num() end)
    if num == nil then pcall(function() num = #ownerMap end) end

    -- Read the map back and count what is actually in it, and whether OUR owner is there.
    local counted = 0
    local mine = 0
    local ownerId = guidText(owner)
    pcall(function()
        ownerMap:ForEach(function(key, value)
            counted = counted + 1
            if guidText(unwrap(value)) == ownerId then mine = mine + 1 end
        end)
    end)
    trace("fix: wrote " .. tostring(written) .. "/" .. tostring(#targets) ..
          ", map num=" .. tostring(num) .. " readback=" .. tostring(counted) ..
          " matching=" .. tostring(mine))
end

-- Every UId in the chain is correct and the Pal still lands on the wrong player, so the
-- suspect is now the integer index the blueprint derives from that UId via GivePlayerID.
-- The authoritative index lives on each APalPlayerState. Read it per player so the mod's
-- claimed "Player ID: 256/257" can be checked against the game's own numbering rather
-- than assumed to match it.
local function dumpPlayerStateIds()
    local players = nil
    pcall(function() players = _ModActor.Players end)
    if players == nil then trace("pid: Players unreadable") return end

    pcall(function()
        players:ForEach(function(key, value)
            local uid = guidText(unwrap(key))
            local state = unwrap(value)
            if not alive(state) then trace("pid: " .. tostring(uid) .. " state not alive") return end

            local reported = {}
            local okClass, cls = pcall(function() return state:GetClass() end)
            if okClass and cls ~= nil then
                local current = cls
                local depth = 0
                while current ~= nil and depth < 8 do
                    pcall(function()
                        current:ForEachProperty(function(prop)
                            local name = nil
                            pcall(function() name = prop:GetFName():ToString() end)
                            if name == nil then return end
                            -- Only integer-ish fields whose name looks like an identifier:
                            -- dereferencing every property on a live player state is how
                            -- this codebase has crashed before.
                            if string.find(name, "Id") or string.find(name, "ID")
                               or string.find(name, "Index") or string.find(name, "Number") then
                                local ptype = "?"
                                pcall(function() ptype = prop:GetClass():GetFName():ToString() end)
                                if string.find(ptype, "Int") or string.find(ptype, "Byte") then
                                    local value = nil
                                    pcall(function() value = state:GetPropertyValue(name) end)
                                    if type(value) == "number" then
                                        reported[#reported + 1] = name .. "=" .. tostring(value)
                                    end
                                end
                            end
                        end)
                    end)
                    local okSuper, super = pcall(function() return current:GetSuperStruct() end)
                    if not okSuper or super == nil or not alive(super) then break end
                    current = super
                    depth = depth + 1
                end
            end
            trace("pid: " .. tostring(uid) .. " -> " .. (#reported > 0 and table.concat(reported, " ") or "no integer id fields found"))
        end)
    end)
end

-- The native header names the hook's parameter RequestPlayerId, which is who ASKED for the
-- hatch, not who owns the result. The Pal's own owner lives on the egg, in
-- HatchedCharacterSaveParameter.OwnerPlayerUId, and a Pal inherits it. If an egg laid in a
-- guild breed farm is stamped with the wrong member at creation, every UId downstream can
-- be correct and the Pal still lands on that member. This reads the stamp.
local function probeEggOwnerStamp(egg)
    if not alive(egg) then return end

    local param = nil
    local okParam = pcall(function() param = egg.HatchedCharacterSaveParameter end)
    if not okParam or param == nil then trace("stamp: HatchedCharacterSaveParameter UNREADABLE") return end

    local owner = nil
    pcall(function() owner = guidText(param.OwnerPlayerUId) end)
    trace("stamp: OwnerPlayerUId = " .. tostring(owner))

    local oldCount = nil
    pcall(function() oldCount = #param.OldOwnerPlayerUIds end)
    trace("stamp: OldOwnerPlayerUIds count = " .. tostring(oldCount))

    -- Named fields worth seeing if the direct read above came back nil: the struct layout
    -- differs between the single and multi hatching classes in the native header.
    for _, name in ipairs({ "CharacterID", "Level", "OwnerPlayerUId" }) do
        local value = nil
        local okValue = pcall(function() value = param[name] end)
        if okValue and value ~= nil then
            trace("stamp: param." .. name .. " = " .. describeValue(value))
        end
    end
end

-- ModActor_C is a singleton actor found via FindAllOf. A server-spawned actor is owned by
-- the PlayerController of the FIRST player to join, and a unicast client RPC routes to the
-- actor's Owner rather than to any UId in the payload. That would let the blueprint log the
-- correct recipient while the engine delivers to the first player, which is every symptom
-- seen here. One read settles it.
-- Candidate one-shots inside the blueprint. If one of these flips true on the first hatch
-- and stays true, it is the captor rather than the Lua's sentBytes, which sending every
-- hatch already failed to defeat.
local RESET_USED_MULTI_HATCH = false

-- GROUND TRUTH. Every probe so far reads what the mod INTENDS; none reads where the Pal
-- actually lands. Two hooks bracket the decision.
--
-- ModActor_C:GivePlayerID is the blueprint's own routing call, taken from the live object
-- dump's function list. It was never hooked because the branch was reading the mod's Lua
-- half and this half is compiled.
--
-- PalCharacterContainerManager:TryGetContainer is the game-side chokepoint: a delivery has
-- to resolve a destination FPalContainerId through it, so it names the receiving container
-- even when the mod's own intent is already wrong.
--
-- FindEmptySlot was hooked here first and is a settled NEGATIVE: it registered and never
-- fired inside a hatch window, so insertion does not go through a slot search. Recorded
-- rather than deleted, because the next reader will otherwise reach for it again.
--
-- Both are gated to the hatch window; each fires for ordinary container work too, and an
-- ungated hook would bury the one call that matters.
local inHatchWindow = false
local hatchWindowLabel = "none"

local function describeContainer(container)
    if not alive(container) then return "not alive" end
    local parts = {}
    local full = nil
    pcall(function() full = container:GetFullName() end)
    parts[#parts + 1] = (full ~= nil and tostring(full) or "unnameable")

    -- FPalContainerId is the container's identity, and the base class exposes both the
    -- property and a getter. Try each: one working is enough, and which one worked matters.
    local okId, idValue = readProperty(container, "ID")
    if okId and idValue ~= nil then parts[#parts + 1] = "ID=" .. describeValue(idValue) end
    local viaGetter = nil
    local okGetter = pcall(function() viaGetter = container:GetId() end)
    if okGetter and viaGetter ~= nil then parts[#parts + 1] = "GetId=" .. describeValue(viaGetter) end

    local slotCount = nil
    pcall(function() slotCount = container:Num() end)
    parts[#parts + 1] = "Num=" .. tostring(slotCount)
    return table.concat(parts, " ")
end

-- Which container belongs to which player, so a container id in the hook above can be
-- attributed. Walks each known player state for container-shaped properties.
local function dumpPlayerContainers()
    local players = nil
    pcall(function() players = _ModActor.Players end)
    if players == nil then trace("cont: Players unreadable") return end
    pcall(function()
        players:ForEach(function(key, value)
            local uid = guidText(unwrap(key))
            local state = unwrap(value)
            if not alive(state) then trace("cont: " .. tostring(uid) .. " state not alive") return end
            local okClass, cls = pcall(function() return state:GetClass() end)
            if not okClass or cls == nil then return end
            local current = cls
            local depth = 0
            while current ~= nil and depth < 6 do
                pcall(function()
                    current:ForEachProperty(function(prop)
                        local name = nil
                        pcall(function() name = prop:GetFName():ToString() end)
                        if name == nil then return end
                        if string.find(name, "Container") or string.find(name, "Storage")
                           or string.find(name, "Party") or string.find(name, "Pal") then
                            local okRead, propValue = readProperty(state, name)
                            if okRead and propValue ~= nil then
                                local target = unwrap(propValue)
                                local full = nil
                                pcall(function() full = target:GetFullName() end)
                                if full ~= nil then
                                    trace("cont:" .. tostring(uid) .. " " .. name .. " = " .. tostring(full))
                                end
                            end
                        end
                    end)
                end)
                local okSuper, super = pcall(function() return current:GetSuperStruct() end)
                if not okSuper or super == nil or not alive(super) then break end
                current = super
                depth = depth + 1
            end
        end)
    end)
end

local function RegisterContainerHook()
    -- A registration that throws and a hook that never fires look identical in the log, so
    -- each registration reports its own result before any hatch is attempted.
    local okContainer = pcall(function()
        RegisterHook("/Script/Pal.PalCharacterContainerManager:TryGetContainer",
          guarded("container.pre", function(self, containerId, outContainer)
            if not inHatchWindow then return end
            local idText = "unread"
            local okId = pcall(function() idText = describeValue(containerId:get()) end)
            trace("cont:TryGetContainer during " .. hatchWindowLabel
                  .. " id_ok=" .. tostring(okId) .. " id=" .. tostring(idText))
          end,
          function(self, containerId, outContainer)
            if not inHatchWindow then return end
            local resolved = nil
            local okOut = pcall(function() resolved = outContainer:get() end)
            trace("cont:TryGetContainer resolved out_ok=" .. tostring(okOut)
                  .. " -> " .. (okOut and describeContainer(resolved) or "unreadable"))
          end))
    end)
    trace("cont: TryGetContainer hook registered=" .. tostring(okContainer))

    -- The blueprint half, by full object path rather than a /Script/ class path: this is a
    -- Blueprint-generated UFunction, so it lives under /Game and has no native class name.
    local okGive = pcall(function()
        RegisterHook("/Game/Mods/AutoHatch/ModActor.ModActor_C:GivePlayerID",
          guarded("give.pre", function(self, ...)
            local args = table.pack(...)
            local parts = {}
            for index = 1, args.n do
                local value = "unread"
                local okArg = pcall(function() value = describeValue(unwrap(args[index])) end)
                parts[#parts + 1] = index .. "=" .. tostring(value) .. "(ok=" .. tostring(okArg) .. ")"
            end
            trace("give:GivePlayerID during " .. hatchWindowLabel .. " args " .. table.concat(parts, " "))
          end))
    end)
    trace("cont: GivePlayerID hook registered=" .. tostring(okGive))

    -- The rest of the blueprint's hatch path, hooked rather than called. Every earlier
    -- attempt INVOKED these with arguments chosen here, which is how GetLoggedInPlayerUId
    -- came to be judged on a zero that a mismatched call had produced. Hooking reports what
    -- the blueprint itself passes and what it hands back, on the real hatch.
    --
    -- All of them are observations. None mutates state, so they compose: one restart
    -- answers every question at once instead of one question per restart. Interventions
    -- still do not compose and still go one at a time, which is why APPLY_OWNER_FIX is off.
    for _, name in ipairs({ "GetEggOwnerUIdSingle", "GetEggOwnerUIdMulti", "GetLoggedInPlayerUId",
                            "FindBreedFarmBelongTo", "AutoPickUpEgg", "EggCleanUp",
                            "OnUpdateHatchedCharacterDelegate_Event", "PickUpAllEggs",
                            "AutoHatch", "ExecuteUbergraph_ModActor" }) do
        local okHook = pcall(function()
            RegisterHook("/Game/Mods/AutoHatch/ModActor.ModActor_C:" .. name,
              guarded("bp." .. name, function(self, ...)
                if not inHatchWindow then return end
                local args = table.pack(...)
                local parts = {}
                for index = 1, args.n do
                    local value = "unread"
                    local okArg = pcall(function() value = describeValue(unwrap(args[index])) end)
                    parts[#parts + 1] = index .. "=" .. tostring(value) .. "(ok=" .. tostring(okArg) .. ")"
                end
                trace("bp:" .. name .. " pre src=" .. (ownCallDepth > 0 and "probe" or "BLUEPRINT") .. " " .. hatchWindowLabel .. " " .. table.concat(parts, " "))
              end,
              function(self, ...)
                if not inHatchWindow then return end
                local args = table.pack(...)
                local parts = {}
                for index = 1, args.n do
                    local value = "unread"
                    local okArg = pcall(function() value = describeValue(unwrap(args[index])) end)
                    parts[#parts + 1] = index .. "=" .. tostring(value) .. "(ok=" .. tostring(okArg) .. ")"
                end
                trace("bp:" .. name .. " post src=" .. (ownCallDepth > 0 and "probe" or "BLUEPRINT") .. " " .. hatchWindowLabel .. " " .. table.concat(parts, " "))
              end))
        end)
        -- Registration is reported per function. A blueprint function that cannot be hooked
        -- and one that is never called produce the same silence in the log otherwise.
        trace("cont: bp hook " .. name .. " registered=" .. tostring(okHook))
    end
end

local function probeBlueprintLatches(phase)
    if not alive(_ModActor) then return end
    local parts = {}
    for _, name in ipairs({ "UsedMultiHatch", "UseAutoHatch", "DedicatedServer", "KeepSprint",
                            "Can Press Hotkey", "ShouldEnableInteract", "WidgetOnScreen" }) do
        local okRead, value = readProperty(_ModActor, name)
        parts[#parts + 1] = name .. "=" .. (okRead and tostring(value) or "READFAIL")
    end
    local byteLen = nil
    pcall(function() byteLen = #_ModActor.ByteArray end)
    parts[#parts + 1] = "ByteArray=" .. tostring(byteLen)
    trace("latch:" .. phase .. " " .. table.concat(parts, " "))

    -- Only in the pre phase, and only when armed: clearing a one-shot the blueprint owns is
    -- a live mutation, so it stays behind a flag and reports whether the write stuck.
    if phase == "pre" and RESET_USED_MULTI_HATCH then
        local okWrite = pcall(function() _ModActor.UsedMultiHatch = false end)
        local after = nil
        pcall(function() after = _ModActor.UsedMultiHatch end)
        trace("latch:reset UsedMultiHatch write=" .. tostring(okWrite) .. " now=" .. tostring(after))
    end
end

-- ObtainHatchedCharacter_ServerInternal takes an int32 RequestPlayerId, not a UId, so the
-- correct UId the mod resolves has to survive a round trip through a per-connection integer
-- before the game can find a container for it. This walks the GameState's PlayerArray and
-- prints, for every PlayerState the server currently holds, its PlayerId alongside its UId
-- and name. A PlayerId that maps to the wrong UId, or two states sharing one PlayerId, puts
-- the fault in that lookup rather than anywhere in the mod.
local function probePlayerArray(phase)
    local gameState = nil
    local okState = pcall(function() gameState = _ModActor["Game State"] end)
    if not okState or gameState == nil then
        okState = pcall(function() gameState = _ModActor:GetGameStateFromLua() end)
    end
    if gameState == nil then trace("parr:" .. phase .. " GameState unreadable read_ok=" .. tostring(okState)) return end

    local okRead, array = readProperty(gameState, "PlayerArray")
    if not okRead or array == nil then
        trace("parr:" .. phase .. " PlayerArray read_ok=" .. tostring(okRead) .. " value=nil")
        return
    end

    -- Length and iteration are reported apart from the entries. An array that could not be
    -- counted and an array that is genuinely empty are different findings, and collapsing
    -- them is how three earlier probes reported an absent value as a zero.
    local count = nil
    local okCount = pcall(function() count = #array end)
    trace("parr:" .. phase .. " count_ok=" .. tostring(okCount) .. " count=" .. tostring(count))
    if not okCount or count == nil then return end

    local seen = {}
    for index = 1, count do
        local entry = nil
        local okEntry = pcall(function() entry = array[index] end)
        if not okEntry or entry == nil then
            trace("parr:" .. phase .. " [" .. index .. "] entry_ok=false")
        else
            local state = unwrap(entry)
            local okId, playerId = readProperty(state, "PlayerId")
            local okName, playerName = readProperty(state, "PlayerNamePrivate")
            local uid = "unread"
            pcall(function() uid = guidText(state.PlayerUId) end)
            local full = "unnameable"
            pcall(function() full = state:GetFullName() end)
            local idText = tostring(okId and playerId or "unread")
            local duplicate = seen[idText] and " DUPLICATE_OF_" .. tostring(seen[idText]) or ""
            seen[idText] = index
            trace("parr:" .. phase .. " [" .. index .. "] PlayerId=" .. idText
                  .. " uid=" .. tostring(uid)
                  .. " name=" .. tostring(okName and playerName or "unread")
                  .. duplicate .. " obj=" .. tostring(full))
        end
    end
end

local function probeModActorOwnership()
    if not alive(_ModActor) then trace("own: no ModActor") return end
    for _, name in ipairs({ "GetOwner", "GetNetOwningPlayer", "GetInstigator", "GetInstigatorController" }) do
        local value = nil
        local okCall = pcall(function() value = _ModActor[name](_ModActor) end)
        if not okCall then trace("own:" .. name .. " CALL FAILED")
        elseif value == nil then trace("own:" .. name .. " = nil")
        else
            local inner = value
            pcall(function() inner = value:get() end)
            local full = nil
            pcall(function() full = inner:GetFullName() end)
            if full ~= nil then trace("own:" .. name .. " = " .. tostring(full))
            else trace("own:" .. name .. " UNNAMEABLE (" .. describeValue(value) .. ")") end
        end
    end

    -- Whose controller is it? A PlayerController carries the PlayerState that names the
    -- player, which is the identity this whole test is after.
    local owner = nil
    pcall(function() owner = _ModActor:GetOwner() end)
    if owner ~= nil then
        local inner = owner
        pcall(function() inner = owner:get() end)
        for _, field in ipairs({ "PlayerState", "Pawn" }) do
            local okRead, value = readProperty(inner, field)
            if okRead and value ~= nil then
                local target = value
                pcall(function() target = value:get() end)
                for _, idField in ipairs({ "PlayerId", "PlayerUId", "PlayerNamePrivate" }) do
                    local okId, idValue = readProperty(target, idField)
                    if okId and idValue ~= nil then
                        local rawId = idValue
                        pcall(function() rawId = idValue:get() end)
                        trace("own:Owner." .. field .. "." .. idField .. " = " .. describeValue(rawId))
                    end
                end
            end
        end

        -- Identity by comparison rather than by name: match the owner's player state
        -- against the Players map, whose keys are the UIds we already trust.
        local players = nil
        pcall(function() players = _ModActor.Players end)
        local ownerState = nil
        pcall(function() ownerState = inner:GetPropertyValue("PlayerState") end)
        if players ~= nil and ownerState ~= nil then
            local ownerId = nil
            pcall(function() ownerId = ownerState:get():GetPropertyValue("PlayerId") end)
            trace("own:Owner PlayerId for matching = " .. tostring(ownerId))
            pcall(function()
                players:ForEach(function(key, value)
                    local uid = guidText(unwrap(key))
                    local state = unwrap(value)
                    local stateId = nil
                    pcall(function() stateId = state:GetPropertyValue("PlayerId") end)
                    trace("own:match " .. tostring(uid) .. " PlayerId=" .. tostring(stateId) ..
                          (stateId ~= nil and ownerId ~= nil and stateId == ownerId and "  <== OWNS THE MODACTOR" or ""))
                end)
            end)
        end
    end
    for _, name in ipairs({ "Owner", "Instigator" }) do
        local okRead, value = readProperty(_ModActor, name)
        trace("own:prop " .. name .. " read=" .. tostring(okRead) .. " " .. describeValue(value))
    end
    local hasAuthority = nil
    pcall(function() hasAuthority = _ModActor:HasAuthority() end)
    trace("own:HasAuthority = " .. tostring(hasAuthority))
end

-- Every read reports whether it SUCCEEDED, separately from what it returned. A pcall whose
-- ok flag is discarded turns "I could not read this" into "this is empty", which is the
-- failure that has cost this investigation three restarts.
local function traceRead(label, object, name)
    local okRead, value = readProperty(object, name)
    if not okRead then trace(label .. " " .. name .. " READ FAILED") return nil end
    if value == nil then trace(label .. " " .. name .. " absent-or-nil") return nil end
    trace(label .. " " .. name .. " = " .. describeValue(value))
    return value
end

-- GetEggOwnerUIdSingle takes the single model and GetEggOwnerUIdMulti the multi one. Calling
-- both on one object guarantees a type mismatch, and UE4SS answers a mismatched UObject arg
-- with a null, so the resulting zero GUID says nothing about ownership.
local function probeResolvers(egg)
    if not alive(egg) or not alive(_ModActor) then return end
    local isMulti, isSingle = nil, nil
    pcall(function() isMulti = egg:IsA("/Script/Pal.PalMapObjectMultiHatchingEggModel") end)
    pcall(function() isSingle = egg:IsA("/Script/Pal.PalMapObjectHatchingEggModel") end)
    trace("res:isMulti=" .. tostring(isMulti) .. " isSingle=" .. tostring(isSingle))

    if isMulti then
        -- Slot matters: index 0 is a guess, and a wrong slot returns a default GUID that
        -- looks identical to "no owner".
        for slot = 0, 3 do
            local out = callBlueprint(_ModActor, "GetEggOwnerUIdMulti", egg, slot)
            if out ~= nil then
                for key, value in pairs(out) do
                    trace("res:multi[" .. slot .. "] " .. tostring(key) .. "=" .. describeValue(value))
                end
            end
        end
    elseif isSingle then
        callBlueprint(_ModActor, "GetEggOwnerUIdSingle", egg)
    else
        trace("res: egg is NEITHER single nor multi by IsA; resolvers not called")
    end

    -- Hypothesis (a) was never actually tested: the old probe fed this a zero GUID taken
    -- from a mismatched call. Feed it the owner the incubator map genuinely resolves.
    local trueOwner = ownerForEgg(egg)
    if trueOwner ~= nil then
        trace("res:feeding TRUE owner " .. tostring(guidText(trueOwner)) .. " into GetLoggedInPlayerUId")
        callBlueprint(_ModActor, "GetLoggedInPlayerUId", trueOwner)
    else
        trace("res: ownerForEgg found nothing, GetLoggedInPlayerUId still untested")
    end
end

local function probeRouting(egg)
    if not alive(_ModActor) then trace("route: no ModActor") return end

    for _, name in ipairs({ "PlayerEggIncubators", "PlayerBreedFarms",
                            "WorkProgress_To_PlayerUId__Map", "Players", "EggToPlayerMap",
                            "PlayerSettings", "WorkBase_To_PlayerUId_Map",
                            "WorkProgress_To_Incubator_Map" }) do
        dumpMap(_ModActor, name, 12)
    end
    local useAuto = nil
    pcall(function() useAuto = _ModActor.UseAutoHatch end)
    trace("route:UseAutoHatch = " .. tostring(useAuto))
    dumpPlayerStateIds()

    local byteLen = nil
    pcall(function() byteLen = #_ModActor.ByteArray end)
    trace("route:ByteArray len=" .. tostring(byteLen))

    if not alive(egg) then trace("route: egg not alive") return end
    local single = callBlueprint(_ModActor, "GetEggOwnerUIdSingle", egg)
    local multi = callBlueprint(_ModActor, "GetEggOwnerUIdMulti", egg, 0)

    -- Feed whatever a resolver produced back through the suspect step. A true owner in and
    -- a different UId out is the bug, caught in one line.
    local resolved = nil
    for _, out in ipairs({ single or {}, multi or {} }) do
        for _, value in pairs(out) do
            if resolved == nil then resolved = value end
        end
    end
    if resolved ~= nil then
        trace("route:resolved owner = " .. describeValue(resolved))
        callBlueprint(_ModActor, "GetLoggedInPlayerUId", resolved)
    else
        trace("route: no owner resolved, skipping GetLoggedInPlayerUId")
    end
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

    -- Registered with BOTH callbacks so the pre/post question is settled by observation
    -- rather than by argument: the panel split on whether a single callback is the pre or
    -- the post hook, and it decides whether "the maps were empty" means empty at the
    -- decision or empty after it.
    local function observeHatch(phase, self, playerId)
        trace("hatch:" .. phase .. " #" .. tostring(hatchCount))
        local okRecipient, rawRecipient = pcall(function() return playerId:get() end)
        trace("hatch:" .. phase .. ":recipient " .. (okRecipient and describeId(rawRecipient) or "unreadable"))

        local egg = self:get()
        if not alive(egg) then trace("hatch:" .. phase .. ":egg not alive") return end
        -- Class on EVERY hatch, not once per server lifetime: the old counter was spent on
        -- the first player's hatches, so the failing player's class was never recorded.
        trace("hatch:" .. phase .. ":egg " .. egg:GetFullName())

        for _, name in ipairs({ "PlayerEggIncubators", "PlayerBreedFarms",
                                "WorkProgress_To_PlayerUId__Map", "EggToPlayerMap" }) do
            dumpMap(_ModActor, name, 8)
        end
        probeBlueprintLatches(phase)
        probePlayerArray(phase)
        probeResolvers(egg)
        if phase == "pre" then
            probeModActorOwnership()
            dumpObject("egg." .. phase, egg, PROBE_EGG)
            traceRead("stamp:", egg, "HatchedCharacterSaveParameter")
        end
    end

    RegisterContainerHook()

    RegisterHook("/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal",
      guarded("hatch.pre", function(self, playerId, archive)
        hatchCount = hatchCount + 1
        local okRecipient, rawRecipient = pcall(function() return playerId:get() end)
        hatchWindowLabel = "hatch#" .. tostring(hatchCount) .. " recipient=" ..
                           (okRecipient and tostring(rawRecipient) or "?")
        inHatchWindow = true
        observeHatch("pre", self, playerId)
        dumpPlayerContainers()
        if APPLY_OWNER_FIX then applyOwnerFix(self:get()) end

        if sentBytes and not SEND_BYTES_EVERY_HATCH then trace("hatch:bytes already sent") return end
        if not alive(_ModActor) then trace("hatch:no ModActor") return end
        local ar = archive:get()
        if ar == nil then trace("hatch:no archive") return end
        local bytes = ar.Bytes
        if bytes == nil then trace("hatch:no bytes") return end

        -- Nothing in the mod empties ByteArray between hatches, which is why per-hatch
        -- sends compounded last time. Clear it first, and report which method worked so a
        -- silent no-op cannot masquerade as a clear.
        local beforeLen = nil
        pcall(function() beforeLen = #_ModActor.ByteArray end)
        local cleared = pcall(function() _ModActor.ByteArray:Empty() end)
        if not cleared then cleared = pcall(function() _ModActor.ByteArray:Clear() end) end
        if not cleared then cleared = pcall(function() _ModActor.ByteArray = {} end) end
        local afterLen = nil
        pcall(function() afterLen = #_ModActor.ByteArray end)
        trace("hatch:bytearray " .. tostring(beforeLen) .. " -> " .. tostring(afterLen) ..
              " cleared=" .. tostring(cleared))

        if #bytes > BYTE_CEILING then
            trace("hatch:REFUSING to send " .. tostring(#bytes) .. " bytes, over ceiling " ..
                  tostring(BYTE_CEILING) .. ". The accumulator is growing again.")
            return
        end

        for byteIndex = 1, #bytes do
            _ModActor:GetBytes(bytes[byteIndex])
        end
        sentBytes = true
        trace("hatch:sent " .. tostring(#bytes) .. " bytes")
      end),
      guarded("hatch.post", function(self, playerId, archive)
        observeHatch("post", self, playerId)
        inHatchWindow = false
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
