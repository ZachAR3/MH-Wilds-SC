-- Self-test: checks everything the mod relies on against the running game and writes
-- reframework/data/wilds_seamless_coop/selftest.json. Read-only (apart from one save backup).
-- Runs from the panel (Diagnostics), or once ~20 s after start when config.selftest is true.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")
local story = require("wilds_seamless_coop.features.story")

local selftest = { summary = "not run" }

-- Game methods the mod calls directly (hooked methods are collected by game.hook itself).
local CALLED = {
    { "app.MissionManager", "getProgressId" }, { "app.MissionManager", "getPartySyncProgressId" },
    { "app.MissionManager", "getEnableMissionController" }, { "app.MissionUtil", "getExpectLoadMainMissionId" },
    { "app.NetworkManager", "get_UserInfoManager" }, { "app.Net_UserInfoManager", "getUserInfoList" },
    { "app.Net_UserInfo", "get_IsValid" }, { "app.Net_UserInfo", "get_IsSelf" }, { "app.Net_UserInfo", "get_HunterId" },
    { "app.Net_UserInfo", "get_UserId" }, { "app.Net_UserInfo", "get_PlName" }, { "app.Net_UserInfo", "get_IsPartySync" },
    { "app.Net_UserInfo", "get_MemberListProgressId" },
    { "app.NetworkRequestManager", "acceptInviteLinkPartyQuest" }, { "app.NetworkRequestManager", "acceptInviteLinkPartySync" },
    { "app.NetworkRequestManager", "inviteLinkPartySync" }, { "app.cGUINetworkRequest", "hasInvitationPartySync" },
    { "app.Net_Party", "get_InvitedSyncList" }, { "app.DemoMediator", "requestSkip" }, { "System.Guid", "Parse" },
}
local SINGLETONS = { "app.MissionManager", "app.NetworkManager", "app.NetworkRequestManager", "app.DemoMediator",
    "app.GUIManager", "app.SaveDataManager" }
local ENUMS = { "app.net_session_manager.SESSION_TYPE", "app.Net_Party.PARTY_SYNC_OPTION" }
-- Names looked up in the whole type database (needs seamless_net.dll): who really declares them?
local SCAN = {
    "isEnableOnlinePlay", "isEnableOnlineMenu", "isEnableLobby", "IsMultiplayerEnable", "isLinkNotStoryClear",
    "reqLoadMission", "requestSetActiveMission", "changeActiveManageMission", "forceActivateObjective",
    "clearQuestObjective", "setMissionDynamicFlag", "setDialogueSelectedIndex", "getEnableMissionController",
    "getExpectLoadMainMissionId", "requestPlay", "requestSkip", "execSkip", "onPlayStartTimeline", "onPlayEndTimeline",
    "leaveLinkPartySync", "inviteLinkPartySync", "acceptInviteLinkPartySync", "acceptInviteLinkPartyQuest",
    "addQuestInviteNotify", "isEnableJoinAcceptPartySync", "getCanPartySyncInfoInCurrentStage",
    "IsDrawReplicaPlFromProgress", "isProgressDrawOffSelfFromOthers", "getProgressId", "getPartySyncProgressId",
    "checkAndReportQuestCheat", "reportCheatQuest", "~PartySync", "~StoryClear", "~MultiplayEnable", "~MultiplayerEnable",
    "~OnlinePlay", "~MissionDynamicFlag", "~ActivateObjective", "~QuestObjective", "~ActiveMission", "~requestSave",
    "~Cheat", "~PartyHost", "~IsHost", "~Multiplay", "~isEnableOnline", "~EnableNetwork", "~StoryProgress",
    "~Invitation", "~InviteSync", "~Objective", "~DynamicFlag", "~MissionClear", "~clearMission", "~RequestManager",
    "~TimelineEvent", "~EventId", "~EventID", "~isSkip", "~SaveData",
    "@Net_UserInfo", "@Net_Party", "@NetworkRequestManager", "@cGUINetworkRequest", "@MenuUtil", "@MissionController",
    "@cStoryFsmController", "@DemoMediator", "@app.NetworkManager", "@app.MissionManager", "@MissionUtil",
    "@Net_SessionService", "@cQuestDirector", "@cSaveDataHelper_StoryParam", "@NetworkUtil",
}

local function signature(m)
    local rt = m:get_return_type()
    return string.format("%s%s %s(%s)", m:is_static() and "static " or "", rt and rt:get_full_name() or "void",
        m:get_name(), table.concat(game.param_types(m), ", "))
end

