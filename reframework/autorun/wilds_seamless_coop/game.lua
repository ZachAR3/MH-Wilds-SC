-- Thin, defensive access to the game's own managed types (via REFramework's type database).
-- Type and method names come from live-verified notes in github.com/Hunterjet/mhwilds-seamless-coop (MIT).
local util = require("wilds_seamless_coop.util")

local game = {}

------------------------------------------------------------------------------------------------------------------------
-- Type database helpers
------------------------------------------------------------------------------------------------------------------------

local types, methods = {}, {}

function game.type(name, quiet)
    local td = types[name]
    if td == nil then
        td = sdk.find_type_definition(name) or false
        if not td and not quiet then util.warn("type not found: " .. name) end
        types[name] = td
    end
    return td or nil
end

-- First method called `name` on `type_name` (optionally with `nparams` parameters).
function game.method(type_name, name, nparams)
    local key = type_name .. "::" .. name .. "/" .. tostring(nparams)
    local m = methods[key]
    if m == nil then
        m = false
        local td = game.type(type_name)
        for _, cand in ipairs(td and td:get_methods() or {}) do
            if cand:get_name() == name and (nparams == nil or cand:get_num_params() == nparams) then
                m = cand
                break
            end
        end
        if td and not m then util.warn("method not found: " .. key) end
        methods[key] = m
    end
    return m or nil
end

function game.param_types(method)
    local out = {}
    for i, td in ipairs(method:get_param_types() or {}) do out[i] = td:get_full_name() end
    return out
end

function game.returns_bool(method)
    local rt = method:get_return_type()
    return rt ~= nil and rt:get_full_name() == "System.Boolean"
end

-- Value of enum `type_name`.`field`, or `fallback` when the type database doesn't expose it.
function game.enum(type_name, field, fallback)
    local td = game.type(type_name)
    local f = td and td:get_field(field)
    if f then
        local ok, v = pcall(f.get_data, f, nil)
        if ok and v ~= nil then return v end
    end
    return fallback
end

-- Hook every overload of type_name.name; pre(args, method) and post(retval, method) also get the hooked overload.
-- Hooks can't be removed, so callers check their own toggle at run time.
game.hook_requests = {} -- every { type, method } a feature asked to hook (for the self-test)
function game.hook(type_name, name, pre, post)
    table.insert(game.hook_requests, { type_name, name })
    local td = game.type(type_name)
    local count = 0
    for _, m in ipairs(td and td:get_methods() or {}) do
        if m:get_name() == name then
            local ok, err = pcall(sdk.hook, m,
                function(args) return pre and pre(args, m) or sdk.PreHookResult.CALL_ORIGINAL end,
                function(retval) if post then return post(retval, m) end return retval end)
            if ok then count = count + 1 else util.warn("hook " .. type_name .. "." .. name .. ": " .. tostring(err)) end
        end
    end
    if td and count == 0 then util.warn("nothing hooked for " .. type_name .. "." .. name) end
    return count > 0
end

------------------------------------------------------------------------------------------------------------------------
-- Hook argument helpers. args[1] = thread context, args[2] = this, args[2 + i] = parameter i.
------------------------------------------------------------------------------------------------------------------------

function game.arg_this(args) return sdk.to_managed_object(args[2]) end
function game.arg_obj(args, i) return sdk.to_managed_object(args[2 + i]) end
function game.arg_int(args, i) return sdk.to_int64(args[2 + i]) & 0xFFFFFFFF end
function game.arg_bool(args, i) return (sdk.to_int64(args[2 + i]) & 1) == 1 end
function game.arg_guid(args, i) return game.guid_str(sdk.to_valuetype(args[2 + i], "System.Guid")) end

game.TRUE = sdk.to_ptr(1)
game.FALSE = sdk.to_ptr(0)

------------------------------------------------------------------------------------------------------------------------
-- Guids are kept as strings everywhere and converted back with the game's own System.Guid.Parse when calling.
------------------------------------------------------------------------------------------------------------------------

