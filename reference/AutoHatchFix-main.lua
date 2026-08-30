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
-- WHAT NOTHING WE WRITE CAN DO: deliver the hatch itself. Measured twice, two different
-- callers, same result. From Lua directly: `ObtainHatchedCharacter_ServerInternal`,
-- `RequestObtainSingleHatchedCharacter` and `RequestObtainAllHatchedCharacter` each returned
-- call_ok=true and consumed nothing on ten COMPLETED eggs addressed to the tester's own live
-- PlayerId. From a purpose-built companion Blueprint: the same function, reached with
-- processevent=true and reached_obtain=true and the correct recipient, consumed nothing on the
-- same ten eggs. The caller was never the variable. That function's payload is its Archive
-- parameter, which the original mod assembles by streaming bytes through GetBytes(uint8) into
-- ByteArray, and a default-constructed one carries nothing to obtain.
--
-- SO DELIVERY IS NOT REIMPLEMENTED, IT IS DRIVEN. `AutoHatch(FGuid PlayerUId)` on the ORIGINAL
-- mod's ModActor is that mod's entire working delivery path and takes the recipient as a
-- parameter. The original hatches reliably; its only defect is CHOOSING that recipient, which
-- is exactly the step this file replaces. Its pak is enabled and its own Lua is not (no
-- enabled.txt), so its shared-context sweep never runs and the blueprint is machinery we drive;
-- UseAutoHatch is forced false before every call as a second guard.
-- callOriginalAutoHatch() below is the ONLY place that delivers.
--
-- The companion Blueprint and callDoHatch() are retained but no longer on the delivery path.
-- They are what PROVED the above: without them, "Lua cannot dispatch Blueprint bytecode" and
-- "the game refuses an injected obtain" were indistinguishable.

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

-- A PlayerState exists briefly during a join before PlayerUId is populated, and reads as all
-- zeros. Observed in the delivery ledger: one join produced TWO rows, an all-zeros one and then
-- the real UId fourteen seconds later. In a two-player ledger that phantom row is exactly what
-- someone would misread as a second player, so it is rejected everywhere a UId is keyed or
-- recorded rather than filtered at the point it happened to be noticed.
local function isRealUid(uid)
    if uid == nil or uid == "" then return false end
    return string.match(uid, "^0+$") == nil
end

local function readProperty(object, name)
    if not alive(object) then return false, nil end
    local ok, value = pcall(function() return object[name] end)
    if not ok then return false, nil end
    return true, value
end

---------------------------------------------------------------------------------------------
-- ARCHIVE CAPTURE. This is the mechanism the whole mod turns on, and it is not a normal API.
--
-- ObtainHatchedCharacter_ServerInternal(RequestPlayerId, Archive) cannot be called into
-- usefully from outside: measured no-ops from Lua directly, from a purpose-built Blueprint that
-- provably ran its graph, and from the original mod's own AutoHatch. All three failed for the
-- same reason. The Archive is the request, and a default-constructed one carries nothing.
--
-- The original mod never builds an Archive either. It hooks this same function, waits for a
-- GENUINE player-initiated hatch, copies that real call's Archive bytes out, and replays them
-- forever (reference/AutoHatch-main.lua, the hatch.pre hook). Auto-hatching is a replay of a
-- recording, not a call.
--
-- That is also the original's bug, exactly. Its `sentBytes` latches after the first capture, so
-- one server lifetime holds ONE recording, taken from whoever hatched first, and every later
-- delivery replays that person's request. Which is the reported symptom verbatim: the first
-- player to hatch after a restart receives everyone's Pals.
--
-- So: capture PER PLAYER, and replay a given owner's own recording for that owner's eggs. Each
-- player teaches the mod once by hatching a single egg by hand; everything of theirs after that
-- is automatic, addressed by their own captured request.
---------------------------------------------------------------------------------------------

-- PlayerUId (hex) -> array of archive bytes copied out of that player's own real hatch.
local archiveBytesByUid = {}
-- PlayerId (int, per-connection) -> PlayerUId (hex, stable). Rebuilt every sweep, because
-- PlayerId is assigned per connection and is meaningless across a restart.
local uidByPlayerId = {}
-- PlayerUId (hex) -> that player's raw FGuid, kept so an archive can be synthesized for them and
-- checked against the real one. Refreshed every sweep from the live PlayerState.
local capturedGuidByUid = {}
-- Set only while WE are replaying. The hook fires for any caller including our own replay, and
-- capturing our own replay is how the 2026-08-29 "fresh bytes every hatch" test silently tested
-- nothing: it re-recorded its own recording and could not have shown a difference either way.
local inOurDelivery = false
-- The hex of the last archive WE loaded into the blueprint. `inOurDelivery` alone cannot guard
-- the capture, because AutoHatch returns before the delivery runs, so the hook fires for our own
-- replay with the flag already cleared. Comparing the bytes is reliable where the flag is not:
-- an archive identical to the one we just supplied IS our replay coming back around.
--
-- This is not hypothetical. After a restart the mod synthesizes and delivers before any human
-- hatches, so the FIRST capture was our own replay, and during the misaddress test that recorded
-- another player's GUID as the tester's archive.
local lastLoadedArchiveHex = nil

-- THE REDIRECT. Rewrite ObtainHatchedCharacter_ServerInternal's RequestPlayerId to the hatchery
-- owner, so a genuine hatch delivers to whoever built the incubator rather than whoever clicked.
-- OFF, and the reason is the most useful thing measured tonight. Rewriting RequestPlayerId WORKS
-- mechanically (readback confirmed took=true) and changes NOTHING about who receives the Pal: a
-- delivery rewritten to a disconnected player 257 still landed in player 256's Palbox.
--
-- What did track the outcome was the ARCHIVE. Two runs settle it:
--   archive=absent player,  RequestPlayerId=connected player -> nothing delivered
--   archive=connected player, RequestPlayerId=bogus 257      -> delivered to that player
-- The archive's GUID is the recipient. RequestPlayerId is not consulted for routing.
--
-- Which is also the original mod's bug in one line: it replays ONE captured archive for the whole
-- server, so every Pal carries whichever player hatched first.
local REDIRECT_TO_OWNER = false

-- FORCED REDIRECT (test only). Set to a PlayerId to rewrite EVERY delivery to it, regardless of
-- who owns the incubator. Exists because the owner-based redirect above has never actually run:
-- with one player connected, the owner and the clicker are the same person, so there is nothing
-- to rewrite, and `:set()` on a hook argument remains completely untested on this UE4SS fork.
--
-- Two things fall out of one run against the tester's OWN eggs:
--   took=true/false  -> whether :set() works at all here. If false, this whole approach is dead
--                       and no amount of two-player testing would have revealed it.
--   Pals stop arriving -> the game HONOURS RequestPlayerId, so redirecting by owner will work.
--   Pals still arrive  -> the parameter is decoration and the recipient is decided elsewhere.
--
-- 257 is deliberately a player who is not connected (the second player held 256/257 in an earlier
-- session), so a successful redirect should deliver to nobody rather than to someone real.
-- Set to nil for normal operation.
local FORCE_REDIRECT_PLAYER_ID = nil