local function overloads(type_name, name)
    local out = {}
    local td = game.type(type_name, true)
    if not td then return nil end
    for _, m in ipairs(td:get_methods()) do
        if m:get_name() == name then out[#out + 1] = signature(m) end
    end
    return out
end

local FIELD_TYPES = { "app.MissionController", "ace.DemoMediatorBase.cParamBase", "app.Net_Party.InvitedLinkParty",
    "app.Net_Party.InvitedQuestInfo", "app.cStoryFsmController.DynamicFlag", "app.Net_UserInfoList", "app.NetworkManager",
    "app.MissionController.OBJECTIVE_STATE", "app.DemoMediator", "ace.DemoMediatorBase", "app.Net_Party" }

-- "type name" of every field of a type and its parents.
local function fields_of(type_name)
    local td = game.type(type_name, true)
    if not td then return "TYPE MISSING" end
    local out = { value_type = td:is_value_type() }
    while td do
        for _, f in ipairs(td:get_fields()) do
            local ft = f:get_type()
            out[#out + 1] = (f:is_static() and "static " or "") .. (ft and ft:get_full_name() or "?") .. " " .. f:get_name()
        end
        td = td:get_parent_type()
    end
    return out
end

local function enum_values(type_name)
    local td = game.type(type_name, true)
    if not td then return "TYPE MISSING" end
    local out = {}
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            out[f:get_name()] = ok and tostring(v) or "?"
        end
    end
    return out
end

function selftest.run()
    local out = { version = util.VERSION, missing = {}, methods = {}, singletons = {}, enums = {}, env = {} }
    local function miss(what) out.missing[#out.missing + 1] = what end

    out.env.tdb_version = sdk.get_tdb_version and sdk.get_tdb_version()
    for _, name in ipairs({ "os.clock", "os.date", "os.time", "json.dump_string", "json.load_string", "json.dump_file",
        "json.load_file", "imgui.combo", "imgui.tree_node", "draw.text", "sdk.to_valuetype", "sdk.to_ptr", "log.info" }) do
        local lib, fn = name:match("^(%w+)%.([%w_]+)$")
        local ok = type(rawget(_G, lib)) == "table" and rawget(_G, lib)[fn] ~= nil
        out.env[name] = ok
        if not ok then miss("lua " .. name) end
    end

    local wanted = {}
    for _, c in ipairs(CALLED) do wanted[#wanted + 1] = { c[1], c[2], "called" } end
    for _, h in ipairs(game.hook_requests) do wanted[#wanted + 1] = { h[1], h[2], "hooked" } end
    for _, w in ipairs(wanted) do
        local key = w[1] .. "." .. w[2]
        local list = overloads(w[1], w[2])
        if list == nil then
            miss(key .. " (type missing)")
        elseif #list == 0 then
            miss(key)
        end
        out.methods[key] = { use = w[3], overloads = list or "TYPE MISSING" }
    end
    for _, s in ipairs(SINGLETONS) do
        out.singletons[s] = sdk.get_managed_singleton(s) ~= nil
    end
    for _, e in ipairs(ENUMS) do out.enums[e] = enum_values(e) end

    local nm = game.network_manager()
    out.objects = { request_manager = game.request_manager() ~= nil, party = game.party() ~= nil,
        user_info_manager = nm ~= nil and nm:call("get_UserInfoManager") ~= nil }
    out.fields = {}
    for _, t in ipairs(FIELD_TYPES) do out.fields[t] = fields_of(t) end
    local mm = game.mission_manager()
    out.pack_host = mm and tostring(select(2, pcall(mm.call, mm, "get_IsPackHost")))
    out.state = {
        story_progress = tostring(game.story_progress()),
        party_sync_progress = tostring(game.party_sync_progress()),
        next_main_mission = tostring(game.next_main_mission()),
        link_members = #game.members(game.SESSION.LINK()),
        lobby_members = #game.members(game.SESSION.LOBBY()),
        quest_members = #game.members(game.SESSION.QUEST()),
        self_in_link = game.self_member(game.SESSION.LINK()) ~= nil,
    }

    local p = rawget(_G, "seamless_net")
    out.plugin = { loaded = p ~= nil }
    if p then
        local ok, reason = p.available()
        out.plugin.version, out.plugin.available, out.plugin.reason = p.version, ok, reason
        out.plugin.has_self_id = p.self_id() ~= nil
        out.plugin.friends_in_game = #p.friends()
        if p.backup_saves then
            local bok, where = p.backup_saves("selftest")
            out.plugin.backup = { ok = bok, result = where }
            if not bok then miss("save backup: " .. tostring(where)) end
        end

        if p.scan and util.config.selftest_scan then
            local by_name = {}
            for _, hit in ipairs(p.scan(SCAN)) do
                by_name[hit.method] = by_name[hit.method] or {}
                table.insert(by_name[hit.method], string.format("%s%s %s::%s(%s)", hit.static and "static " or "",
                    hit.ret, hit.type, hit.method, table.concat(hit.params, ", ")))
            end
            json.dump_file("wilds_seamless_coop/scan.json", by_name)
        end
        if not ok then miss("co-op link: " .. tostring(reason)) end
    else
        miss("seamless_net.dll not loaded")
    end

    selftest.out = out
    json.dump_file("wilds_seamless_coop/selftest.json", out)
    selftest.summary = #out.missing == 0 and "all checks passed"
        or (#out.missing .. " problem(s): " .. table.concat(out.missing, "; "))
    util.info("self-test: " .. selftest.summary)
    return out
end

------------------------------------------------------------------------------------------------------------------------
-- Ghost partner: our own messages, sent to ourselves through Steam, play the role of a leading co-op partner.
-- Exercises the real path (Steam send/receive -> session layer -> follower code -> the game's own lookups) without
-- a second player. Only runs with story sync in dry run, so nothing is ever changed.
------------------------------------------------------------------------------------------------------------------------

local ghost = nil -- { at, phase }

local function ghost_start()
    local p = rawget(_G, "seamless_net")
    if util.config.story_sync ~= "dry" or util.config.lead_story or not (p and p.send_self) then
        return "skipped (needs story sync = dry run, 'Lead the story' off, plugin 1.1.0+)"
    end
    net.ghost = true
    ghost = { at = util.now(), phase = 1 }
    return net.hello_self() and "running" or "FAILED: Steam refused the loopback message"
end

local function ghost_update()
    local p = rawget(_G, "seamless_net")
    local me, elapsed = p.self_id(), util.now() - ghost.at
    if ghost.phase == 1 and elapsed > 3 then
        ghost.phase = 2
        if not net.peers[me] then
            ghost.result = "FAILED: our own message never came back through Steam"
        else
            local mission = math.tointeger(tonumber(game.next_main_mission())) or 0
            local progress = game.story_progress()
            local function step(key, args, prog) net.send(me, { t = "step", key = key, args = args, progress = prog or progress }) end
            step("app.MissionManager.reqLoadMission", { mission })
            step("app.MissionManager.setEnableMissionDynamicFlag", { mission, 0, true })
            step("app.MissionController.setClearObjective", { mission, 0, true })
            step("app.MissionManager.reqLoadMission", { "not a number" })       -- must be ignored
            step("app.MissionManager.requestSaveDataAutoSave", { 1 })          -- not a story step: must be ignored
            step("app.MissionManager.reqLoadMission", { mission }, (tonumber(progress) or 0) + 1) -- wrong progress
            net.send(me, { t = "cut", id = 12345, phase = "ready" })
            net.send(me, { t = "vote", id = 12345 })
        end
    elseif ghost.phase == 2 and elapsed > 7 then
        ghost.phase = 3
        if not ghost.result then
            local dry, cant, refused, bad = 0, 0, 0, 0
            for _, line in ipairs(story.log) do
                if line:find("%[dry run%] would mirror") then dry = dry + 1 end
                if line:find("can't mirror") then cant = cant + 1 end
                if line:find("not mirrored: your story progress") then refused = refused + 1 end
                if line:find("mirrored ") and not line:find("would") and not line:find("not mirrored") then bad = bad + 1 end
            end
            local ok = dry + cant == 3 and dry >= 2 and refused == 1 and bad == 0
            ghost.result = string.format("%s: %d of 3 steps resolved in dry run, %d mission-not-loaded, wrong-progress "
                .. "step refused %d time(s), %d really applied (must be 0)", ok and "passed" or "FAILED", dry, cant, refused, bad)
        end
        net.peers[me] = nil
        net.ghost = false
        local out = selftest.out or {}
        out.ghost = { result = ghost.result, story_log = story.log }
        json.dump_file("wilds_seamless_coop/selftest.json", out)
        selftest.summary = selftest.summary .. " | ghost partner " .. ghost.result
        util.info("self-test ghost partner: " .. ghost.result)
        ghost = nil
    end
end

local started, done = nil, false
function selftest.run_all()
    selftest.run()
    selftest.summary = selftest.summary .. " | ghost partner " .. ghost_start()
end

-- A request file (reframework/data/wilds_seamless_coop/selftest_request.json, {"id": <anything new>}) starts a run
-- without touching the panel; used by automated tests.
local last_request, next_look = nil, 0
local function look_for_request()
    if not util.config.selftest_watch or util.now() < next_look then return end
    next_look = util.now() + 5
    local req = json.load_file("wilds_seamless_coop/selftest_request.json")
    local id = type(req) == "table" and tostring(req.id) or nil
    if last_request == nil then last_request = id or "" return end -- ignore a request left over from an earlier run
    if id and id ~= last_request then
        last_request = id
        util.try("self-test", selftest.run_all)
    end
end

function selftest.update()
    if ghost then util.try("self-test ghost", ghost_update) return end
    look_for_request()
    if done or not util.config.selftest then return end
    started = started or util.now()
    if util.now() - started < 20 then return end
    done = true
    util.try("self-test", selftest.run_all)
end

return selftest
