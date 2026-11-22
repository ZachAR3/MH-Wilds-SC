-- Two-player simulation: loads the real mod twice (leader "A" and follower "B") against a fake game and a fake Steam
-- channel, then plays through the flows that matter for save safety. No game needed.
--   lua5.4 two_players.lua <path to reframework/autorun>
local AUTORUN = assert(arg[1], "usage: lua5.4 two_players.lua <path to reframework/autorun>")

local clock = 0          -- shared fake time (seconds)
local mail = {}          -- [steam id] = queue of { from, data }
local steam_names = {}   -- [steam id] = Steam persona name (what the game shows as OnlineId)
local store, nstore = {}, 0
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

-- Type database shared by both games: { [type] = { { name, { param types }, return type, static } } }
local VALUE = { ["System.Boolean"] = true, ["System.Int32"] = true, ["System.Int16"] = true, ["System.Guid"] = true,
    ["app.MissionIDList.ID"] = true, ["app.Net_Party.PARTY_SYNC_OPTION"] = true, ["app.net_session_manager.SESSION_TYPE"] = true,
    ["app.FieldDef.STAGE"] = true, ["app.NETWORK_ERROR_CODE"] = true }
local VALUE_SIZE = { ["System.Guid"] = 16, ["System.Nullable`1<System.Guid>"] = 24 }
-- A fake game Guid holds a number per label ("HA" -> 1, ...) in its first 8 bytes.
local guid_nos = {}
local function guid_no(str)
    if not guid_nos[str] then guid_nos[#guid_nos + 1] = str; guid_nos[str] = #guid_nos end
    return guid_nos[str]
end
local ENUM_FIELDS = { ["app.NETWORK_ERROR_CODE"] = { { "NONE", 0 }, { "ERR_STORY", 3 }, { "ERR_JOIN_REJECT", 7 } } }
-- Field offsets the mod's raw member reader looks up (the live game's, 2026-11-22). NO_RAW hides them, so the mod
-- falls back to its wrapped read.
local RAW_LAYOUT = {
    ["app.NetworkManager"] = { _UserInfoManager = 0xb8 },
    ["app.Net_UserInfoManager"] = { _mlInfo = 0x10, _mqInfo = 0x18, _mlkInfo = 0x20, _mmInfo = 0x28 },
    ["app.Net_UserInfoList"] = { _ListInfo = 0x10, sessionType = 0x20 },
    ["app.Net_UserInfo"] = { param = 0x10, ["<IsValid>k__BackingField"] = 0x1d, ["<IsSelf>k__BackingField"] = 0x1c },
    ["app.Net_UserParam"] = { PlName = 0x18, ShortHunterId = 0x28, OnlineId = 0x30, HunterId = 0x40, UserId = 0x50,
        IsPartySync = 0x8f, MemberListProgressId = 0x80, PlatformId = 0x82, HunterRank = 0x78 },
}
NO_RAW = false

local function tdef(name)
    local fields = {}
    for _, f in ipairs(ENUM_FIELDS[name] or {}) do
        fields[#fields + 1] = { get_name = function() return f[1] end, is_static = function() return true end,
            get_data = function() return f[2] end }
    end
    return { get_full_name = function() return name end, is_value_type = function() return VALUE[name] == true end,
        get_valuetype_size = function() return VALUE_SIZE[name] or 0 end,
        get_methods = function() return {} end, get_fields = function() return fields end,
        get_field = function(_, f)
            local o = not NO_RAW and RAW_LAYOUT[name] and RAW_LAYOUT[name][f]
            if o then return { get_offset_from_base = function() return o end } end
            return nil
        end }
end
local TYPES = {
    ["app.MissionManager"] = {
        { "reqLoadMission", { "app.MissionIDList.ID" } },
        
        { "setEnableMissionDynamicFlag", { "app.MissionIDList.ID", "System.Int32", "System.Boolean" } },
        { "IsDrawReplicaPlFromProgress", { "System.Int16" }, "System.Boolean" },
        { "isProgressDrawOffSelfFromOthers", { "System.Int16" }, "System.Boolean" },
        { "getCanPartySyncInfoInCurrentStage", {}, "System.Boolean" },
    },
    ["app.NetworkRequestManager"] = { { "inviteLinkPartySync", { "System.Guid", "app.FieldDef.STAGE", "System.Action`2<System.Boolean,app.NETWORK_ERROR_CODE>" } },
        { "inviteLinkParty", { "app.net_session_manager.SESSION_TYPE", "app.Net_MLUserInfo", "System.Action`2<System.Boolean,app.NETWORK_ERROR_CODE>" } },
        { "acceptInviteLinkParty", { "System.Guid", "System.String", "System.Action`2<System.Boolean,app.NETWORK_ERROR_CODE>" } },
        { "leaveSession", { "app.net_session_manager.SESSION_TYPE", "System.Action`2<System.Boolean,app.NETWORK_ERROR_CODE>", "System.Boolean" } } },
    ["app.Net_Party"] = { { "app.NetworkRequestManager.INet_LinkParty.joinPartySync",
        { "System.Guid", "System.Action`3<System.Boolean,app.FieldDef.STAGE,app.NETWORK_ERROR_CODE>", "System.Boolean" } } },
    ["app.mcFastTravel"] = { { "warpPlayer", { "app.HunterCharacter", "app.FieldDef.STAGE", "via.vec3", "via.Quaternion", "app.mcFastTravel.WarpInfo", "app.GimmickBaseApp" } } },
    ["app.MasterFieldManager"] = { { "get_CurrentStage", {}, "app.FieldDef.STAGE" } },
    ["System.Guid"] = { { "Parse", { "System.String" }, "System.Guid", true } },
    ["System.Nullable`1<System.Guid>"] = {},
    -- the game's menu-level requests (static)
    ["app.cGUINetworkRequest"] = {
        { "reqLinkPartySyncInvite", { "app.GUIBaseApp" }, nil, true },
        { "reqLinqPartyInviteWindow", { "app.GUIBaseApp", "app.Net_MLUserInfo", "app.net_session_manager.SESSION_TYPE", "System.Action" }, nil, true },
        { "reqLinqPartyInvite", { "app.GUIBaseApp", "app.Net_MLUserInfo", "app.net_session_manager.SESSION_TYPE", "System.Action" }, nil, true },
        { "hasInvitationPartySync", {}, "System.Boolean", true },
        { "canLinkPartyInvite", { "app.Net_MLUserInfo", "System.Boolean" }, "app.cGUISubMenuInfo.EnableFunctionInfo", true },
        { "canLinkPartyInvite", { "System.Guid", "System.Guid" }, "app.cGUISubMenuInfo.EnableFunctionInfo", true },
    },
    ["app.MissionController"] = { { "setClearObjective", { "app.MissionIDList.ID", "System.Int32", "System.Boolean" } } },
    ["app.DemoMediator"] = {
        { "requestPlay", { "ace.DemoMediatorBase.cParamBase" } }, { "requestSkip", {} },
        { "onPlayStartTimeline", { "System.Int32" } }, { "onPlayEndTimeline", { "System.Int32" } },
    },
    ["app.Net_SessionService"] = { { "reportCheatQuest", { "System.Guid" } },
        { "checkAndReportQuestCheat", { "app.cKeepQuestData", "System.Guid" }, "System.Boolean" } },
}