-- Snapshots the hook can read. The obtain hook fires from the game's own call stack, outside any
-- sweep, so it cannot rebuild these itself; the sweep refreshes them every cycle.
--   model InstanceId (hex) -> owner PlayerUId (hex)
local lastOwnerByModelId = {}
--   owner PlayerUId (hex) -> that player's current PlayerId, for connected players only
local lastPlayerIdByUid = {}
-- Players already journaled as online this server run, so a join is recorded once rather than
-- every five seconds.
local journaledOnline = {}

-- The 2026-08-28 runaway: nothing emptied ByteArray between sends, so the archive doubled every
-- hatch (6.8 MB, 13.7 MB, 27.5 MB) until the game thread stopped answering the REST API with no
-- crash dump. Refuse anything absurd rather than feed it.
local ARCHIVE_BYTE_CEILING = 100000

-- ROUTING TEST MODE. Answers "what actually decides the recipient" with ONE player, by making
-- the two candidate sources disagree on purpose: replay one player's recording while naming a
-- DIFFERENT owner in the AutoHatch argument. Normally both name the same person and a successful
-- hatch proves nothing about which one did the work.
--
-- It also lets delivery proceed for an OFFLINE owner, which normal operation refuses. That is the
-- point: the tester puts their own eggs into another player's hatchery, so the incubator's owner
-- is somebody not connected. Turn this OFF for ordinary play; an offline owner has no addressable
-- recipient and holding their eggs is the correct behaviour.
-- OFF. It answered what it was for: with three offline owners named by correctly synthesized
-- archives and call_ok=true every cycle, nothing was ever consumed, which establishes that
-- delivery requires a CONNECTED recipient and that the offline gate is separate from routing.
-- Leaving it on costs a pointless AutoHatch per offline owner per cycle, and would dump a
-- returning player's whole backlog through a test path the moment they reconnect.
--
-- Turning it off does NOT affect the two-player test: it only ever relaxed the offline gate, and
-- an owner who is online takes the normal path regardless.
local ROUTING_TEST = false

-- MISADDRESS TEST. The two-player test cannot be simulated, because delivery needs a CONNECTED
-- recipient and an absent player cannot be faked. This asks the same question from the other
-- side, with one player.
--
-- Set this to another player's UId (hex, as printed in poll.detail's owner= field). Every
-- delivery then names THAT player in both the synthesized archive and the AutoHatch argument,
-- regardless of who actually owns the incubator. Run it against the ONE configuration already
-- known to deliver: the tester's own completed eggs, in their own hatchery, while connected.
--
--   nothing hatches  => the address is HONOURED. Delivery went looking for the named (absent)
--                       player and stopped. That is what per-owner addressing depends on.
--   Pals still arrive => the address is IGNORED and the recipient comes from somewhere else
--                       (the connected player, or a shared context). Per-owner archives would
--                       then fix nothing, and the two-player test would fail.
--
-- Set to nil for normal operation. This NEVER touches another player's eggs: it changes who a
-- delivery is addressed to, not which incubators are swept.
-- Disarmed. It answered, and the answer is two-part:
--
--   1. The FGuid we pass to AutoHatch does NOT choose the recipient. We named an ABSENT player in
--      both the archive and the argument, and the call arrived at
--      ObtainHatchedCharacter_ServerInternal with RequestPlayerId=256, the CONNECTED player. The
--      blueprint resolves the recipient itself, from a logged-in player, ignoring our address.
--   2. The archive is still checked. With the archive naming the absent player and
--      RequestPlayerId resolved to the connected one, NOTHING was consumed across many cycles;
--      when both named the same connected player, eggs hatched. Delivery appears to require the
--      two to AGREE.
--
-- Consequence: per-owner archives cannot by themselves route a Pal to the right person, because
-- RequestPlayerId is not ours to set. They do act as a FILTER, turning a would-be misroute into a
-- no-op rather than delivering someone else's Pal to the wrong player, which is strictly safer
-- than the original's behaviour but is not the fix.
local MISADDRESS_TEST_UID = nil

---------------------------------------------------------------------------------------------
-- ARCHIVE SYNTHESIS. The captured 21 bytes decode completely:
--
--   FF FF FF FF | 01 | E6 90 43 08 | 00 x12
--   \--------/    \/   \---------------------/
--    -1, likely   flag  the owner's FGuid, LITTLE-ENDIAN
--    "all slots"
--
-- Read against PlayerUId 084390E6000000000000000000000000: bytes 6..9 are E6 90 43 08, which is
-- 0x084390E6 with the byte order reversed, and B/C/D follow as twelve zeros. So the request is
-- header plus recipient, and the recipient is the only part that varies between players.
--
-- That means a recording is not precious. We can BUILD one for any owner, which removes the
-- hand-hatch step entirely and makes an offline owner addressable the moment they reconnect.
--
-- NOTE for anyone reading the earlier log: the `owner_uid_present_in_bytes` line reported false
-- on this exact match, because it compared the big-endian hex TEXT of the UId against a
-- little-endian byte dump. The check was wrong, not the data.
---------------------------------------------------------------------------------------------

local ARCHIVE_HEADER = { 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }

