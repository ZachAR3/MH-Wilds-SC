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
local ENUM_FIELDS = { ["app.NETWORK_ERROR_CODE"] = { { "NONE", 0 }, { "ERR_STORY", 3 }, { "ERR_JOIN_REJECT", 7 } } }
local function tdef(name)
    local fields = {}
    for _, f in ipairs(ENUM_FIELDS[name] or {}) do
        fields[#fields + 1] = { get_name = function() return f[1] end, is_static = function() return true end,
            get_data = function() return f[2] end }
    end
    return { get_full_name = function() return name end, is_value_type = function() return VALUE[name] == true end,
        get_methods = function() return {} end, get_fields = function() return fields end, get_field = function() return nil end }
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
local TEST_CONFIG = { config_version = 2, story_sync = "dry", auto_link = true, auto_accept_link = true,
    relink_after_hunt = true, auto_follow = true, auto_party = true, follow_travel = true, stay_linked = true,
    cutscene_sync = true }

local function new_player(name, steam_id, hunter, opts)
    opts = opts or {}
    steam_names[steam_id] = name .. "_steam"
    local P = { name = name, id = steam_id, hunter = hunter, progress = 300, in_quest = false, party = {},
        calls = {}, hooks = {}, backups = 0, backup_ok = true, warnings = {}, frames = {} }
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
            local args = { "ctx", obj, ... }
            local skip = false
            for _, h in ipairs(P.hooks[m] or {}) do
                if h.pre and h.pre(args) == 1 then skip = true end
            end
            -- (pure getters are not "calls": they change nothing)
            if not skip and def[1] ~= "get_CurrentStage" and def[1] ~= "Parse" then P.calls[#P.calls + 1] = { tname .. "." .. def[1], ... } end
            local ret = nil
            if def[1] == "getCanPartySyncInfoInCurrentStage" then ret = true end
            if def[1] == "get_CurrentStage" then ret = P.stage end
            if def[1] == "Parse" then local str = ...; ret = { call = function() return str end } end
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
        local function guid(str) return { call = function() return str end } end
        local card = { HunterId = guid(m.hunter), UserId = guid("U" .. m.hunter), HunterName = m.name, PlatformId = 5,
            UniqueId = "uid-" .. m.hunter, ShortHunterId = "S" .. m.hunter, Hr = 50 }
        local v = { get_IsValid = true, get_PlName = m.name, get_HunterId = guid(m.hunter), get_UserId = guid("U" .. m.hunter),
            get_IsSelf = m.hunter == hunter, get_IsPartySync = m.unsynced ~= true, get_MemberListProgressId = 300,
            get_OnlineId = m.name .. "_steam", conv2BlockUserInfo = { get_field = function(_, f) return card[f] end } }
        return { call = function(_, k) return v[k] end }
    end
    local controller = { call = function() end }
    local objects = {
        ["app.MissionManager"] = { call = function(_, k, a)
            if k == "getProgressId" then return P.progress end
            if k == "getPartySyncProgressId" then return 150 end
            if k == "getEnableMissionController" then return a == 7 and controller or nil end
        end },
        ["app.NetworkManager"] = {
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
        ["app.GameMiniEventManager"] = { call = function(_, k) if k == "get_FastTravel" then return P.ft end end },
    }
    P.stage = 1
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
            if not methods[t] then return nil end
            local td = tdef(t)
            td.get_methods = function() return methods[t] end
            return td
        end,
        get_managed_singleton = function(t) return objects[t] end,
        hook = function(m, pre, post) P.hooks[m] = P.hooks[m] or {}; table.insert(P.hooks[m], { pre = pre, post = post }) end,
        to_ptr = function(v) return v end,
        to_int64 = function(v) if v == true then return 1 elseif not v then return 0 end return v end,
        to_managed_object = function(v) return v end,
        to_valuetype = function(v) return v end,
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
    env.re = { on_frame = function(f) P.frames[#P.frames + 1] = f end, on_draw_ui = function() end, on_config_save = function() end }
    env.imgui = {}
    env.draw = { text = function() end }
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
        for _, p in ipairs(players) do for _, f in ipairs(p.frames) do f() end end
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

-- Environment Link: both in a field, not linked yet -> the lower Steam id sends the invite by itself.
A.util.config.learned["app.NetworkRequestManager.inviteLinkPartySync"] = { [2] = 5 }
B.util.config.learned["app.NetworkRequestManager.inviteLinkPartySync"] = { [2] = 5 }
party[1].unsynced, party[2].unsynced = true, true
A.calls, B.calls = {}, {}
run(5)
local inv = A.called("app.NetworkRequestManager.inviteLinkPartySync")
check(inv ~= nil, "in a field together, the lower Steam id sends the Environment Link invite itself")
check(B.called("app.NetworkRequestManager.inviteLinkPartySync") == nil, "the other player waits instead of inviting at the same time")
run(25)
check(B.called("app.NetworkRequestManager.inviteLinkPartySync") ~= nil, "... and invites after a delay if no invite arrived")
party[1].unsynced, party[2].unsynced = nil, nil
A.calls = {}; run(25)
check(A.called("app.NetworkRequestManager.inviteLinkPartySync") == nil, "no invites once linked")

-- Partner leaves.
mail["200"] = nil; players = { A, C }; run(14)
check(A.net.peer_count() == 0, "a partner who goes silent is dropped after 12 s")
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

-- Outsiders.
A.util.outsiders = true
check(A.util.story_mode() == "off" and not A.util.on("follow_travel") and not A.util.on("cutscene_sync"),
    "Allow outsiders pauses story, cutscene and travel sync")
check(A.util.on("auto_follow"), "... but quest following still works")
A.util.outsiders = false
local X = { name = "Random", hunter = "HX" }
party[#party + 1] = X
run(16)
check(A.util.stranger == "Random" and A.util.story_mode() == "off", "a non-group hunter in the party pauses story sync")
table.remove(party); run(2)
check(A.util.stranger == nil and A.util.story_mode() ~= "off", "... and sync resumes when they leave")
-- Disconnect: A and B lose the Link Party; the lower Steam id re-invites, the other accepts.
A.party, B.party = { { name = "Leader", hunter = "HA" } }, { { name = "Follower", hunter = "HB" } }
A.calls, B.calls = {}, {}
run(8)
local pinv = A.called("app.NetworkRequestManager.inviteLinkParty")
check(pinv ~= nil and type(pinv[3]) == "table" and pinv[3].type == "app.Net_MLUserInfo", "after a disconnect the group is re-invited to the Link Party")
check(B.called("app.NetworkRequestManager.inviteLinkParty") == nil, "only one side invites")
check(B.called("app.NetworkRequestManager.acceptInviteLinkParty") ~= nil, "the invited member accepts automatically")
A.party, B.party = party, party
run(4)

-- REFramework can't build the invite request's callback (the 0.5.0 freeze): never invite or accept then.
local G = new_player("Gil", "050", "HG"); G.no_delegates = true; G.party = { { name = "Gil", hunter = "HG" } }
players[#players + 1] = G
G.util.config.group.members["200"] = { name = "Follower", hunter = "HB" }
B.util.config.group.members["050"] = { name = "Gil", hunter = "HG" }
B.calls = {}
run(40)
check(G.called("app.NetworkRequestManager.inviteLinkParty") == nil and G.called("app.NetworkRequestManager.acceptInviteLinkParty") == nil,
    "no Link Party requests when the game's callback can't be made")
check(G.party_mod.status:find("unavailable") ~= nil, "... and the panel says automatic rebuilding is unavailable")
table.remove(players)
B.util.config.group.members["050"] = nil

-- Leaving the Link Party yourself pauses the rebuilding.
B.party = { { name = "Follower", hunter = "HB" } }
B.game_calls("app.NetworkRequestManager", "leaveSession", 3); run(1)
A.party = { { name = "Leader", hunter = "HA" } }
A.calls = {}; run(60)
local chased = false
for _, c in ipairs(A.calls) do
    if c[1] == "app.NetworkRequestManager.inviteLinkParty" and type(c[3]) == "table" and c[3].calls and c[3].calls[1] then
        local f = c[3].calls[1][2].fields
        if f.HunterId and f.HunterId:call() == "HB" then chased = true end
    end
end
check(not chased, "someone who left by hand is not chased with invites")
A.party, B.party = party, party
run(4)

-- Fast travel: A travels, B joins A's area over Environment Link (the warp replay is gone since 0.5.2).
local JOIN = "app.Net_Party.app.NetworkRequestManager.INet_LinkParty.joinPartySync"
A.ft_fields = { _WarpPosition = { x = 10, y = 2, z = 30 }, _CharacterRotation = { x = 0, y = 0.7, z = 0, w = 0.7 }, _TargetStage = 12 }
B.calls = {}
A.game_calls("app.mcFastTravel", "warpPlayer", A.hunter_obj, 12, { x = 10, y = 2, z = 30 }, { x = 0, y = 0.7, z = 0, w = 0.7 }, nil, nil)
run(3)
local join = B.called(JOIN)
check(join ~= nil and join[2]:call() == "HA", "a fast travel makes the group member join the mover's area")
check(#B.warps == 0 and #A.warps == 0, "... without replaying the warp itself")
B.in_quest = true
A.game_calls("app.mcFastTravel", "warpPlayer", A.hunter_obj, 13, { x = 1, y = 1, z = 1 }, { x = 0, y = 0, z = 0, w = 1 }, nil, nil)
A.ft_fields._TargetStage = 13
run(3)
check(B.called(JOIN) == nil, "nobody is pulled out of a quest")
B.in_quest = false; run(3)
check(B.called(JOIN) ~= nil, "... they follow once the quest is over")
B.util.outsiders = true
A.game_calls("app.mcFastTravel", "warpPlayer", A.hunter_obj, 14, { x = 1, y = 1, z = 1 }, { x = 0, y = 0, z = 0, w = 1 }, nil, nil)
run(3)
check(B.called(JOIN) == nil, "no travel follow while outsiders are allowed")
B.util.outsiders = false

------------------------------------------------------------------------------------------------------------------------
-- 0.5.2: safe by default
------------------------------------------------------------------------------------------------------------------------
local F = new_player("Fresh", "060", "HF", { fresh = true })
local all_off = true
for _, t in ipairs(F.util.EXPERIMENTAL) do if F.util.config[t[1]] then all_off = false end end
check(all_off and F.util.config.story_sync == "off", "a new install starts with every experimental feature off")
check(next(F.hooks) == nil, "... and doesn't hook the game at all")
F.util.config.auto_link = true
check(not F.util.on("auto_link") and not F.util.at_start("auto_link"), "switching a feature on during play waits for the next game start")

local O = new_player("Old", "070", "HO", { config = { auto_link = true, auto_party = true, lead_story = true, story_sync = "on",
    travel_mode = "warp", group = { members = { ["100"] = { name = "Leader" } } } } })
check(not O.util.config.auto_link and not O.util.config.auto_party and not O.util.config.lead_story
    and O.util.config.story_sync == "off" and O.util.migrated, "settings from 0.5.1 are reset to the safe defaults once")
check(O.util.config.group.members["100"] ~= nil, "... keeping the co-op group")
check(next(O.hooks) == nil, "... and the game isn't hooked")

-- No game request is ever made with a null callback.
local H = new_player("Hal", "080", "HH"); H.no_delegates = true
local nrm_m
for _, m in ipairs(H.methods["app.NetworkRequestManager"]) do if m.name == "inviteLinkPartySync" then nrm_m = m end end
local ok_call, why = pcall(H.game.call, {}, nrm_m, { [1] = "HA", [2] = 5 })
check(not ok_call and tostring(why):find("no callback") and H.called("app.NetworkRequestManager.inviteLinkPartySync") == nil,
    "a request whose callback can't be made is refused, not sent with null")

print(string.format("\nALL %d CHECKS PASSED", passed))