function game.guid_str(guid)
    if guid == nil then return nil end
    local ok, s = pcall(guid.call, guid, "ToString()")
    if ok and type(s) == "string" then return s end
    return nil
end

function game.guid(str)
    local parse = game.method("System.Guid", "Parse", 1)
    return parse and parse:call(nil, sdk.create_managed_string(str)) or nil
end

local EMPTY_GUID = "00000000-0000-0000-0000-000000000000"
function game.guid_valid(str) return str ~= nil and str ~= EMPTY_GUID end

------------------------------------------------------------------------------------------------------------------------
-- Calling game methods with arguments built from their parameter types.
------------------------------------------------------------------------------------------------------------------------

-- values: { [param_index] = value } overrides; Guid params given as strings are parsed.
-- Remaining params: Boolean -> false, other value types (ints, enums) -> 0, callbacks -> empty delegate,
-- other references -> null.
function game.call(obj, method, values)
    values = values or {}
    local ptypes = method:get_param_types() or {}
    local args = {}
    for i, td in ipairs(ptypes) do
        local v = values[i]
        local tname = td:get_full_name()
        if tname == "System.Guid" and type(v) == "string" then
            v = game.guid(v)
        elseif tname == "System.String" and type(v) == "string" then
            v = sdk.create_managed_string(v)
        elseif v == nil and tname:find("^System%.Action") then
            -- A callback the game will invoke: give it an empty delegate (does nothing) instead of null.
            local ok, d = pcall(sdk.create_delegate, td, 0)
            if ok then v = d end
        elseif v == nil and tname == "System.Boolean" then
            v = false
        elseif v == nil and td:is_value_type() then
            v = 0
        end
        args[i] = v
    end
    return method:call(obj, table.unpack(args, 1, #ptypes))
end

-- Find a component of `obj` of type `type_name`: a zero-argument getter first, then a field.
local accessors = {}
function game.child(obj, type_name)
    if obj == nil then return nil end
    local td = obj:get_type_definition()
    local key = td:get_full_name() .. ">" .. type_name
    local acc = accessors[key]
    if acc == nil then
        acc = false
        for _, m in ipairs(td:get_methods()) do
            local rt = m:get_return_type()
            if m:get_num_params() == 0 and not m:is_static() and rt and rt:get_full_name() == type_name then
                acc = { method = m }
                break
            end
        end
        if not acc then
            for _, f in ipairs(td:get_fields()) do
                if not f:is_static() and f:get_type():get_full_name() == type_name then
                    acc = { field = f }
                    break
                end
            end
        end
        if not acc then util.warn("no " .. type_name .. " reachable from " .. td:get_full_name()) end
        accessors[key] = acc
    end
    if not acc then return nil end
    if acc.method then return acc.method:call(obj) end
    return acc.field:get_data(obj)
end

------------------------------------------------------------------------------------------------------------------------
-- Game objects
------------------------------------------------------------------------------------------------------------------------

function game.mission_manager() return sdk.get_managed_singleton("app.MissionManager") end
function game.network_manager() return sdk.get_managed_singleton("app.NetworkManager") end

function game.request_manager()
    return sdk.get_managed_singleton("app.NetworkRequestManager")
        or game.child(game.network_manager(), "app.NetworkRequestManager")
end

function game.party()
    return game.child(game.network_manager(), "app.Net_Party")
end

game.SESSION = {
    LOBBY = function() return game.enum("app.net_session_manager.SESSION_TYPE", "LOBBY", 1) end,
    QUEST = function() return game.enum("app.net_session_manager.SESSION_TYPE", "QUEST", 2) end,
    LINK = function() return game.enum("app.net_session_manager.SESSION_TYPE", "LINK", 3) end,
}

local function call0(obj, name)
    local ok, v = pcall(obj.call, obj, name)
    if ok then return v end
    return nil
end

-- Snapshot of a Net_UserInfo as plain Lua values (safe to keep across frames).
function game.member(info)
    if info == nil or not call0(info, "get_IsValid") then return nil end
    return {
        name = call0(info, "get_PlName") or "?",
        hunter_id = game.guid_str(call0(info, "get_HunterId")),
        user_id = game.guid_str(call0(info, "get_UserId")),
        is_self = call0(info, "get_IsSelf") == true,
        is_sync = call0(info, "get_IsPartySync") == true,
        progress = call0(info, "get_MemberListProgressId"),
        online_id = call0(info, "get_OnlineId"), -- Steam persona name on Steam (the game never exposes SteamID64)
    }
end

-- Raw Net_UserInfo objects of a session (valid this frame only).
function game.member_infos(session)
    local out = {}
    local nm = game.network_manager()
    local uim = nm and call0(nm, "get_UserInfoManager")
    local list = uim and uim:call("getUserInfoList", session)
    local arr = list and list:get_field("_ListInfo")
    if arr == nil then return out end
    for i = 0, arr:get_size() - 1 do
        local info = arr:get_element(i)
        if info and call0(info, "get_IsValid") then out[#out + 1] = info end
    end
    return out
end

-- My own Net_UserInfo, from the Link Party or the lobby.
function game.self_info()
    for _, session in ipairs({ game.SESSION.LINK(), game.SESSION.LOBBY() }) do
        for _, info in ipairs(game.member_infos(session)) do
            if call0(info, "get_IsSelf") then return info end
        end
    end
    return nil
end

-- "Card": the game's own block-list record of a hunter (app.savedata.cBlockUserInfo) as plain values. The game
-- can build a Link Party invite target from it (Net_MLUserInfo(cBlockUserInfo)), so a saved card lets the mod
-- re-invite a group member after a disconnect even when they are in no session with us.
local CARD_FIELDS = { UserId = "guid", HunterId = "guid", PlatformId = "num", UniqueId = "str", ShortHunterId = "str",
    HunterName = "str", Hr = "num" }

function game.card_of(info)
    local blk = info and call0(info, "conv2BlockUserInfo")
    if not blk then return nil end
    local card = {}
    for f, kind in pairs(CARD_FIELDS) do
        local ok, v = pcall(blk.get_field, blk, f)
        if ok and v ~= nil then
            if kind == "guid" then v = game.guid_str(v) end
            if kind == "str" and type(v) ~= "string" then v = tostring(v) end
            card[f] = v
        end
    end
    if not game.guid_valid(card.HunterId) then return nil end
    return card
end

function game.self_card() return game.card_of(game.self_info()) end

-- Net_MLUserInfo built from a card (what NetworkRequestManager.inviteLinkParty takes), or nil, why.
function game.ml_from_card(card)
    if type(card) ~= "table" or not game.guid_valid(card.HunterId) then return nil, "no card" end
    local blk = sdk.create_instance("app.savedata.cBlockUserInfo")
    if not blk then return nil, "cBlockUserInfo not creatable" end
    blk = blk:add_ref()
    for f, kind in pairs(CARD_FIELDS) do
        local v = card[f]
        if v ~= nil then
            if kind == "guid" then v = game.guid(v) end
            if kind == "str" then v = sdk.create_managed_string(v) end
            local ok, err = pcall(blk.set_field, blk, f, v)
            if not ok then return nil, "card field " .. f .. ": " .. tostring(err) end
        end
    end
    local ml = sdk.create_instance("app.Net_MLUserInfo")
    if not ml then return nil, "Net_MLUserInfo not creatable" end
    ml = ml:add_ref()
    local ok, err = pcall(ml.call, ml, "importFrom(app.savedata.cBlockUserInfo)", blk)
    if not ok then return nil, "importFrom: " .. tostring(err) end
    return ml
end

-- The local hunter (app.HunterCharacter) and the fast-travel mini event (app.mcFastTravel).
function game.master_hunter()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    local info = pm and call0(pm, "getMasterPlayer")
    return info and call0(info, "get_Character")
end

function game.fast_travel()
    local gm = sdk.get_managed_singleton("app.GameMiniEventManager")
    return gm and call0(gm, "get_FastTravel")
end

-- My own snapshot in a session, or nil.
function game.self_member(session)
    for _, m in ipairs(game.members(session)) do
        if m.is_self then return m end
    end
    return nil
end

-- Members of a session (SESSION_TYPE value), as member snapshots.
function game.members(session)
    local out = {}
    local nm = game.network_manager()
    local uim = nm and call0(nm, "get_UserInfoManager")
    local list = uim and uim:call("getUserInfoList", session)
    local arr = list and list:get_field("_ListInfo")
    if arr == nil then return out end
    for i = 0, arr:get_size() - 1 do
        local m = game.member(arr:get_element(i))
        if m then out[#out + 1] = m end
    end
    return out
end

function game.in_session(session)
    for _, m in ipairs(game.members(session)) do
        if m.is_self then return true end
    end
    return false
end

-- The stage (app.FieldDef.STAGE) the local hunter is in, as the number the game's own invite request takes.
-- The getter isn't named in any public notes, so it is found once in the type database (needs seamless_net.dll),
-- checked by calling it, and remembered in config.learned.stage_getter. Candidates are written to stage_candidates.json.
local stage_scanned = false

local function read_stage(g)
    local m = game.method(g.type, g.method, 0)
    if not m then return nil end
    local obj
    if not g.static then
        obj = sdk.get_managed_singleton(g.type)
        if not obj then return nil end
    end
    local ok, v = pcall(m.call, m, obj)
    if ok and type(v) == "number" then return v end
    return nil
end

function game.current_stage()
    -- Found by scanning the type database (research/scan-2026-11-19.json): the game's own field manager.
    local v = read_stage({ type = "app.MasterFieldManager", method = "get_CurrentStage" })
    if v ~= nil then return v end
    if util.config.learned.stage_getter then return read_stage(util.config.learned.stage_getter) end
    if stage_scanned then return nil end
    stage_scanned = true
    local p = rawget(_G, "seamless_net")
    if not (p and p.scan) then return nil end
    local ok, hits = pcall(p.scan, { "getCurrentStage", "get_CurrentStage", "getNowStage", "get_NowStage", "get_Stage",
        "getStage", "~CurrentStage", "~NowStage", "~CurStage" })
    if not ok then return nil end
    local found = {}
    for _, h in ipairs(hits) do
        if h.ret == "app.FieldDef.STAGE" and #h.params == 0 then
            found[#found + 1] = { type = h.type, method = h.method, static = h.static }
        end
    end
    pcall(json.dump_file, "wilds_seamless_coop/stage_candidates.json", found)
    for _, c in ipairs(found) do
        local v = read_stage(c)
        if v then
            util.config.learned.stage_getter = c
            util.save_config()
            util.info(string.format("current stage read with %s.%s (now %s)", c.type, c.method, tostring(v)))
            return v
        end
    end
    util.warn("no current-stage getter found; auto Environment Link invites will use the stage from your last manual invite")
    return nil
end

function game.story_progress()
    local mm = game.mission_manager()
    return mm and call0(mm, "getProgressId")
end

function game.party_sync_progress()
    local mm = game.mission_manager()
    return mm and call0(mm, "getPartySyncProgressId")
end

-- The next main story mission (app.MissionIDList.ID), the best "same story point" key between players.
function game.next_main_mission()
    local m = game.method("app.MissionUtil", "getExpectLoadMainMissionId", 0)
    if not m then return nil end
    local ok, v = pcall(m.call, m, nil)
    if ok then return v end
    return nil
end

-- Mission id (app.MissionIDList.ID) that a mission-owned object belongs to, via its own getter or field.
function game.mission_of(obj)
    local ok, v = pcall(game.child, obj, "app.MissionIDList.ID")
    if ok then return v end
    return nil
end

return game