-- Saved settings the fake game starts with: the experimental features on (the logic tests need them), as a tester
-- would have them. new_player(..., { fresh = true }) starts with no config.json at all.
local TEST_CONFIG = { config_version = 2, story_sync = "dry", auto_link = true,
    relink_after_hunt = true, auto_follow = true, auto_party = true, follow_travel = true, stay_linked = true,
    cutscene_sync = true }

local function new_player(name, steam_id, hunter, opts)
    opts = opts or {}
    steam_names[steam_id] = name .. "_steam"
    local P = { name = name, id = steam_id, hunter = hunter, progress = 300, in_quest = false, party = {},
        calls = {}, hooks = {}, backups = 0, backup_ok = true, warnings = {}, frames = {}, render_frames = {}, entries = {}, render_touches = 0 }
    mail[steam_id] = {}

    local methods = {} -- [type][name] = fake method
    local function method(tname, def)
        local m = { type = tname, name = def[1] }
        local ptypes = {}
        for i, p in ipairs(def[2]) do ptypes[i] = tdef(p) end
        function m:get_name() return def[1] end
        function m:get_num_params() return #ptypes end
        function m:get_param_types() return ptypes end
        function m:get_return_type() return def[3] and tdef(def[3]) or nil end
        function m:is_static() return def[4] == true end
        -- The game's own routine: runs the hooks like REFramework does, then records the "original".
        function m:call(obj, ...)
            local args = def[4] and { "ctx", ... } or { "ctx", obj, ... }
            local skip = false
            for _, h in ipairs(P.hooks[m] or {}) do
                if h.pre and h.pre(args) == 1 then skip = true end
            end
            -- (pure getters are not "calls": they change nothing)
            if not skip and def[1] ~= "get_CurrentStage" and def[1] ~= "Parse" and not def[1]:find("^can")
                    and not def[1]:find("^has") then P.calls[#P.calls + 1] = { tname .. "." .. def[1], ... } end
            local ret = nil
            if def[1] == "getCanPartySyncInfoInCurrentStage" then ret = true end
            if def[1] == "get_CurrentStage" then ret = P.stage end
            if def[1] == "canLinkPartyInvite" then
                local ml = ...
                ret = { call = function(_, k) if k == "get_IsEnable" then return P.can_invite ~= false and ml ~= nil end end }
            end
            for _, h in ipairs(P.hooks[m] or {}) do
                if h.post then ret = h.post(ret) end
            end
            if def[1] == "getCanPartySyncInfoInCurrentStage" then ret = ret == true or (type(ret) == "number" and ret ~= 0) end
            return ret, skip
        end
        return m
    end
    for tname, defs in pairs(TYPES) do
        methods[tname] = {}
        for _, def in ipairs(defs) do methods[tname][#methods[tname] + 1] = method(tname, def) end
    end
    P.methods = methods

    local function info(m)
        -- Like the real game: Guid getters return nil, so ids are only in fields.
        local function guid(str) return { read_qword = function(_, off) if off == 0 then return guid_no(str) end return 0 end } end
        local card = { HunterId = guid(m.hunter), UserId = guid("U" .. m.hunter), HunterName = m.name, PlatformId = 5,
            UniqueId = "uid-" .. m.hunter, ShortHunterId = "S" .. m.hunter, Hr = 50 }
        local param = { HunterId = guid(m.hunter), UserId = guid("U" .. m.hunter) }
        local v = { get_IsValid = true, get_PlName = m.name,
            get_IsSelf = m.hunter == hunter, get_IsPartySync = m.unsynced ~= true, get_MemberListProgressId = 300,
            get_OnlineId = m.name .. "_steam", conv2BlockUserInfo = { get_field = function(_, f) return card[f] end } }
        return { call = function(_, k) return v[k] end,
            get_field = function(_, f) if f == "param" then return { get_field = function(_, g) return param[g] end } end end }
    end
    -- A little address space with the game's member list layout, rebuilt from P.party on every raw read.
    local function build_mem()
        local mem, top = {}, 0x100000
        local function alloc(size) local a = top; top = top + ((size + 15) // 16) * 16 + 16; return a end
        local function put(a, v, n) for i = 0, n - 1 do mem[a + i] = (v >> (8 * i)) & 0xff end end
        local function str(text)
            local units = {}
            for _, c in utf8.codes(text) do units[#units + 1] = c end
            local a = alloc(0x14 + 2 * #units)
            put(a + 0x10, #units, 4)
            for i, c in ipairs(units) do put(a + 0x14 + 2 * (i - 1), c, 2) end
            return a
        end
        local nm, uim = alloc(0x1d0), alloc(0x60)
        put(nm + 0xb8, uim, 8)
        for idx, session in ipairs({ 1, 2, 3, 4 }) do
            local members = {}
            if session == 3 then members = P.party end
            if session == 2 and P.in_quest then members = { { name = name, hunter = hunter } } end
            local list, arr = alloc(0x28), alloc(0x20 + 8 * 4)
            put(uim + 0x10 + 8 * (idx - 1), list, 8)
            put(list + 0x20, session, 4)
            put(list + 0x10, arr, 8)
            put(arr + 0x1c, 4, 4)
            for i = 1, 4 do
                local info = alloc(0x20)
                put(arr + 0x20 + 8 * (i - 1), info, 8)
                local m = members[i]
                if m then
                    local param = alloc(0x98)
                    put(info + 0x10, param, 8)
                    put(info + 0x1d, 1, 1)
                    put(info + 0x1c, m.hunter == hunter and 1 or 0, 1)
                    put(param + 0x18, str(m.name), 8)
                    put(param + 0x28, str("S" .. m.hunter), 8)
                    put(param + 0x30, str(m.name .. "_steam"), 8)
                    put(param + 0x40, guid_no(m.hunter), 8)
                    put(param + 0x50, guid_no("U" .. m.hunter), 8)
                    put(param + 0x8f, m.unsynced ~= true and 1 or 0, 1)
                    put(param + 0x80, 300, 2)
                    put(param + 0x82, 5, 1)
                    put(param + 0x78, 50, 4)
                end
            end
        end
        P.mem = mem
        return nm
    end
    P.read_mem = function(a, n)
        local v = 0
        for i = 0, n - 1 do v = v | ((P.mem[a + i] or 0) << (8 * i)) end
        return v
    end

    local controller = { call = function() end }
    local objects = {
        ["app.MissionManager"] = { call = function(_, k, a)
            if k == "getProgressId" then return P.progress end
            if k == "getPartySyncProgressId" then return 150 end
            if k == "getEnableMissionController" then return a == 7 and controller or nil end
        end },
        ["app.NetworkManager"] = {
            get_address = function()
                P.member_reads = (P.member_reads or 0) + 1
                P.raw_reads = (P.raw_reads or 0) + 1
                return build_mem()
            end,
            get_field = function(_, f)
                if f ~= "_FriendManager" then return nil end
                return { call = function(_, k)
                    if k ~= "get_FriendList" then return nil end
                    local list = {}
                    for _, h in ipairs(P.friends or {}) do
                        local param = { get_field = function(_, g) if g == "_ShortHunterShortId" then return "S" .. h end end }
                        list[#list + 1] = { sid = "S" .. h, call = function(_, c) if c == "get_IsValid" then return true end end,
                            get_field = function(_, g) if g == "<Param>k__BackingField" then return param end end }
                    end
                    return { get_size = function() return #list end, get_element = function(_, i) return list[i + 1] end }
                end }
            end,
            get_type_definition = function()
                local td = tdef("app.NetworkManager")
                td.get_methods = function() return { {
                    get_num_params = function() return 0 end, is_static = function() return false end,
                    get_return_type = function() return tdef("app.Net_Party") end,
                    call = function() return P.objects["app.Net_Party"] end } } end
                return td
            end,
            call = function(_, k)
                if k ~= "get_UserInfoManager" then return nil end
                return { call = function(_, _, session)
                    P.member_reads = (P.member_reads or 0) + 1
                    local list = {}
                    if session == 3 then for _, m in ipairs(P.party) do list[#list + 1] = info(m) end end
                    if session == 2 and P.in_quest then list[1] = info({ name = name, hunter = hunter }) end
                    return { get_field = function() return {
                        get_size = function() return #list end, get_element = function(_, i) return list[i + 1] end } end }
                end }
            end },
        ["app.DemoMediator"] = {},
        ["app.Net_Party"] = {},
        ["app.NetworkRequestManager"] = { call = function() end },
        ["app.MasterFieldManager"] = {},
        ["app.PlayerManager"] = { call = function(_, k)
            if k == "getMasterPlayer" then return { call = function() return P.hunter_obj end } end
        end },
        ["app.GUIManager"] = { get_field = function(_, f)
            if f ~= "_AllGUI" then return nil end
            return { get_size = function() return #P.guis end, get_element = function(_, i)
                local name = P.guis[i + 1]
                return { get_type_definition = function() return tdef(name) end }
            end }
        end },
        ["app.GameMiniEventManager"] = { call = function(_, k) if k == "get_FastTravel" then return P.ft end end },
    }
    P.stage = 1
    P.guis = { "app.GUI020011", "app.GUI000000" } -- open GUIs: the Link Party HUD, and a menu the tests "opened"
    P.warps = {}
    P.hunter_obj = { get_address = function() return "hunter-" .. steam_id end }
    P.ft_fields = {}
    P.ft = {
        get_field = function(_, f) return P.ft_fields[f] end,
        call = function(_, sig, ...)
            if sig:find("^warpPlayer") then
                local a = { ... }
                P.warps[#P.warps + 1] = { stage = a[2], pos = a[3] }
                P.stage = a[2]
            end
        end,
    }
    objects["app.mcFastTravel"] = P.ft
    P.objects = objects

    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.os = { clock = function() return clock end, date = os.date, time = os.time }
    env.log = { info = function() end, warn = function(s) P.warnings[#P.warnings + 1] = s end }
    env.sdk = {
        PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 },
        find_type_definition = function(t)
            if P.on_render_thread then P.render_touches = P.render_touches + 1 end
            if not methods[t] then return (RAW_LAYOUT[t] and not NO_RAW) and tdef(t) or nil end
            local td = tdef(t)
            td.get_methods = function() return methods[t] end
            td.get_method = function(_, sig)
                local name, params = sig:match("^([^(]+)%((.*)%)$")
                for _, m in ipairs(methods[t]) do
                    if m.name == (name or sig) then
                        local ps = {}
                        for _, p in ipairs(m:get_param_types()) do ps[#ps + 1] = p:get_full_name() end
                        if not params or table.concat(ps, ", ") == params then return m end
                    end
                end
            end
            return td
        end,
        get_managed_singleton = function(t)
            if P.on_render_thread then P.render_touches = P.render_touches + 1 end
            return objects[t]
        end,
        hook = function(m, pre, post) P.hooks[m] = P.hooks[m] or {}; table.insert(P.hooks[m], { pre = pre, post = post }) end,
        to_ptr = function(v) return v end,
        to_int64 = function(v) if v == true then return 1 elseif not v then return 0 end return v end,
        to_managed_object = function(v) return v end,
        to_valuetype = function(v, t)
            if type(v) ~= "number" then return v end
            -- raw memory read: like REFramework's, a copy of the bytes at that address
            assert(t == "System.UInt64", "raw read as " .. tostring(t))
            return {
                read_qword = function(_, off) return P.read_mem(v + off, 8) end,
                read_dword = function(_, off) return P.read_mem(v + off, 4) end,
                read_short = function(_, off) local x = P.read_mem(v + off, 2); return x >= 0x8000 and x - 0x10000 or x end,
                read_byte = function(_, off) return P.read_mem(v + off, 1) end,
            }
        end,
        create_managed_string = function(s) return s end,
        create_delegate = function() if P.no_delegates then return nil end return {} end,
        create_instance = function(t)
            local o = { type = t, fields = {}, calls = {} }
            o.add_ref = function(self) return self end
            o.set_field = function(self, f, v) self.fields[f] = v end
            o.call = function(self, k, ...) self.calls[#self.calls + 1] = { k, ... } end
            return o
        end,
        get_tdb_version = function() return 81 end,
    }
    env.json = {
        load_file = function()
            if opts.fresh then return nil end
            return copy(opts.config or TEST_CONFIG)
        end,
        dump_file = function() return true end,
        dump_string = function(v) nstore = nstore + 1; store["#" .. nstore] = copy(v); return "#" .. nstore end,
        load_string = function(s) return copy(assert(store[s], "not json: " .. tostring(s))) end,
    }
    env.re = { on_frame = function(f) P.render_frames[#P.render_frames + 1] = f end, on_draw_ui = function() end,
        on_config_save = function() end,
        on_application_entry = function(name, f) P.entries[#P.entries + 1] = name; P.frames[#P.frames + 1] = f end }
    env.imgui = {}
    env.draw = { text = function() end }
    -- Like REFramework's, but calling a method on one is an error (in the real game it reads/writes out of bounds).
    env.ValueType = { new = function(td)
        local v = { td = td:get_full_name(), q = {} }
        function v:call(sig) error("method " .. sig .. " called on a value type made by the mod") end
        function v:read_qword(off) return self.q[off] or 0 end
        function v:write_qword(off, q)
            assert(off % 8 == 0 and off + 8 <= td:get_valuetype_size(), "write out of bounds at " .. off)
            self.q[off] = q
        end
        return v
    end }
    env.Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
    env.Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }
    env.seamless_net = {
        version = "1.1.0",
        available = function() return true, "ok" end,
        self_id = function() return steam_id end,
        friends = function(all)
            local out = {}
            for id in pairs(mail) do
                if id ~= steam_id then out[#out + 1] = { id = id, name = steam_names[id] or "friend", in_game = true, state = 1 } end
            end
            return out
        end,
        send = function(to, data) if not mail[to] then return false end table.insert(mail[to], { from = steam_id, data = data }) return true end,
        send_self = function() return false end,
        invite = function(to, connect) P.steam_invites = P.steam_invites or {}; P.steam_invites[#P.steam_invites + 1] = { to, connect } return true end,
        events = function() local e = P.steam_events or {}; P.steam_events = {}; return e end,
        trust = function(ids) P.trusted = ids return #ids end,
        poll = function() local q = mail[steam_id]; mail[steam_id] = {}; return q end,
        backup_saves = function() if P.backup_ok then P.backups = P.backups + 1 return true, "backup" end return false, "disk full" end,
    }
    local loaded = {}
    env.require = function(modname)
        if loaded[modname] == nil then
            local chunk = assert(loadfile(AUTORUN .. "/" .. modname:gsub("%.", "/") .. ".lua", "t", env))
            loaded[modname] = chunk()
        end
        return loaded[modname]
    end
    assert(loadfile(AUTORUN .. "/wilds_seamless_coop.lua", "t", env))()
    P.util, P.net, P.story = env.require("wilds_seamless_coop.util"), env.require("wilds_seamless_coop.net"),
        env.require("wilds_seamless_coop.features.story")
    P.cutscene, P.safety = env.require("wilds_seamless_coop.features.cutscene"), env.require("wilds_seamless_coop.features.safety")
    P.env_status = function() local l = env.require("wilds_seamless_coop.features.linked"); return l.auto_status end
    P.group, P.party_mod = env.require("wilds_seamless_coop.features.group"), env.require("wilds_seamless_coop.features.party")
    P.travel = env.require("wilds_seamless_coop.features.travel")
    P.game = env.require("wilds_seamless_coop.game")

    -- The game itself calls one of its routines (hooks run first, like in the real game).
    function P.game_calls(tname, mname, ...)
        for _, m in ipairs(methods[tname]) do
            if m.name == mname then return m:call(objects[tname] or {}, ...) end
        end
        error("no such fake method " .. mname)
    end
    function P.called(key) -- arguments of the last "original" call of key, removing the record
        for i = #P.calls, 1, -1 do
            if P.calls[i][1] == key then return table.remove(P.calls, i) end
        end
        return nil
    end
    function P.log_has(text)
        for _, line in ipairs(P.story.log) do if line:find(text, 1, true) then return true end end
        return false
    end
    return P
end

local players = {}
local function run(seconds)
    for _ = 1, math.floor(seconds / 0.25) do
        clock = clock + 0.25
        for _, p in ipairs(players) do
            for _, f in ipairs(p.frames) do f() end
            p.on_render_thread = true
            for _, f in ipairs(p.render_frames) do f() end
            p.on_render_thread = false
        end
    end
end

local passed = 0
local function check(cond, what)
    if not cond then error("FAILED: " .. what, 2) end
    passed = passed + 1
    print("ok   " .. what)
end

------------------------------------------------------------------------------------------------------------------------
local A = new_player("Leader", "100", "HA")
local B = new_player("Follower", "200", "HB")
local C = new_player("Stranger", "300", "HC") -- a Steam friend with the mod who is NOT in the Link Party
players = { A, B, C }
local party = { { name = "Leader", hunter = "HA" }, { name = "Follower", hunter = "HB" } }
A.party, B.party, C.party = party, party, { { name = "Stranger", hunter = "HC" } }
local LOAD = "app.MissionManager.reqLoadMission"

run(5)
check(A.net.peer_count() == 1 and B.net.peer_count() == 1, "Link Party members with the mod find each other")
check(A.net.peers["300"] == nil and C.net.peer_count() == 0, "a Steam friend outside the Link Party is not a partner")
check(A.net.contacts["300"] == nil and C.net.contacts["100"] == nil and C.net.contacts["200"] == nil,
    "friends who only play Wilds (not in your group or Link Party) get no messages")
check(A.safety.backup_status:find("backup") and A.backups == 1, "saves are backed up once at game start")
check(A.entries[1] == "LateUpdateBehavior" and #A.frames == 1, "the mod runs on the game's main thread (LateUpdateBehavior)")
check(A.render_touches == 0 and B.render_touches == 0, "nothing on the render thread (re.on_frame) touches the game")
A.member_reads = 0; run(10)
check(A.member_reads <= 2 * 10 + 2, "the game's member lists are read at most once a second per session (shared by all features)")
check(collectgarbage("isrunning") == false, "Lua's garbage collector only runs from the main-thread update")

-- Nobody leads yet.
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(not B.log_has("reqLoadMission"), "nothing is sent while nobody leads the story")
check(A.called(LOAD) ~= nil, "the leader's own game call is never blocked")

A.util.config.lead_story = true; run(4)
check(A.net.leader() == "self" and B.net.leader() == B.net.peers["100"], "both games agree on the leader")

-- Dry run (default).
check(B.util.config.story_sync == "dry", "story sync starts in dry run")
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.log_has("[dry run] would mirror reqLoadMission") and B.called(LOAD) == nil, "dry run logs the step and changes nothing")

-- On.
B.util.config.story_sync = "on"
clock = clock + 1000 -- the start backup is old by now
local before = B.backups
A.game_calls("app.MissionManager", "setEnableMissionDynamicFlag", 7, 3, true); run(1)
local c = B.called("app.MissionManager.setEnableMissionDynamicFlag")
check(c and c[2] == 7 and c[3] == 3 and c[4] == true, "story sync on: the follower's game takes the same step, same values")
check(B.backups == before + 1, "a fresh save backup is made before the first mirrored step")
A.calls = {}
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.called(LOAD) ~= nil and B.backups == before + 1, "further steps reuse the recent backup")
check(#A.calls == 1, "the mirrored step is not echoed back to the leader")
A.game_calls("app.MissionController", "setClearObjective", 7, 2, true); run(1)
check(B.called("app.MissionController.setClearObjective") ~= nil, "objective steps reach the mission's controller")
A.game_calls("app.MissionController", "setClearObjective", 9, 2, true); run(1)
check(B.called("app.MissionController.setClearObjective") == nil and B.log_has("mission not loaded here"), "a step for a mission the follower hasn't loaded is skipped")

-- Guards.
B.backup_ok = false; clock = clock + 1000
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.called(LOAD) == nil and B.log_has("save backup failed"), "no backup -> no mirroring")
B.backup_ok = true

B.progress = 250
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.called(LOAD) == nil and B.log_has("must be equal"), "a follower at a different story point is never touched")
B.progress = 300

B.in_quest = true
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.called(LOAD) == nil and B.log_has("you are in a quest"), "nothing is mirrored while the follower is in a quest")
B.in_quest = false
A.in_quest = true; A.calls = {}
A.game_calls("app.MissionManager", "reqLoadMission", 7); run(1)
check(B.called(LOAD) == nil, "the leader sends nothing from inside a quest")
A.in_quest = false

-- Hostile / broken messages from a real partner.
local function raw(msg) A.net.send("200", msg) run(1) end
raw({ t = "step", key = "app.SaveDataManager.requestSaveDataAutoSave", args = {}, progress = 300 })
raw({ t = "step", key = LOAD, args = { "x" }, progress = 300 })
raw({ t = "step", key = LOAD, args = {}, progress = 300 })
raw({ t = "step", key = "app.MissionManager.setEnableMissionDynamicFlag", args = { 7, 3, 1 }, progress = 300 })
raw({ t = "step", key = LOAD, progress = 300 })
check(#B.calls == 0, "unknown routines and malformed arguments are ignored")
C.util.config.lead_story = true
C.net.send("200", { t = "step", key = LOAD, args = { 7 }, progress = 300 }); run(4)
check(B.called(LOAD) == nil and B.net.leader() == B.net.peers["100"], "a non-party friend can neither lead nor send steps")
B.net.send("100", { t = "step", key = LOAD, args = { 7 }, progress = 300 }); run(1)
A.calls = {}
check(A.called(LOAD) == nil, "the leader never takes steps from a follower")

-- Two players tick "Lead the story": lowest Steam id wins everywhere.
B.util.config.lead_story = true; run(4)
check(A.net.leader() == "self" and B.net.leader() == B.net.peers["100"], "two leaders: both games still agree on one")
B.util.config.lead_story = false; run(4)

-- Cutscenes: start together.
local param = { get_field = function(_, f) return f == "<ID>k__BackingField" and 500 or nil end, add_ref = function() end, release = function() end }
A.net.peers["200"].next_mission, B.net.peers["100"].next_mission = nil, nil
A.calls, B.calls = {}, {}
local _, skipped = A.game_calls("app.DemoMediator", "requestPlay", param); run(1)
check(skipped and A.called("app.DemoMediator.requestPlay") == nil and A.cutscene.status:find("^waiting"), "a cutscene waits while the partner hasn't reached it")
_, skipped = B.game_calls("app.DemoMediator", "requestPlay", param)
check(not skipped, "the partner who arrives second starts at once")
run(1)
check(A.called("app.DemoMediator.requestPlay") ~= nil, "... and the waiting game starts it at the same moment")
A.game_calls("app.DemoMediator", "onPlayStartTimeline", 500); B.game_calls("app.DemoMediator", "onPlayStartTimeline", 500); run(1)

-- Skip together.
A.calls, B.calls = {}, {}
_, skipped = A.game_calls("app.DemoMediator", "requestSkip"); run(1)
check(skipped and A.cutscene.status == "skip vote 1/2" and A.called("app.DemoMediator.requestSkip") == nil, "one skip press is only a vote")
B.game_calls("app.DemoMediator", "requestSkip"); run(1)
check(A.called("app.DemoMediator.requestSkip") ~= nil and B.called("app.DemoMediator.requestSkip") ~= nil, "when both voted, both games skip")
A.game_calls("app.DemoMediator", "onPlayEndTimeline", 500); B.game_calls("app.DemoMediator", "onPlayEndTimeline", 500); run(1)

-- Timeout: partner never arrives.
local param2 = { get_field = function() return 501 end, add_ref = function() end, release = function() end }
A.calls = {}
A.game_calls("app.DemoMediator", "requestPlay", param2); run(29)
check(A.called("app.DemoMediator.requestPlay") == nil, "still waiting after 29 s")
run(3)
check(A.called("app.DemoMediator.requestPlay") ~= nil, "after 30 s the cutscene plays anyway (never stuck)")
A.game_calls("app.DemoMediator", "onPlayStartTimeline", 501)
A.calls = {}
_, skipped = A.game_calls("app.DemoMediator", "requestSkip")
check(not skipped, "watching alone: skip works immediately")
A.game_calls("app.DemoMediator", "onPlayEndTimeline", 501)

-- Cutscene sync off -> never held.
A.util.config.cutscene_sync = false
_, skipped = A.game_calls("app.DemoMediator", "requestPlay", param)
check(not skipped, "with shared cutscenes off nothing is held")
A.util.config.cutscene_sync = true

-- Tripwire.
B.game_calls("app.Net_SessionService", "reportCheatQuest", "guid"); run(1)
check(B.util.config.story_sync == "off" and B.safety.tripped ~= nil, "if the game's cheat check fires, story sync switches itself off")
check(B.called("app.Net_SessionService.reportCheatQuest") ~= nil, "... and the check itself is never blocked")

-- Environment Link: both in a field, not linked yet -> the lower Steam id sends the game's own invite by itself.
local SYNC_INVITE = "app.cGUINetworkRequest.reqLinkPartySyncInvite"
party[1].unsynced, party[2].unsynced = true, true
A.calls, B.calls = {}, {}
run(5)
local inv = A.called(SYNC_INVITE)
check(inv ~= nil and inv[2] ~= nil and inv[2].get_type_definition():get_full_name() == "app.GUI020011",
    "in a field together, the lower Steam id sends the game's own Environment Link invite (from the Link Party HUD)")
check(A.called("app.NetworkRequestManager.inviteLinkPartySync") == nil, "... never the raw network request")
check(B.called(SYNC_INVITE) == nil, "the other player waits instead of inviting at the same time")
run(25)
check(B.called(SYNC_INVITE) ~= nil, "... and invites after a delay if no invite arrived")
A.calls = {}; run(200)
local n_inv = 0
for _, c in ipairs(A.calls) do if c[1] == SYNC_INVITE then n_inv = n_inv + 1 end end
check(n_inv == 2, "at most 3 invites per area, 45 s apart (got " .. n_inv + 1 .. ")")
A.stage = 2; A.calls = {}; run(3)
check(A.called(SYNC_INVITE) ~= nil, "a new area allows new invites")
party[1].unsynced, party[2].unsynced = nil, nil
A.calls = {}; run(60)
check(A.called(SYNC_INVITE) == nil, "no invites once linked")

-- Partner leaves.
mail["200"] = nil; players = { A, C }; run(22)
check(A.net.peer_count() == 0, "a partner who goes silent is dropped after 20 s")
A.calls = {}
_, skipped = A.game_calls("app.DemoMediator", "requestPlay", param)
check(not skipped, "alone again: cutscenes are not held")

------------------------------------------------------------------------------------------------------------------------
-- 0.5: co-op group, permanent party, fast travel, outsiders
------------------------------------------------------------------------------------------------------------------------
mail["200"] = {}; players = { A, B, C }
run(5)
check(A.group.is_member("200") and B.group.is_member("100"), "two modded hunters in one Link Party join each other's group")
check(not A.group.is_member("300"), "a modded friend outside the Link Party is not added")

-- Invite a friend who is offline: the invite waits; their mod gets it when they start the game.
A.group.invite("400", "Dee")
check(A.steam_invites and A.steam_invites[1][1] == "400" and A.steam_invites[1][2]:find("wsc_group=100"), "a Steam chat invite carries your Steam id")
run(10)
check(A.group.pending_out["400"] ~= nil, "the invite stays pending while they are offline")
local D = new_player("Dee", "400", "HD"); D.party = { { name = "Dee", hunter = "HD" } }
players = { A, B, C, D }
run(8)
check(D.group.pending_in["100"] ~= nil, "their mod receives the invite once their game runs")
D.group.accept("100"); run(2)
check(A.group.is_member("400") and D.group.is_member("100"), "accepting puts both in each other's group")

-- Accepting the Steam chat invite (game running) works too.
local E = new_player("Eve", "500", "HE"); E.party = { { name = "Eve", hunter = "HE" } }
players = { A, B, C, D, E }
A.group.invite("500", "Eve"); run(1)
E.steam_events = { { kind = "join", from = "100", connect = "+wsc_group=100" } }
run(3)
check(E.group.is_member("100") and A.group.is_member("500"), "accepting the Steam chat invite joins the group")
E.group.leave(); run(2)
check(not A.group.is_member("500"), "leaving the group tells the others")
check(A.trusted ~= nil, "group members are trusted by the plugin (works without Steam presence)")

-- Only one side lists the other (B reinstalled, fresh config, not in a Link Party with A): B answers A's HELLO, so
-- the contact holds steadily instead of dropping between A's 15 s quiet HELLOs (live bug 2026-11-22).
A.party, B.party = { { name = "Leader", hunter = "HA" } }, { { name = "Follower", hunter = "HB" } }
B.util.config.group.members = {}
local steady = true
for _ = 1, 45 do
    run(1)
    if not (A.net.contacts["200"] and B.net.contacts["100"]) then steady = false end
end
check(steady, "a contact listed by only one side stays connected both ways")
A.party, B.party = party, party
run(3)
check(B.group.is_member("100"), "... and meeting in a Link Party puts them back in each other's group")

-- Outsiders.
A.util.outsiders = true
check(A.util.story_mode() == "off" and not A.util.on("follow_travel") and not A.util.on("cutscene_sync"),
    "Allow outsiders pauses story, cutscene and travel sync")
check(A.util.on("auto_follow"), "... but quest following still works")
A.util.outsiders = false
local X = { name = "Random", hunter = "HX" }
party[#party + 1] = X
run(18) -- grace period + the 2 s member cache
check(A.util.stranger == "Random" and A.util.story_mode() == "off", "a non-group hunter in the party pauses story sync")
table.remove(party); run(2)
check(A.util.stranger == nil and A.util.story_mode() ~= "off", "... and sync resumes when they leave")
-- Disconnect: A and B lose the Link Party. The game's invite window is only used after the mod has seen the game
-- open it by hand (session type, and that the game passes no callback).
local INV_WIN = "app.cGUINetworkRequest.reqLinqPartyInviteWindow"
A.friends = { "HB", "HD" }
A.party, B.party = { { name = "Leader", hunter = "HA" } }, { { name = "Follower", hunter = "HB" } }
A.calls, B.calls = {}, {}
run(8)
check(A.called(INV_WIN) == nil and A.party_mod.status:find("once from the game menu") ~= nil,
    "before you invite once by hand, the mod doesn't invite and says how to teach it")
A.game_calls("app.cGUINetworkRequest", "reqLinqPartyInviteWindow", { get_type_definition = function() return { get_full_name = function() return "app.GUI000000" end } end }, {}, 3, nil)
check(A.util.config.learned.party_invite and A.util.config.learned.party_invite.session == 3
    and A.util.config.learned.party_invite.action_null and A.util.config.learned.party_invite.gui == "app.GUI000000",
    "an invite made by hand teaches the session type and the GUI the game opens it from")
A.guis = { "app.GUI020011" }; A.calls = {}
run(8)
check(A.called(INV_WIN) == nil, "the invite window isn't opened while the GUI the game uses for it isn't open")
A.guis = { "app.GUI020011", "app.GUI000000" }
A.calls = {}
run(32)
local function invite_to(P, sid)
    for _, c in ipairs(P.calls) do
        if c[1] == INV_WIN and type(c[3]) == "table" and c[3].calls[1] and c[3].calls[1][2].sid == sid then return c end
    end
end
local pinv = invite_to(A, "SHB")
check(pinv ~= nil and pinv[3].type == "app.Net_MLUserInfo" and pinv[4] == 3 and pinv[5] == nil,
    "after a disconnect the group member is re-invited with the game's invite window")
check(pinv[3].calls[1][1]:find("Net_SocialUserInfoWithStatus") ~= nil, "... built from your Hunter Friends list entry")
check(B.called(INV_WIN) == nil, "only one side invites")
B.util.config.learned.party_invite = { session = 3, action_null = true, gui = "app.GUI000000" }
A.can_invite = false; A.calls = {}
run(40)
check(invite_to(A, "SHB") == nil and A.party_mod.status:find("won't invite") ~= nil, "nothing is sent when the game says the invite isn't possible (offline)")
A.can_invite = nil
A.util.config.learned.party_invite = { session = 3, action_null = false, gui = "app.GUI000000" }
A.calls = {}; run(40)
check(invite_to(A, "SHB") == nil and invite_to(A, "SHD") == nil, "if the game passes a callback itself, the mod never invites")
A.util.config.learned.party_invite = { session = 3, action_null = true, gui = "app.GUI000000" }
A.party, B.party = party, party
run(4)

-- Leaving the Link Party yourself pauses the rebuilding.
B.party = { { name = "Follower", hunter = "HB" } }
B.game_calls("app.NetworkRequestManager", "leaveSession", 3); run(1)
A.party = { { name = "Leader", hunter = "HA" } }
A.calls = {}; run(60)
check(invite_to(A, "SHB") == nil, "someone who left by hand is not chased with invites")
A.party, B.party = party, party
run(4)

-- Fast travel: A travels; B would join A's area over Environment Link, but that request needs a callback the mod
-- can't make, so it is refused (until it moves onto a game menu request). The warp replay is gone since 0.5.2.
local JOIN = "app.Net_Party.app.NetworkRequestManager.INet_LinkParty.joinPartySync"
A.ft_fields = { _WarpPosition = { x = 10, y = 2, z = 30 }, _CharacterRotation = { x = 0, y = 0.7, z = 0, w = 0.7 }, _TargetStage = 12 }
B.calls = {}; B.warnings = {}
A.game_calls("app.mcFastTravel", "warpPlayer", A.hunter_obj, 12, { x = 10, y = 2, z = 30 }, { x = 0, y = 0.7, z = 0, w = 0.7 }, nil, nil)
run(3)
local refused = false
for _, w in ipairs(B.warnings) do if w:find("no callback") then refused = true end end
check(B.called(JOIN) == nil and refused, "a fast travel follow that needs a callback is refused, not sent with null")
check(#B.warps == 0 and #A.warps == 0, "... and the warp itself is never replayed")

------------------------------------------------------------------------------------------------------------------------
-- 0.5.2: safe by default
------------------------------------------------------------------------------------------------------------------------
local F = new_player("Fresh", "060", "HF", { fresh = true })
local all_off = true
for _, t in ipairs(F.util.EXPERIMENTAL) do if F.util.config[t[1]] then all_off = false end end
check(all_off and F.util.config.story_sync == "off", "a new install starts with every experimental feature off")
check(F.util.config.auto_link == true, "... with the live-tested auto Environment Link invite on (0.5.5)")
check(next(F.hooks) == nil, "... and doesn't hook the game at all")
F.util.config.relink_after_hunt = true
check(not F.util.on("relink_after_hunt") and not F.util.at_start("relink_after_hunt"), "switching a feature on during play waits for the next game start")

local O = new_player("Old", "070", "HO", { config = { auto_link = true, auto_party = true, lead_story = true, story_sync = "on",
    travel_mode = "warp", group = { members = { ["100"] = { name = "Leader" } } } } })
check(O.util.config.auto_link and not O.util.config.auto_party and not O.util.config.lead_story
    and O.util.config.story_sync == "off" and O.util.migrated, "settings from 0.5.1 are reset to the safe defaults once (auto Environment Link on since 0.5.5)")
check(O.util.config.group.members["100"] ~= nil, "... keeping the co-op group")
check(next(O.hooks) == nil, "... and the game isn't hooked")
local V = new_player("V2", "075", "HV", { config = { config_version = 2, auto_link = false, cutscene_sync = true,
    story_sync = "dry" } })
check(V.util.config.auto_link and V.util.config.cutscene_sync and V.util.config.story_sync == "dry" and not V.util.migrated,
    "0.5.2-0.5.4 settings: auto Environment Link switched on once, the rest kept")

-- No game request is ever made with a null callback.
local H = new_player("Hal", "080", "HH")
local nrm_m
for _, m in ipairs(H.methods["app.NetworkRequestManager"]) do if m.name == "inviteLinkPartySync" then nrm_m = m end end
local ok_call, why = pcall(H.game.call, {}, nrm_m, { [1] = "HA", [2] = 5 })
check(not ok_call and tostring(why):find("no callback") and H.called("app.NetworkRequestManager.inviteLinkPartySync") == nil,
    "a request whose callback can't be made is refused, not sent with null")

-- Guid bytes as the game's own Guid constructor laid them out (read live 2026-11-21).
local SOME_ID = "d6cf33c0-8c20-4955-a0e1-822224e2a2eb"
local g = H.game.guid(SOME_ID)
check(g and g.q[0] == 0x49558c20d6cf33c0 and g.q[8] == string.unpack("<i8", string.pack("<I8", 0xeba2e2242282e1a0))
    and H.game.ptr_guid(g) == SOME_ID, "a Guid is packed with the game's byte layout and read back")
check(H.game.guid_str(g) == SOME_ID, "... the same bytes as a Guid read from a game field")
local n = H.game.nullable_guid(SOME_ID)
check(n and n.q[0] == 1 and n.q[8] == g.q[0] and H.game.arg_nullable_guid(n) == SOME_ID
    and H.game.arg_nullable_guid(H.game.nullable_guid(nil)) == "none" and H.game.guid("not a guid") == nil,
    "a Nullable<Guid> is packed (flag at 0, Guid at 8) and read back; bad ids are refused")

-- 0.5.5: member lists are read as raw memory (wrapping the game's network objects crashed joins), with the old
-- wrapped read only as a fallback.
local function hid(h) return H.game.guid_str({ read_qword = function(_, off) return off == 0 and guid_no(h) or 0 end }) end
local function warned(P, text)
    for _, w in ipairs(P.warnings) do if w:find(text, 1, true) then return true end end
    return false
end
local R = new_player("Rita", "090", "HR")
R.party = { { name = "Rita", hunter = "HR" }, { name = "Dée", hunter = "HD", unsynced = true } }
R.raw_reads = 0
local rl = R.game.members(R.game.SESSION.LINK(), true)
check(R.raw_reads > 0 and #rl == 2 and rl[1].name == "Rita" and rl[1].is_self and rl[1].is_sync
    and rl[2].name == "Dée" and not rl[2].is_self and not rl[2].is_sync and rl[2].hunter_id == hid("HD")
    and rl[2].user_id == hid("UHD") and rl[2].progress == 300 and rl[2].online_id == "Dée_steam"
    and not warned(R, "member lists"), "member lists are read from raw memory (names, ids, flags), no game object wrapped")
local card = R.game.self_card()
check(card and card.HunterId == hid("HR") and card.UserId == hid("UHR") and card.HunterName == "Rita"
    and card.ShortHunterId == "SHR" and card.Hr == 50 and card.PlatformId == 5,
    "... my own card comes from the same raw read (no conv2BlockUserInfo object)")
local W = new_player("Wes", "091", "HW")
W.party = { { name = "Wes", hunter = "HW" }, { name = "Dée", hunter = "HD", unsynced = true } }
W.raw_reads = 0
NO_RAW = true -- the mod looks the fields up on its first read
local wl = W.game.members(W.game.SESSION.LINK(), true)
NO_RAW = false
check(W.raw_reads == 0 and #wl == 2 and wl[1].is_self and wl[2].name == "Dée" and wl[2].hunter_id == rl[2].hunter_id
    and wl[2].is_sync == rl[2].is_sync and warned(W, "member lists"),
    "... and when a game patch renames those fields, the old wrapped read takes over (with a warning)")

print(string.format("\nALL %d CHECKS PASSED", passed))