local function synthesizeArchiveBytes(guid)
    if guid == nil then return nil end
    local bytes = {}
    for index = 1, #ARCHIVE_HEADER do bytes[index] = ARCHIVE_HEADER[index] end
    local function appendLittleEndian(word)
        if word == nil then return false end
        word = word & 0xFFFFFFFF
        bytes[#bytes + 1] = word & 0xFF
        bytes[#bytes + 1] = (word >> 8) & 0xFF
        bytes[#bytes + 1] = (word >> 16) & 0xFF
        bytes[#bytes + 1] = (word >> 24) & 0xFF
        return true
    end
    local ok = true
    for _, field in ipairs({ "A", "B", "C", "D" }) do
        local word = nil
        pcall(function() word = guid[field] end)
        if not appendLittleEndian(word) then ok = false end
    end
    if not ok or #bytes ~= 21 then return nil end
    return bytes
end

local function bytesToHex(bytes)
    if bytes == nil then return "nil" end
    local parts = {}
    for index = 1, #bytes do parts[index] = string.format("%02X", bytes[index]) end
    return table.concat(parts)
end

-- Durable delivery ledger. UE4SS.log is TRUNCATED on every server restart, and the restart is the
-- most common thing that happens between a delivery and anyone looking at it. The open question
-- (does a second player's egg reach that second player) will most likely be answered while nobody
-- is watching, hours after this was written, by that player simply logging in. Without a record
-- that outlives the restart, that answer is produced and destroyed silently.
--
-- D: is the durable volume (the world lives there and survives instance replacement); C: does not.
-- Absolute path because Lua resolves relative paths against C:\PalServer, not this script's folder.
local DELIVERY_LOG = "D:\\PalServer\\autohatchfix-deliveries.log"

local function recordDelivery(line)
    -- Best effort by design: a failure to journal must never interfere with a delivery. But say so
    -- in UE4SS.log rather than failing silently, or a missing ledger reads as "nothing happened".
    local file = io.open(DELIVERY_LOG, "a")
    if file == nil then
        trace("ledger: FAILED to open " .. DELIVERY_LOG .. " for append")
        return
    end
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ ") .. line .. "\n")
    file:close()
end

local function captureArchiveFor(playerIdValue, archive)
    if inOurDelivery then return end -- our own replay; recording it would be circular
    local uid = uidByPlayerId[playerIdValue]
    -- isRealUid, not a nil check: an all-zeros UId from a half-initialised PlayerState would file
    -- a real archive under a player who does not exist.
    if not isRealUid(uid) then return end
    -- FIRST CAPTURE WINS. The inOurDelivery flag alone is not enough: AutoHatch returns before
    -- the delivery actually runs, so the hook fires for our own replay with the flag already
    -- cleared, and every log line reads ours=false. Re-recording a replay is how the 2026-08-29
    -- "fresh bytes every hatch" experiment tested nothing. Worse, while the misroute is unfixed a
    -- replay can deliver to the WRONG player, and re-capturing there would file one player's
    -- request under another's name and quietly corrupt the very test that checks routing.
    if archiveBytesByUid[uid] ~= nil then return end
    local liveArchive = nil
    pcall(function() liveArchive = archive:get() end)
    if liveArchive == nil then return end
    local bytes = nil
    pcall(function() bytes = liveArchive.Bytes end)
    if bytes == nil then return end
    local count = nil
    if not pcall(function() count = #bytes end) or type(count) ~= "number" or count == 0 then return end
    if count > ARCHIVE_BYTE_CEILING then
        trace("capture: REFUSING " .. tostring(count) .. " bytes for " .. uid .. ", over ceiling")
        return
    end
    -- Copy the VALUES out. The Archive is a live argument on the game's stack and is gone the
    -- moment this hook returns, so keeping a reference to it would dangle.
    local copy = {}
    for byteIndex = 1, count do
        local value = nil
        pcall(function() value = bytes[byteIndex] end)
        if value == nil then return end -- a partial recording is worse than none
        copy[byteIndex] = value
    end
    -- Reject our own replay coming back through the hook. Byte-identical to what we just loaded
    -- means this is not a player's genuine request, and recording it would file whatever we sent
    -- (possibly another player's GUID) as this player's archive.
    local capturedHex = bytesToHex(copy)
    if lastLoadedArchiveHex ~= nil and capturedHex == lastLoadedArchiveHex then
        trace("capture: ignoring our own replay for " .. uid .. " (bytes match what we loaded)")
        return
    end
    archiveBytesByUid[uid] = copy
    -- Dump the raw bytes. With one player online, "the right person" and "the only person" are
    -- the same observation, so a successful hatch cannot tell whether the recipient came from the
    -- FGuid passed to AutoHatch, from this recording, or from the blueprint's own state. The
    -- contents settle it without a second player: an FGuid is 16 bytes, so if this owner's UId
    -- appears here, the recording carries the identity.
    local hex = bytesToHex(copy)
    trace("capture: stored " .. tostring(count) .. " archive byte(s) for " .. uid ..
          " (first capture; their eggs can auto-hatch now)")
    trace("capture: bytes=" .. hex)

    -- THE CONTROL for synthesis. Build what we THINK this player's archive should be and compare
    -- it byte for byte against the real one the game just handed us. A match proves the layout is
    -- understood; a mismatch prints both so the difference is visible rather than assumed. This is
    -- the check that has to be green before any synthesized archive is trusted for delivery, and
    -- unlike the previous owner_uid_present test it compares like with like.
    local synthesized = synthesizeArchiveBytes(capturedGuidByUid[uid])
    local synthesizedHex = bytesToHex(synthesized)
    trace("capture: synthesized=" .. synthesizedHex ..
          " matches_real=" .. tostring(synthesizedHex == hex))
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

-- Rebuilt each sweep alongside ownerByModelId; holds the UPalMapObjectModel so BuildPlayerUId can
-- be re-read as a real FGuid when calling the original mod's AutoHatch.
local ownerObjectByModelId = {}
-- One map object per OWNER UId, so a real FGuid can be read for any owner in the world, online or
-- not. The misaddress test needs the target's FGuid and Lua cannot construct an FGuid from a hex
-- string; borrowing it off a structure that player built is the way to get a genuine one.
local sampleObjectByOwnerUid = {}

local function buildOwnerByModelId()
    local ownerByModelId = {}
    ownerObjectByModelId = {}
    sampleObjectByOwnerUid = {}
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
            -- Keep the map object itself as well. The original mod's AutoHatch(FGuid) needs a real
            -- FGuid, and guidText above is one-way, so the raw value is re-read from this object at
            -- call time rather than reconstructed from its hex text.
            ownerObjectByModelId[instanceId] = mapObject
            if sampleObjectByOwnerUid[builder] == nil then
                sampleObjectByOwnerUid[builder] = mapObject
            end
            mapped = mapped + 1
        end
    end
    trace("poll: map objects=" .. tostring(#models) .. " with a readable builder=" .. tostring(mapped))
    -- Publish for the obtain hook, which runs outside the sweep and needs this to answer "who does
    -- this egg belong to" at the instant a hatch request passes through.
    lastOwnerByModelId = ownerByModelId
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

-- Find the GameState from the WORLD, not from the ModActor.
--
-- This previously asked our ModActor for a "Game State" property and a GetGameStateFromLua()
-- function. Both of those belong to the ORIGINAL AutoHatch blueprint (see
-- reference/AutoHatch-ModActor.hpp); our replacement is a bare Actor carrying exactly one
-- function. So both reads returned nil, playerIdForUid then returned nil for everyone, every
-- owner looked OFFLINE, and all 13 incubators were skipped silently. The log showed the sweep
-- running healthily and selecting nothing, with no error anywhere.
--
-- PalGameStateInGame is the class the chat hook already registers against, so the name is
-- proven rather than guessed. Guessing here is especially dangerous: UE4SS answers an unknown
-- name with a plausible TrivialObject rather than an error.
-- Cached from the chat hook, whose `self` IS the live PalGameStateInGame the server is running.
-- FindAllOf returns instances whose PlayerArray reads empty even with a player connected, so
-- world enumeration alone never sees anybody. The original mod reached the right object through
-- its own blueprint property; this reaches it through a hook argument, which is the one source
-- proven to carry the live instance.
local cachedGameState = nil

local function getGameState(modActor)
    -- Prefer the hooked instance. Verify it still has a readable PlayerArray rather than trusting
    -- the cache blindly: a stale object across a level change would otherwise silently report an
    -- empty server forever.
    if alive(cachedGameState) then
        local okCached, players = readProperty(cachedGameState, "PlayerArray")
        if okCached and players ~= nil then return cachedGameState end
        cachedGameState = nil
    end

    -- Ask the ACTOR's world. This became reachable only once findModActor started taking the
    -- actor BPModLoaderMod actually spawned: a class default object belongs to no world, so
    -- GetWorld on it yields nothing, and the whole route looked unavailable. It is preferred over
    -- the chat cache because it needs nobody to speak first, which otherwise left the mod unable
    -- to resolve a single online player until somebody typed in chat.
    if alive(modActor) then
        local world = nil
        pcall(function() world = modActor:GetWorld() end)
        if alive(world) then
            local fromWorld = nil
            pcall(function() fromWorld = world.GameState end)
            if not alive(fromWorld) then
                pcall(function() fromWorld = world:GetGameState() end)
            end
            if alive(fromWorld) then
                local okArr, players = readProperty(fromWorld, "PlayerArray")
                if okArr and players ~= nil then
                    cachedGameState = fromWorld
                    return fromWorld
                end
            end
        end
    end

    local found = nil
    if not pcall(function() found = FindAllOf("PalGameStateInGame") end) or found == nil then
        return nil
    end
    -- Skip the class default object. FindAllOf returns Default__PalGameStateInGame alongside
    -- the live instance, and the CDO is a perfectly "alive" object carrying an EMPTY PlayerArray.
    -- Taking the first hit therefore read the template, every player looked offline, and all 44
    -- completed eggs were skipped in silence while ownership resolved 13/13 correctly.
    --
    -- Prefer an instance that actually has players in it; fall back to any non-default object so
    -- an empty server still resolves rather than returning nil.
    local fallback = nil
    for index = 1, #found do
        local candidate = found[index]
        local name = nil
        pcall(function() name = candidate:GetFullName() end)
        if alive(candidate) and name ~= nil and not string.find(name, "Default__", 1, true) then
            if fallback == nil then fallback = candidate end
            local okArr, players = readProperty(candidate, "PlayerArray")
            local count = nil
            if okArr and players ~= nil then pcall(function() count = #players end) end
            if type(count) == "number" and count > 0 then return candidate end
        end
    end
    return fallback
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

-- Whether the Blueprint graph EXECUTES is observed here, not by a Print String node. UE strips
-- UKismetSystemLibrary::PrintString entirely in Shipping and Test builds
-- (`#if !(UE_BUILD_SHIPPING || UE_BUILD_TEST)` wraps its whole body, read from the UE 5.1 engine
-- source), and this server is PalServer-Win64-Shipping.exe. A Print String first node therefore
-- emits nothing whether or not the graph ran, which is a probe that cannot go green. Do not
-- instrument a server Blueprint that way again.
--
-- What survives Shipping is the graph's own side effects. `Do Hatch` calls
-- ObtainHatchedCharacter_ServerInternal on the egg model, and nothing in THIS file calls that
-- function, so a fire of its hook while inDoHatchCall is set proves the graph reached the call
-- node. The hook path is the one already proven to register and fire in
-- reference/AutoHatch-main.lua.
local inDoHatchCall = false
local obtainFiresInsideCall = 0
local obtainFiresTotal = 0
-- Fires of a hook on OUR OWN Do Hatch. This is the earlier and stricter of the two signals: it
-- rises when ProcessEvent reaches the function, before any node in the body runs, so it separates
-- "dispatch never happened" from "dispatch happened and the body did nothing".
local doHatchHookFires = 0

-- One-shot dispatch probe, consumed in sweepOnce. Declared here because Lua resolves a name that
-- has no local in scope to a GLOBAL rather than erroring, so a local declared below its use reads
-- as nil and the probe would silently never fire. probeTarget is refreshed every sweep and only
-- ever holds an ONLINE owner's own incubator, so this can never address another player's eggs.
-- Off: it has served its purpose. It proved dispatch reaches our Blueprint and runs its body to
-- the delivery node, which is exactly what showed the Blueprint route cannot deliver at all.
local DISPATCH_PROBE = false
local dispatchProbeFired = false
local probeTarget = nil

---------------------------------------------------------------------------------------------
-- DELIVERY VIA THE ORIGINAL MOD'S OWN ENTRY POINT.
--
-- Our companion Blueprint is proven to dispatch and to run its body all the way to
-- ObtainHatchedCharacter_ServerInternal (processevent=true, reached_obtain=true, recipient
-- correct), and the egg is still not consumed. Direct Lua calls to the same function behave
-- identically. So the caller was never the variable: that function ignores an injected request
-- whatever invokes it. Its real payload is the Archive parameter, which the original builds by
-- streaming bytes through GetBytes(uint8) into ByteArray; we pass a default-constructed one.
--
-- AutoHatch(FGuid PlayerUId) on the ORIGINAL mod's ModActor is the whole working delivery path
-- and takes the recipient as a parameter. The original hatches reliably; its only defect is
-- choosing the recipient, which is exactly the step we replace. reference/AutoHatch-ModActor.hpp
-- flagged this on 2026-08-28: "AutoHatch(FGuid) takes the recipient directly, so a fix can skip
-- the broken step."
--
-- Its pak is re-enabled, its own Lua is NOT: with no enabled.txt, its shared-context sweep never
-- runs, so the blueprint exists purely as machinery we drive. UseAutoHatch is forced false every
-- cycle as a second guard, because the sweep it gates is the misroute itself.
---------------------------------------------------------------------------------------------

local _OrigModActor = nil
local origHandoffDone = false

local function findOriginalModActor()
    if alive(_OrigModActor) then return _OrigModActor end
    local shared = nil
    pcall(function() shared = ModRef:GetSharedVariable("BPModLoaderMod_AutoHatch") end)
    if alive(shared) then
        _OrigModActor = shared
        local name = nil
        pcall(function() name = shared:GetFullName() end)
        trace("orig: found original ModActor, using=" .. tostring(name))
        return _OrigModActor
    end
    return nil
end

-- Hand the original blueprint the three managers its own Lua would normally supply. Without them
-- its graph has no world handles and AutoHatch would run against nils. Each is reported, because
-- a silent partial handoff would look exactly like a working one.
-- The class names are taken VERBATIM from the original's own handoff (reference/AutoHatch-main.lua
-- around the possession hook), which passes the BP_ subclasses, not the native base classes. An
-- earlier attempt here used FindAllOf on the bases and reported true for all three, because a
-- pcall that does not throw reports true whatever the blueprint received.
local function handOffToOriginal(origActor, gameState)
    if origHandoffDone or not alive(origActor) then return end
    local playerManager = FindFirstOf("BP_PalPlayerManager_C")
    local objectManager = FindFirstOf("BP_PalMapObjectManager_C")
    local bpGameState = FindFirstOf("BP_PalGameStateInGame_C")
    local okPlayer = alive(playerManager) and pcall(function() origActor:GetPlayerManagerFromLua(playerManager) end)
    local okObject = alive(objectManager) and pcall(function() origActor:GetObjectManagerFromLua(objectManager) end)
    local okState = alive(bpGameState) and pcall(function() origActor:GetGameStateFromLua(bpGameState) end)
    -- Report whether each object was FOUND separately from whether the call threw: those are
    -- different failures and the previous version could not tell them apart.
    trace("orig: handoff found gs=" .. tostring(alive(bpGameState)) ..
          " om=" .. tostring(alive(objectManager)) ..
          " pm=" .. tostring(alive(playerManager)) ..
          " | called gs=" .. tostring(okState) ..
          " om=" .. tostring(okObject) ..
          " pm=" .. tostring(okPlayer))
    if okState and okObject and okPlayer then origHandoffDone = true end
end

-- Register every connected player's PalPlayerState with the original blueprint. Its own Lua does
-- this per player on OnCompleteInitializeParameter, and AutoHatch(FGuid) resolves its recipient
-- through that registration, so without it the blueprint has no player to deliver to and the call
-- can succeed while doing nothing. Re-run every sweep: it is idempotent and it picks up joins.
local function registerPlayerStatesWithOriginal(origActor, gameState)
    if not alive(origActor) or gameState == nil then return end
    local okArr, playerArray = readProperty(gameState, "PlayerArray")
    if not okArr or playerArray == nil then return end
    local count = nil
    if not pcall(function() count = #playerArray end) or type(count) ~= "number" then return end
    local registered = 0
    for index = 1, count do
        local entry = nil
        if pcall(function() entry = playerArray[index] end) and entry ~= nil then
            local state = unwrap(entry)
            local uid = nil
            pcall(function() uid = guidText(state.PlayerUId) end)
            if isRealUid(uid) and alive(state) then
                -- Key the archive recordings by a STABLE id. The hook only sees the per-connection
                -- PlayerId, which is reassigned on reconnect and meaningless across a restart, so
                -- this map is what lets a capture survive as "this person's recording".
                local playerId = nil
                pcall(function() playerId = state.PlayerId end)
                if playerId ~= nil then uidByPlayerId[playerId] = uid end
                pcall(function() capturedGuidByUid[uid] = state.PlayerUId end)
                if playerId ~= nil then lastPlayerIdByUid[uid] = playerId end
                if pcall(function() origActor:GetPlayerStateFromLua(uid, state) end) then
                    registered = registered + 1
                end
            end
        end
    end
    trace("orig: registered " .. tostring(registered) .. " of " .. tostring(count) .. " player state(s)")
end

-- Deliver every completed egg belonging to ONE owner, addressed to that owner. Called once per
-- owner per sweep, which is what keeps one collection context per owner instead of the single
-- shared context that produced the misroute.
local function callOriginalAutoHatch(origActor, ownerModelId, ownerText)
    local sourceObject = ownerObjectByModelId[ownerModelId]
    if not alive(origActor) or not alive(sourceObject) then
        trace("orig: cannot deliver, actor or source object not alive")
        return false
    end
    -- No recording for this owner means there is nothing to replay. This is a normal state, not
    -- an error: it is every player's state until they hatch one egg by hand.
    -- Prefer a real captured recording; otherwise BUILD this owner's, which the byte layout makes
    -- possible for anyone. The owner's FGuid comes off the incubator itself (BuildPlayerUId), so
    -- this works for a player who has never hand-hatched and for one who is not connected.
    -- MISADDRESS TEST: address this delivery to somebody else entirely, in BOTH the archive and
    -- the AutoHatch argument, so the two cannot disagree. Borrow the target's real FGuid off a
    -- structure they built, since Lua cannot build an FGuid from hex.
    local addressedTo = ownerText
    local addressGuidSource = sourceObject
    if MISADDRESS_TEST_UID ~= nil then
        local sample = sampleObjectByOwnerUid[MISADDRESS_TEST_UID]
        if alive(sample) then
            addressedTo = MISADDRESS_TEST_UID
            addressGuidSource = sample
            trace("MISADDRESS TEST: eggs owned by " .. tostring(ownerText) ..
                  " are being addressed to " .. tostring(MISADDRESS_TEST_UID) ..
                  ". Nothing hatching => the address is honoured; " ..
                  "Pals still arriving => the address is ignored.")
        else
            trace("MISADDRESS TEST: no world object found for " .. tostring(MISADDRESS_TEST_UID) ..
                  ", cannot borrow their FGuid; delivering normally")
        end
    end

    local ownerBytes = archiveBytesByUid[addressedTo]
    local source = "captured"
    if ownerBytes == nil then
        local ownerGuidForArchive = nil
        pcall(function() ownerGuidForArchive = addressGuidSource.BuildPlayerUId end)
        ownerBytes = synthesizeArchiveBytes(ownerGuidForArchive)
        source = "synthesized"
    end
    if ownerBytes == nil then
        trace("orig: no archive for " .. tostring(ownerText) ..
              " and could not synthesize one from the incubator's BuildPlayerUId")
        return false
    end
    trace("orig: archive source=" .. source .. " bytes=" .. bytesToHex(ownerBytes) ..
          " for " .. tostring(ownerText))
    return pcall(function()
        ExecuteInGameThread(function()
            if not alive(origActor) or not alive(sourceObject) then return end
            -- UseAutoHatch is armed ONLY for the duration of this call, then disarmed again.
            -- Forcing it false around the call was self-defeating: it is the mod's single global
            -- gate, and AutoHatch's own graph very plausibly early-outs on it, so the previous
            -- version may have been switching off the exact branch it was trying to invoke. The
            -- reason to keep it false the rest of the time is unchanged: it gates the blueprint's
            -- own timer-driven sweep, which is the shared-context misroute being replaced.
            -- Read it back rather than trusting the write, since a silent no-op here looks
            -- identical to a successful arm.
            -- Load THIS owner's recording. Empty first: nothing in the original clears ByteArray
            -- between sends, which is what made it double every hatch until the game thread hung.
            local beforeLen = nil
            pcall(function() beforeLen = #origActor.ByteArray end)
            local cleared = pcall(function() origActor.ByteArray:Empty() end)
            if not cleared then cleared = pcall(function() origActor.ByteArray:Clear() end) end
            if not cleared then cleared = pcall(function() origActor.ByteArray = {} end) end
            for byteIndex = 1, #ownerBytes do
                pcall(function() origActor:GetBytes(ownerBytes[byteIndex]) end)
            end
            -- Remember what we supplied so the capture hook can recognise this same request when
            -- the blueprint replays it back through ObtainHatchedCharacter_ServerInternal.
            lastLoadedArchiveHex = bytesToHex(ownerBytes)
            local loadedLen = nil
            pcall(function() loadedLen = #origActor.ByteArray end)
            trace("orig: bytearray " .. tostring(beforeLen) .. " -> cleared=" .. tostring(cleared) ..
                  " -> loaded=" .. tostring(loadedLen) .. " of " .. tostring(#ownerBytes) ..
                  " for " .. tostring(ownerText))

            pcall(function() origActor.UseAutoHatch = true end)
            local armed = nil
            pcall(function() armed = origActor.UseAutoHatch end)
            local ownerGuid = nil
            -- Same source as the archive, so the two halves of the request always name the same
            -- person. Under the misaddress test that is deliberately NOT the incubator's owner.
            pcall(function() ownerGuid = addressGuidSource.BuildPlayerUId end)
            if ownerGuid == nil then
                trace("orig: could not re-read BuildPlayerUId for " .. tostring(addressedTo))
                return
            end
            inOurDelivery = true
            local ok, err = pcall(function() origActor:AutoHatch(ownerGuid) end)
            inOurDelivery = false
            pcall(function() origActor.UseAutoHatch = false end)
            trace("orig: AutoHatch(" .. tostring(addressedTo) .. ") armed=" .. tostring(armed) ..
                  " eggs_owned_by=" .. tostring(ownerText) ..
                  " call_ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
        end)
    end)
end

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
    -- The sweep runs under LoopAsync, which is a WORKER thread, and this reaches into Unreal to
    -- run Blueprint bytecode. BPModLoaderMod never does that from off the game thread: it wraps
    -- SpawnActor and its PreBeginPlay() Blueprint call in ExecuteInGameThread
    -- (reference/BPModLoaderMod-main.lua:308 and :339; the comment at :338 says why). Reads such
    -- as FindAllOf and property access survive a worker thread, which is why the sweep looked
    -- healthy while the one call that had to dispatch did not.
    --
    -- ExecuteInGameThread is asynchronous, so this can no longer report the outcome to its
    -- caller. That costs nothing: the caller keys its cooldown on the slot count, never on a
    -- return value, because the return value here was only ever a pcall result.
    local queued = pcall(function()
        ExecuteInGameThread(function()
            -- Revalidate inside the callback. Queueing defers execution, and an actor or egg can
            -- go away between the sweep observing it and the game thread arriving here.
            if not alive(modActor) or not alive(eggModel) then
                trace("hatch: object died before the game thread ran the call")
                return
            end
            -- UE4SS's __index answers ANY name with a plausible TrivialObject, so print what came
            -- back: a UFunction proves the name resolved, a TrivialObject proves it did not.
            local memberType = nil
            pcall(function() memberType = tostring(modActor[BLUEPRINT_HATCH_FN]) end)

            local firesBefore = obtainFiresInsideCall
            local hooksBefore = doHatchHookFires
            inDoHatchCall = true
            local ok, err = pcall(function()
                modActor[BLUEPRINT_HATCH_FN](modActor, eggModel, ownerPlayerId)
            end)
            inDoHatchCall = false
            if not ok then
                trace("hatch: " .. BLUEPRINT_HATCH_FN .. " call_ok=false err=" .. tostring(err))
            end
            -- THE measurement. call_ok says only that nothing threw. `processevent` says whether
            -- dispatch reached the function at all; `reached_obtain` says whether its body ran as
            -- far as the delivery node. Both survive a Shipping build; a Print String node does
            -- not.
            trace("hatch: on_game_thread call_ok=" .. tostring(ok) ..
                  " fn=" .. tostring(memberType) ..
                  " processevent=" .. tostring(doHatchHookFires > hooksBefore) ..
                  " reached_obtain=" .. tostring(obtainFiresInsideCall > firesBefore) ..
                  " obtain_total=" .. tostring(obtainFiresTotal))
        end)
    end)
    if not queued then
        trace("hatch: ExecuteInGameThread unavailable, call NOT dispatched")
    end
    return queued
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
        or current.incubatorsWithOnlineOwner ~= previous.incubatorsWithOnlineOwner
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
        incubators = #eggs, ownersResolved = 0, incubatorsWithOnlineOwner = 0,
        occupiedSlots = 0, completedSlots = 0, hatchesAttempted = 0,
    }
    local detailLines = {}

    -- The delivery machinery. Resolved every sweep because the original's pak loads on the
    -- loader's own schedule, which is later than this mod's first cycles.
    local origActor = findOriginalModActor()
    if origActor ~= nil then
        local liveGameState = getGameState(modActor)
        handOffToOriginal(origActor, liveGameState)
        registerPlayerStatesWithOriginal(origActor, liveGameState)
    end

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
                if ownerOnline then summary.incubatorsWithOnlineOwner = summary.incubatorsWithOnlineOwner + 1 end
            end
            if ownerOnline and gateEnabled and probeTarget == nil then
                probeTarget = { model = model, playerId = ownerPlayerId }
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

            if ownerPlayerId == nil and not ROUTING_TEST then
                -- Owner is offline. Nothing to address delivery to; the egg stays put and
                -- the next sweep after they reconnect will pick it up. This is a design
                -- choice, not a failure: holding beats hatching to nobody.
                goto continue
            end
            if ownerPlayerId == nil then
                trace("ROUTING TEST: proceeding for OFFLINE owner " .. tostring(owner) ..
                      " (normal operation would hold these eggs)")
            end

            -- One call per OWNER, not per slot: AutoHatch takes a recipient and collects that
            -- player's eggs, so a per-slot loop would issue the same request repeatedly. The
            -- cooldown key is therefore the owner, not the slot.
            local key = tostring(owner)
            local last = lastAttemptAt[key]
            local now = nowMs()
            if last == nil or (now - last) >= HATCH_RETRY_COOLDOWN_MS then
                lastAttemptAt[key] = now
                summary.hatchesAttempted = summary.hatchesAttempted + 1
                trace("hatch: owner=" .. tostring(owner) .. " playerId=" .. tostring(ownerPlayerId)
                      .. " model=" .. tostring(modelId) .. " completed=" .. tostring(#completedSlots))
                if origActor ~= nil then
                    callOriginalAutoHatch(origActor, tostring(modelId), tostring(owner))
                else
                    trace("hatch: original ModActor not available, no delivery path")
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
    -- ONE-SHOT DISPATCH PROBE. Whether Lua can make Blueprint bytecode run is a separate
    -- question from whether a ready egg exists, and coupling them means the answer waits on
    -- somebody's incubator finishing. So fire exactly one call against an ONLINE owner's own
    -- incubator, whether or not it holds anything: an empty incubator has nothing to deliver, so
    -- the game side no-ops and no Pal moves, while `processevent` still reports whether dispatch
    -- landed. Restricted to an online owner's own incubator so it can never touch another
    -- player's eggs. Set DISPATCH_PROBE false once the bridge is proven.
    if DISPATCH_PROBE and not dispatchProbeFired and probeTarget ~= nil then
        dispatchProbeFired = true
        trace("probe: firing ONE Do Hatch at an online owner's own incubator (no egg required)")
        callDoHatch(modActor, probeTarget.model, probeTarget.playerId)
    end

    -- Carry the GameState's own player count. owners_online=0 is ambiguous between "nobody is
    -- playing" and "the GameState lookup failed", and reading it as the former wasted a whole
    -- test round while a player was demonstrably connected.
    -- How many players have taught the mod their archive. Delivery is impossible without one, so
    -- a zero here explains an idle mod completely rather than looking like a failure.
    local recordings = 0
    for _ in pairs(archiveBytesByUid) do recordings = recordings + 1 end

    -- Dump the WHOLE PlayerArray, every entry's UId next to its PlayerId. Two things this exists
    -- to check, neither of which the per-owner lookup can show on its own:
    --   1. That the UId match is real. With one player connected, "the entry matching this UId"
    --      and "the first entry" are the same observation, so a broken lookup looks identical.
    --   2. That PalPlayerState.PlayerId is the SAME identifier space as the RequestPlayerId
    --      parameter of ObtainHatchedCharacter_ServerInternal. Both are int32s named PlayerId and
    --      that was assumed, never verified. Reconnecting changes a per-connection PlayerId, so
    --      if this number and the obtain hook's recipient move together, they are one space.
    do
        local liveState = getGameState(modActor)
        if liveState ~= nil then
            local okArr, playerArray = readProperty(liveState, "PlayerArray")
            local count = nil
            if okArr and playerArray ~= nil then pcall(function() count = #playerArray end) end
            if type(count) == "number" then
                for index = 1, count do
                    local entry = nil
                    if pcall(function() entry = playerArray[index] end) and entry ~= nil then
                        local state = unwrap(entry)
                        local entryUid, entryPlayerId = nil, nil
                        pcall(function() entryUid = guidText(state.PlayerUId) end)
                        pcall(function() entryPlayerId = state.PlayerId end)
                        trace("players: [" .. tostring(index) .. "/" .. tostring(count) .. "] uid=" ..
                              tostring(entryUid) .. " player_id=" .. tostring(entryPlayerId))
                        -- Journal a join once per player per server run. A delivery row means
                        -- little without knowing who was connected when it happened, and the
                        -- two-player case is precisely a question about that.
                        if isRealUid(entryUid) and not journaledOnline[entryUid] then
                            journaledOnline[entryUid] = true
                            recordDelivery("online uid=" .. tostring(entryUid) ..
                                           " player_id=" .. tostring(entryPlayerId) ..
                                           " connected_count=" .. tostring(count))
                        end
                    end
                end
            end
        end
    end

    local gameState = getGameState(modActor)
    local connected = "no-gamestate"
    if gameState ~= nil then
        local okArr, playerArray = readProperty(gameState, "PlayerArray")
        local count = nil
        if okArr and playerArray ~= nil then pcall(function() count = #playerArray end) end
        connected = tostring(count)
    end
    trace(string.format(
        "poll.summary: archives=%d incubators=%d owners_resolved=%d incubators_with_online_owner=%d occupied=%d completed=%d attempted=%d players_in_gamestate=%s",
        recordings, summary.incubators, summary.ownersResolved, summary.incubatorsWithOnlineOwner,
        summary.occupiedSlots, summary.completedSlots, summary.hatchesAttempted, connected))
    lastSummaryCounts = summary
end

---------------------------------------------------------------------------------------------
-- Mod bring-up and chat commands. Finding the ModActor does not depend on a player joining
-- (unlike the original's possession hook) — the sweep loop itself looks for it until found,
-- so an empty server still enumerates the world once the Blueprint exists.
---------------------------------------------------------------------------------------------

local _ModActor = nil

-- Skip the class default object, exactly as getGameState does above. FindAllOf returns
-- Default__ModActor_C alongside the spawned actor; a CDO is IsA its own class, answers IsValid,
-- and exposes every UFunction, so it passes every check here while carrying no world. Calling a
-- Blueprint function on it dispatches against a template and delivers nothing. That is the same
-- trap Default__PalGameStateInGame set with its empty PlayerArray.
--
-- The old log line printed MOD_ACTOR_BLUEPRINT_PATH, a hardcoded constant, so it read identical
-- for the CDO and the real actor and was never evidence about the object held. Print the
-- object's own name instead.
local function findModActor()
    if alive(_ModActor) then return _ModActor end

    -- BPModLoaderMod publishes the actor it actually spawned, keyed by mod name
    -- (reference/BPModLoaderMod-main.lua:258). That is the authoritative instance and it cannot
    -- be a CDO, so prefer it over scanning. Scanning stays as the fallback because the shared
    -- variable only exists once the loader has reached the spawn.
    local shared = nil
    pcall(function() shared = ModRef:GetSharedVariable("BPModLoaderMod_AutoHatchFix") end)
    if alive(shared) then
        _ModActor = shared
        local sharedName = nil
        pcall(function() sharedName = shared:GetFullName() end)
        trace("init: ModActor from BPModLoader shared variable, using=" .. tostring(sharedName))
        return _ModActor
    end

    local candidates = nil
    if not pcall(function() candidates = FindAllOf("ModActor_C") end) or candidates == nil then
        return nil
    end
    local skippedDefaults = 0
    for index = 1, #candidates do
        local candidate = candidates[index]
        local isOurs = nil
        pcall(function() isOurs = candidate:IsA(MOD_ACTOR_BLUEPRINT_PATH) end)
        if isOurs and alive(candidate) then
            local name = nil
            pcall(function() name = candidate:GetFullName() end)
            if name ~= nil and string.find(name, "Default__", 1, true) then
                skippedDefaults = skippedDefaults + 1
            else
                _ModActor = candidate
                trace("init: ModActor candidates=" .. tostring(#candidates) ..
                      " skipped_CDO=" .. tostring(skippedDefaults) ..
                      " using=" .. tostring(name))
                return _ModActor
            end
        end
    end
    trace("init: no non-default ModActor among " .. tostring(#candidates) ..
          " candidate(s), skipped_CDO=" .. tostring(skippedDefaults))
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
        -- Capture the live GameState. This hook's self is the running instance, which is the
        -- only source that has reliably yielded a populated PlayerArray on this server.
        local live = nil
        pcall(function() live = self:get() end)
        if live == nil then pcall(function() live = unwrap(self) end) end
        if alive(live) then
            cachedGameState = live
            local okP, players = readProperty(live, "PlayerArray")
            local n = nil
            if okP and players ~= nil then pcall(function() n = #players end) end
            trace("chat: cached GameState, PlayerArray count=" .. tostring(n))
        end
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

-- The execution probe. This hook is observation only: it never calls anything and never alters
-- the delivery. Registration itself is the control, so log it rather than assuming it took.
local function RegisterObtainProbe()
    local ok = pcall(function()
        RegisterHook("/Script/Pal.PalMapObjectHatchingEggModelBase:ObtainHatchedCharacter_ServerInternal",
          -- REDIRECT AT THE DELIVERY BOUNDARY.
          --
          -- Every previous approach tried to ORIGINATE a delivery and failed, because the request
          -- itself can only be produced by a real player action. This does the opposite: it lets
          -- the genuine request happen and edits the one field that says who it is for.
          --
          -- RequestPlayerId is an explicit parameter of this function. We have been reading it all
          -- along and never writing it. UE4SS hands hook arguments as wrappers with :get() and
          -- :set(), so a pre-hook can rewrite it before the game's own body runs. The click keeps
          -- supplying the context and the valid Archive; only the destination changes.
          --
          -- This is what makes the ownership map load-bearing instead of decorative: the egg knows
          -- which incubator it is in, the incubator knows who built it, and that owner is who the
          -- Pal should reach.
          guarded("obtain", function(self, playerId, archive)
            obtainFiresTotal = obtainFiresTotal + 1
            if inDoHatchCall then obtainFiresInsideCall = obtainFiresInsideCall + 1 end
            local recipient = nil
            pcall(function() recipient = playerId:get() end)
            -- THE CAPTURE. A genuine player hatch passes a real Archive through here; that is the
            -- only place a usable one ever exists. Observation only: nothing here alters the call.
            captureArchiveFor(recipient, archive)

            -- Resolve who this egg's incubator belongs to, and redirect the request to them.
            local eggModel = unwrap(self)
            local eggModelId, trueOwnerUid, trueOwnerPlayerId = nil, nil, nil
            pcall(function() eggModelId = guidText(eggModel:GetModelInstanceId()) end)
            if eggModelId ~= nil then trueOwnerUid = lastOwnerByModelId[eggModelId] end
            if trueOwnerUid ~= nil then
                trueOwnerPlayerId = lastPlayerIdByUid[trueOwnerUid]
            end

            -- The forced target wins when set, so the rewrite path runs even when the owner and
            -- the clicker are the same person, which is the only case a solo tester can produce.
            if FORCE_REDIRECT_PLAYER_ID ~= nil then
                trueOwnerPlayerId = FORCE_REDIRECT_PLAYER_ID
            end

            local rewrote = false
            if REDIRECT_TO_OWNER and trueOwnerPlayerId ~= nil and trueOwnerPlayerId ~= recipient then
                -- :set() may not be supported for this parameter on this UE4SS fork. Report
                -- whether the write actually took by reading the value back, rather than assuming
                -- the call succeeded because it did not throw.
                pcall(function() playerId:set(trueOwnerPlayerId) end)
                local readBack = nil
                pcall(function() readBack = playerId:get() end)
                rewrote = (readBack == trueOwnerPlayerId)
                trace("obtain: REDIRECT " .. tostring(recipient) .. " -> " ..
                      tostring(trueOwnerPlayerId) .. " (owner " .. tostring(trueOwnerUid) ..
                      ") readback=" .. tostring(readBack) .. " took=" .. tostring(rewrote))
            end

            trace("obtain: fired inside_do_hatch=" .. tostring(inDoHatchCall) ..
                  " ours=" .. tostring(inOurDelivery) ..
                  " recipient=" .. tostring(recipient) ..
                  " egg_owner=" .. tostring(trueOwnerUid) ..
                  " owner_player_id=" .. tostring(trueOwnerPlayerId) ..
                  " redirected=" .. tostring(rewrote) ..
                  " total=" .. tostring(obtainFiresTotal))

            -- The one line that answers the outstanding question, written where a restart cannot
            -- erase it. A row whose egg_owner is NOT the tester's UId is the two-player result.
            recordDelivery("delivery egg_owner=" .. tostring(trueOwnerUid) ..
                           " owner_player_id=" .. tostring(trueOwnerPlayerId) ..
                           " request_player_id=" .. tostring(recipient))
            return false
        end))
    end)
    trace("init: obtain probe registered=" .. tostring(ok))
end

-- Hook our own Blueprint function. Registration is itself informative: UE4SS can only hook an
-- FName it has seen, so a registration failure says the name is wrong, which is the one reading
-- the uasset's name table cannot rule out from here.
-- Register against BOTH spellings and report each. The cooked asset's name table carries
-- "Do Hatch" three times and "DoHatch" zero times, so the space is what the class exposes; but
-- UE4SS splits a hook path on ':' and its handling of a space in the trailing name is unproven
-- here, so a failure to register does not by itself mean the name is wrong. Registering both
-- separates "UE4SS cannot express this name" from "this name does not exist".
-- Registered LAZILY, on the first cycle that has an actor, not at init. UE4SS can only hook a
-- class it has already loaded, and BPModLoaderMod spawns our ModActor well after this mod's
-- ExecuteAsync runs, so registering at init failed for BOTH spellings and said nothing about
-- either name. A registration attempt before the class exists is another control that cannot
-- go green.
local doHatchProbeAttempted = false

local function RegisterDoHatchProbe()
    if doHatchProbeAttempted then return end
    doHatchProbeAttempted = true
    for _, candidateName in ipairs({ BLUEPRINT_HATCH_FN, "DoHatch" }) do
        local ok = pcall(function()
            RegisterHook(MOD_ACTOR_BLUEPRINT_PATH .. ":" .. candidateName,
              guarded("dohatch", function()
                doHatchHookFires = doHatchHookFires + 1
                trace("dohatch: ProcessEvent reached '" .. candidateName ..
                      "', fires=" .. tostring(doHatchHookFires))
                return false
            end))
        end)
        trace("init: Do Hatch probe name='" .. candidateName .. "' registered=" .. tostring(ok))
    end
end

local function RegisterPollLoop()
    LoopAsync(POLL_INTERVAL_MS, guarded("poll", function()
        local modActor = findModActor()
        if modActor == nil then
            trace("poll: no ModActor yet, waiting")
            return false -- keep looping; do not stop on a transient absence
        end
        RegisterDoHatchProbe()
        sweepOnce(modActor)
        return false
    end))
end

ExecuteAsync(function()
    loadPlayerSettings()
    RegisterChatHook()
    RegisterObtainProbe()
    RegisterPollLoop()
    trace("init: AutoHatchFix loaded")
end)
