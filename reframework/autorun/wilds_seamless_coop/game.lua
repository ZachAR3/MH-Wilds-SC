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
function game.arg_guid(args, i) return game.ptr_guid(args[2 + i]) end

game.TRUE = sdk.to_ptr(1)
game.FALSE = sdk.to_ptr(0)

------------------------------------------------------------------------------------------------------------------------
-- Guids are kept as strings everywhere and turned back into System.Guid values when calling.
------------------------------------------------------------------------------------------------------------------------

-- Guids are packed and unpacked here in Lua, byte by byte, never with a method called on a value type.
-- The data of a value type starts at byte 0: a field read with get_field, sdk.to_valuetype(address) and an argument
-- the game reads (all checked live on 2026-11-21: Net_MLUserInfo.importFrom copies a friend's HunterId/UserId to
-- exactly the bytes read at 0, and the game's Guid.op_Equality compares bytes 0..15).
-- But a method called on a value type works on byte 16 onward. ToString() therefore showed the NEXT field (the
-- "hunter id" logged by 0.5.x was really the user id), and .ctor/Guid.Parse wrote past the end of the 16-byte buffer:
-- that corrupted memory and crashed the game seconds later in the live test. Getters returning a Guid
-- (get_HunterId, ...) return nil: read the field instead.
-- Layout: Data1 (4 bytes), Data2 (2), Data3 (2) little-endian, then 8 bytes in order.

-- The two 8-byte halves of a Guid string, or nil.
local function guid_halves(str)
    if type(str) ~= "string" then return nil end
    local h = str:gsub("[{}%-]", ""):lower()
    if #h ~= 32 or h:find("[^0-9a-f]") then return nil end
    local function x(i, n) return tonumber(h:sub(i, i + n - 1), 16) end
    local tail = {}
    for i = 0, 7 do tail[#tail + 1] = x(17 + i * 2, 2) end
    local raw = string.pack("<I4I2I2", x(1, 8), x(9, 4), x(13, 4)) .. string.char(table.unpack(tail))
    return string.unpack("<i8i8", raw)
end

local function halves_str(q0, q1)
    local raw = string.pack("<i8i8", q0, q1)
    local d1, d2, d3 = string.unpack("<I4I2I2", raw)
    return string.format("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x", d1, d2, d3, raw:byte(9, 16))
end

-- Guid string at an address (a Guid hook argument is passed by pointer), or nil.
function game.ptr_guid(ptr)
    local ok, s = pcall(function()
        local v = sdk.to_valuetype(ptr, "System.Guid")
        return halves_str(v:read_qword(0), v:read_qword(8))
    end)
    return ok and s or nil
end

-- A value type of `name` with exactly `size` bytes, or nil (never write into one of another size).
local function new_value(name, size)
    local td = sdk.find_type_definition(name)
    if not td then return nil end
    local ok, n = pcall(td.get_valuetype_size, td)
    if not ok or n ~= size then return nil end
    return ValueType.new(td)
end

-- Guid string of a System.Guid value (read from a field, or made by game.guid), or nil.
function game.guid_str(guid)
    if guid == nil then return nil end
    if type(guid) == "string" then return guid end
    local ok, s = pcall(function() return halves_str(guid:read_qword(0), guid:read_qword(8)) end)
    return ok and s or nil
end

-- Guid string of the field `name` of a game object, or nil.
function game.guid_field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(obj.get_field, obj, name)
    return ok and game.guid_str(v) or nil
end

-- A System.Guid value for `str`, ready to pass as an argument, or nil.
function game.guid(str)
    local q0, q1 = guid_halves(str)
    if not q0 then return nil end
    local ok, g = pcall(function()
        local v = assert(new_value("System.Guid", 16))
        v:write_qword(0, q0)
        v:write_qword(8, q1)
        return v
    end)
    return ok and g or nil
end

local EMPTY_GUID = "00000000-0000-0000-0000-000000000000"
function game.guid_valid(str) return str ~= nil and str ~= EMPTY_GUID end

------------------------------------------------------------------------------------------------------------------------
-- Calling game methods with arguments built from their parameter types.
------------------------------------------------------------------------------------------------------------------------

-- values: { [param_index] = value } overrides; Guid params given as strings are parsed.
-- Remaining params: Boolean -> false, other value types (ints, enums) -> 0, other references -> null.
-- A callback parameter (System.Action / Func) without a value is never sent: the call is refused (error). In
-- 0.5.0/0.5.1 null callbacks froze and crashed the game, and REFramework can't make a working one (checked live
-- 2026-11-21: sdk.create_delegate(type, 0) returns nil, (type, 1) an empty delegate with no method behind it).
-- Use the game's menu requests (game.menu) instead: they build their own callbacks.
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
        elseif v == nil and (tname:find("^System%.Action") or tname:find("^System%.Func")) then
            error("no callback object could be made for " .. tname .. "; not calling " .. method:get_name(), 0)
        elseif v == nil and tname == "System.Boolean" then
            v = false
        elseif v == nil and td:is_value_type() then
            v = 0
        end
        args[i] = v
    end
    local name = method:get_name()
    util.breadcrumb("calling " .. name)
    local res = method:call(obj, table.unpack(args, 1, #ptypes))
    util.breadcrumb("returned from " .. name)
    return res
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

------------------------------------------------------------------------------------------------------------------------
-- The game's menu-level network requests (static methods of app.cGUINetworkRequest). They build their own callbacks
-- and show the game's usual windows, so the mod never has to hand the game a callback. Checked live 2026-11-21:
-- reqLinkPartySyncInvite(GUI020011) runs the game's whole "invite Link Party to my environment" flow.
------------------------------------------------------------------------------------------------------------------------

local function c0(obj, name)
    local ok, v = pcall(obj.call, obj, name)
    if ok then return v end
    return nil
end

-- Each request must come from the GUI the game itself opens it from. Watched live 2026-11-22:
--   reqLinkPartySyncInvite      - the Link Party HUD (app.GUI020011), which exists all game.
--   reqLinqPartySyncJoinWindow, reqLinqPartyJoinWindow - the Invitation List (app.GUI040002), which only exists while
--                                 that menu is open. Opened from the HUD instead, with an invite pending, the game threw
--                                 an exception and crashed ~12 s later (the partner's game went down with it).
-- Requests not listed here are refused.
game.MENU_GUI = {
    reqLinkPartySyncInvite = "app.GUI020011",
    reqLinqPartySyncJoinWindow = "app.GUI040002",
    reqLinqPartyJoinWindow = "app.GUI040002",
}

-- The live GUI object of type `gui_type` (default: the Link Party HUD), or nil.
function game.gui_app(gui_type)
    gui_type = gui_type or "app.GUI020011"
    local gm = sdk.get_managed_singleton("app.GUIManager")
    local ok, arr = pcall(function() return gm:get_field("_AllGUI") end)
    if not ok or arr == nil then return nil end
    for i = 0, arr:get_size() - 1 do
        local g = arr:get_element(i)
        if g and g:get_type_definition():get_full_name() == gui_type then return g end
    end
    return nil
end

-- Call app.cGUINetworkRequest.<name>(gui, ...). The GUI argument is filled in; returns the result or errors.
-- Callback parameters (System.Action / Func) may only be passed explicitly; none is ever made up.
function game.menu(name, ...)
    local gui_type = game.MENU_GUI[name]
    if not gui_type then error("menu request " .. name .. " is not known to be safe from the mod", 0) end
    local m = game.method("app.cGUINetworkRequest", name, select("#", ...) + 1)
    if not m then error("menu request " .. name .. " not found", 0) end
    local gui = game.gui_app(gui_type)
    if not gui then error("the game's " .. gui_type .. " isn't open, so " .. name .. " can't be used now", 0) end
    util.breadcrumb("calling menu " .. name)
    local res = m:call(nil, gui, ...)
    util.breadcrumb("returned from menu " .. name)
    return res
end

-- A static yes/no check of app.cGUINetworkRequest (hasInvitationPartySync, ...), or nil.
-- `name` may be a full signature ("canLinkPartyInvite(app.Net_MLUserInfo, System.Boolean)") to pick an overload.
function game.menu_check(name, ...)
    local m
    if name:find("%(") then
        local td = game.type("app.cGUINetworkRequest")
        m = td and td:get_method(name)
    else
        m = game.method("app.cGUINetworkRequest", name, select("#", ...))
    end
    if not m then return nil end
    local ok, v = pcall(m.call, m, nil, ...)
    if not ok then return nil end
    -- can* checks return cGUISubMenuInfo.EnableFunctionInfo
    if type(v) == "userdata" or type(v) == "table" then
        local ok2, en = pcall(v.call, v, "get_IsEnable")
        return ok2 and en == true
    end
    return v == true
end

-- System.Nullable<System.Guid> holding `str` (or empty when str is nil), ready to pass as an argument.
-- Layout (24 bytes): has-value flag at 0, the Guid at 8.
local NULLABLE_GUID = "System.Nullable`1<System.Guid>"
function game.nullable_guid(str)
    local q0, q1 = 0, 0
    if str then
        q0, q1 = guid_halves(str)
        if not q0 then return nil end
    end
    local ok, v = pcall(function()
        local n = assert(new_value(NULLABLE_GUID, 24))
        n:write_qword(0, str and 1 or 0)
        n:write_qword(8, q0)
        n:write_qword(16, q1)
        return n
    end)
    return ok and v or nil
end

-- Hunter id string inside a Nullable<Guid> hook argument (passed by pointer), "none", or "?".
function game.arg_nullable_guid(ptr)
    local ok, s = pcall(function()
        local n = sdk.to_valuetype(ptr, NULLABLE_GUID)
        if n:read_qword(0) & 0xFF == 0 then return "none" end
        return halves_str(n:read_qword(8), n:read_qword(16))
    end)
    return ok and s or "?"
end

-- The game's own Net_MLUserInfo for a hunter in your Hunter Friends list (what its menu invites), or nil, why.
-- Matched by short hunter id (e.g. "LH5YP9Y4"). Building one from a saved card (importFrom(cBlockUserInfo)) gave a
-- wrong hunter id in the live test, so only the friend list is used.
function game.friend_ml(short_id)
    if type(short_id) ~= "string" or short_id == "" then return nil, "no hunter id saved" end
    local nm = game.network_manager()
    local fm = nm and nm:get_field("_FriendManager")
    local list = fm and c0(fm, "get_FriendList")
    if list == nil then return nil, "friend list not loaded" end
    for i = 0, list:get_size() - 1 do
        local f = list:get_element(i)
        local valid = f and (c0(f, "get_IsValid") or f:get_field("<IsValid>k__BackingField"))
        local param = valid and f:get_field("<Param>k__BackingField")
        local sid = param and param:get_field("_ShortHunterShortId")
        if sid ~= nil and tostring(sid) == short_id then
            local ml = sdk.create_instance("app.Net_MLUserInfo")
            if not ml then return nil, "Net_MLUserInfo not creatable" end
            ml = ml:add_ref()
            local ok, err = pcall(ml.call, ml, "importFrom(app.Net_SocialUserInfoWithStatus)", f)
            if not ok then return nil, "importFrom: " .. tostring(err) end
            return ml
        end
    end
    return nil, "not in your Hunter Friends list"
end

------------------------------------------------------------------------------------------------------------------------
-- Raw member reads (0.5.5)
--
-- Crash bisect 2026-11-22 (PC + Steam Deck, scripted Link Party + Environment Link joins): with the mod's member
-- list reads on, the game crashed every 1-5 joins (engine release queue / managed heap); with every game read off and
-- everything else the same, 7 joins in a row were clean. Each wrapped read hands game objects to Lua: REFramework
-- adds a reference to every Net_UserInfoList / array / Net_UserInfo / Net_UserParam it wraps and drops it again when
-- Lua collects the wrapper, while the game is creating and freeing those very objects for the join.
-- So member lists are read as plain memory instead: sdk.to_valuetype(address, "System.UInt64") copies 8 bytes and
-- never touches a game object's reference count. Field offsets come from the game's own type database (looked up by
-- name once), so a game patch that moves fields keeps working, and one that renames them falls back to the old
-- wrapped read (logged once).
------------------------------------------------------------------------------------------------------------------------

local raw = { off = nil, warned = false }
game.raw = raw

local ARRAY_COUNT, ARRAY_DATA = 0x1c, 0x20 -- System.Array: element count, first element
local STRING_LEN, STRING_CHARS = 0x10, 0x14 -- System.String: length (UTF-16 units), characters

local function plausible(a)
    return type(a) == "number" and a > 0x10000 and a < 0x7FFFFFFFFFFF and a % 8 == 0
end

local function peek(a)
    local v = sdk.to_valuetype(a, "System.UInt64")
    if not v then error("peek failed") end
    return v
end
local function q(a) return peek(a):read_qword(0) end
local function u32(a) return peek(a):read_dword(0) end
local function u16(a) return peek(a):read_short(0) % 0x10000 end
local function u8(a) return peek(a):read_byte(0) % 0x100 end

local function field_off(type_name, field)
    local td = game.type(type_name, true)
    local f = td and td.get_field and td:get_field(field)
    return f and f:get_offset_from_base() or nil
end

-- Offsets of every field the reader needs, or false when one is missing.
function raw.offsets()
    if raw.off ~= nil then return raw.off end
    local o = {
        nm_uim = field_off("app.NetworkManager", "_UserInfoManager"),
        lists = { field_off("app.Net_UserInfoManager", "_mlInfo"), field_off("app.Net_UserInfoManager", "_mqInfo"),
            field_off("app.Net_UserInfoManager", "_mlkInfo"), field_off("app.Net_UserInfoManager", "_mmInfo") },
        list_arr = field_off("app.Net_UserInfoList", "_ListInfo"),
        list_session = field_off("app.Net_UserInfoList", "sessionType"),
        info_param = field_off("app.Net_UserInfo", "param"),
        info_valid = field_off("app.Net_UserInfo", "<IsValid>k__BackingField"),
        info_self = field_off("app.Net_UserInfo", "<IsSelf>k__BackingField"),
        name = field_off("app.Net_UserParam", "PlName"),
        short_id = field_off("app.Net_UserParam", "ShortHunterId"),
        online_id = field_off("app.Net_UserParam", "OnlineId"),
        hunter = field_off("app.Net_UserParam", "HunterId"),
        user = field_off("app.Net_UserParam", "UserId"),
        sync = field_off("app.Net_UserParam", "IsPartySync"),
        progress = field_off("app.Net_UserParam", "MemberListProgressId"),
        platform = field_off("app.Net_UserParam", "PlatformId"),
        hr = field_off("app.Net_UserParam", "HunterRank"),
    }
    local missing = {}
    for k, v in pairs(o) do
        if v == nil then missing[#missing + 1] = k end
    end
    for i = 1, 4 do
        if o.lists[i] == nil then missing[#missing + 1] = "list" .. i end
    end
    if #missing > 0 then
        util.warn("member lists: game fields not found (" .. table.concat(missing, ", ") .. "), using the slower wrapped read")
        raw.off = false
    else
        raw.off = o
    end
    return raw.off
end

local function utf16(units)
    local out, i = {}, 1
    while i <= #units do
        local c = units[i]
        if c >= 0xD800 and c <= 0xDBFF and units[i + 1] and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF then
            c = 0x10000 + (c - 0xD800) * 0x400 + (units[i + 1] - 0xDC00)
            i = i + 1
        elseif c >= 0xD800 and c <= 0xDFFF then
            c = 0xFFFD
        end
        out[#out + 1] = utf8.char(c)
        i = i + 1
    end
    return table.concat(out)
end

-- A System.String field of the object at `obj` (nil when null).
local function raw_string(obj, off)
    local s = q(obj + off)
    if s == 0 or not plausible(s) then return nil end
    local len = u32(s + STRING_LEN)
    if len > 256 then return nil end
    local units = {}
    for k = 0, len - 1, 4 do
        local w = q(s + STRING_CHARS + 2 * k)
        for j = 0, 3 do
            if k + j < len then units[#units + 1] = (w >> (16 * j)) & 0xFFFF end
        end
    end
    return utf16(units)
end

local function raw_guid(obj, off) return halves_str(q(obj + off), q(obj + off + 8)) end

-- The NetworkManager singleton, kept so its wrapper isn't made and dropped on every read.
local nm_held
local function network_manager_addr()
    local nm = sdk.get_managed_singleton("app.NetworkManager")
    if nm == nil then return nil end
    nm_held = nm
    return nm:get_address()
end

-- Net_UserParam address and flags of every valid entry of a session's list (SESSION_TYPE value).
local function raw_entries(session)
    local o = raw.offsets()
    if not o then return nil end
    local nm = network_manager_addr()
    if not plausible(nm) then return {} end
    local uim = q(nm + o.nm_uim)
    if not plausible(uim) then return {} end
    local out = {}
    for _, lo in ipairs(o.lists) do
        local list = q(uim + lo)
        if plausible(list) and u32(list + o.list_session) == session then
            local arr = q(list + o.list_arr)
            if not plausible(arr) then return out end
            local n = u32(arr + ARRAY_COUNT)
            if n > 128 then return out end
            for i = 0, n - 1 do
                local info = q(arr + ARRAY_DATA + 8 * i)
                if plausible(info) and u8(info + o.info_valid) ~= 0 then
                    local param = q(info + o.info_param)
                    if plausible(param) then
                        out[#out + 1] = { param = param, is_self = u8(info + o.info_self) ~= 0 }
                    end
                end
            end
            return out
        end
    end
    return out
end

-- Member snapshots of a session from raw memory (same shape as game.member), or nil when unavailable.
function raw.members(session)
    local ok, entries = pcall(raw_entries, session)
    if not ok then
        if not raw.warned then
            raw.warned = true
            util.warn("member lists: raw read failed (" .. tostring(entries) .. ")")
        end
        return nil
    end
    if entries == nil then return nil end
    local o = raw.off
    local out = {}
    for _, e in ipairs(entries) do
        local okm, m = pcall(function()
            local p = e.param
            local progress = u16(p + o.progress)
            return {
                name = raw_string(p, o.name) or "?",
                hunter_id = raw_guid(p, o.hunter),
                user_id = raw_guid(p, o.user),
                is_self = e.is_self,
                is_sync = u8(p + o.sync) ~= 0,
                progress = progress >= 0x8000 and progress - 0x10000 or progress,
                online_id = raw_string(p, o.online_id),
                -- card fields (see game.card_of)
                card = {
                    UserId = raw_guid(p, o.user), HunterId = raw_guid(p, o.hunter), PlatformId = u8(p + o.platform),
                    ShortHunterId = raw_string(p, o.short_id), HunterName = raw_string(p, o.name), Hr = u32(p + o.hr),
                },
            }
        end)
        if okm then out[#out + 1] = m end
    end
    return out
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
    local okp, param = pcall(info.get_field, info, "param")
    param = okp and param or nil
    return {
        name = call0(info, "get_PlName") or "?",
        -- Guid getters return nil: read Net_UserInfo.param (app.Net_UserParam) instead.
        hunter_id = game.guid_field(param, "HunterId"),
        user_id = game.guid_field(param, "UserId"),
        is_self = call0(info, "get_IsSelf") == true,
        is_sync = call0(info, "get_IsPartySync") == true,
        progress = call0(info, "get_MemberListProgressId"),
        online_id = call0(info, "get_OnlineId"), -- Steam persona name on Steam (the game never exposes SteamID64)
    }
end

-- Raw Net_UserInfo objects of a session (valid this frame only).
function game.member_infos(session)
    if util.config.debug_no_reads then return {} end -- crash bisecting only (config.json)
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

-- My own card. 0.5.5: from the raw member read (conv2BlockUserInfo made a new game object on every call).
function game.self_card()
    if util.config.debug_no_reads then return nil end -- crash bisecting only (config.json)
    for _, session in ipairs({ game.SESSION.LINK(), game.SESSION.LOBBY() }) do
        local list = raw.members(session)
        if list == nil then return game.card_of(game.self_info()) end -- raw read unavailable: old path
        for _, m in ipairs(list) do
            if m.is_self and m.card and game.guid_valid(m.card.HunterId) then return m.card end
        end
    end
    return nil
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
-- Read from the game at most once a second per session and shared by every feature: each read wraps the game's
-- network objects (list, Net_UserInfo, Net_UserParam) for Lua, and releasing those wrappers raced the game's own
-- object bookkeeping during Link Party / Environment Link joins (crash in the engine's release queue, 2026-11-22).
-- 0.5.4: even read once a second (and released at once) the reads still crashed the game in that queue, on the host
-- too, roughly once every 4-5 joins; without the mod 6 joins in a row were fine. So unless an experimental feature
-- needs fresher data, the member lists are read only every 15 s (peer matching and the panel can wait that long).
-- 0.5.5: the lists are read as raw memory (see "Raw member reads" above); the wrapped read is only a fallback.
-- The raw read wraps nothing, so it can run every 2 s; only the wrapped fallback keeps the slow 15 s pace.
local function member_ttl()
    if raw.off ~= false or util.any_experimental_at_start() or util.on("auto_link") then return 2.0 end
    return 15.0
end
game.member_ttl = member_ttl
local member_cache = {}

local function read_members(session)
    if util.config.debug_no_reads then return {} end -- crash bisecting only (config.json)
    local list = raw.members(session)
    if list then
        for _, m in ipairs(list) do m.card = nil end
        return list
    end
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

-- fresh = true skips the cache (decisions taken inside a hook, at the moment the game acts).
function game.members(session, fresh)
    local now = util.now()
    local c = member_cache[session]
    if fresh or not c or now - c.at >= member_ttl() or now < c.at then
        c = { at = now, list = read_members(session) }
        member_cache[session] = c
    end
    local copy = {} -- callers may append to the list
    for i, m in ipairs(c.list) do copy[i] = m end
    return copy
end

-- Forget the cached member lists (the next read goes to the game).
function game.refresh_members() member_cache = {} end

function game.in_session(session, fresh)
    for _, m in ipairs(game.members(session, fresh)) do
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
    if util.config.debug_no_reads then return nil end -- crash bisecting only (config.json)
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
    if util.config.debug_no_reads then return nil end -- crash bisecting only (config.json)
    local mm = game.mission_manager()
    return mm and call0(mm, "getProgressId")
end

function game.party_sync_progress()
    local mm = game.mission_manager()
    return mm and call0(mm, "getPartySyncProgressId")
end

-- The next main story mission (app.MissionIDList.ID), the best "same story point" key between players.
function game.next_main_mission()
    if util.config.debug_no_reads then return nil end -- crash bisecting only (config.json)
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
