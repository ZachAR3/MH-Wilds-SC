-- Environment Link (the game's "party sync"): keep Link Party members in one shared field.
--   stay_linked       - when a story event starts, the game leaves sync (PARTY_SYNC_OPTION.LEAVE_StoryEvent); skip that.
--   link_in_story     - allow sync in the current stage during story missions, once the game has unlocked
--                       Environment Link for this save (party-sync progress > 0, after mission 001075),
--                       or from the start with early unlock (features/unlock.lua).
--   auto_accept_link  - accept Environment Link invites from Link Party members.
--   auto_link         - in a field together, send the Environment Link invite yourself (to Link Party members running
--                       this mod; the one with the lower Steam id sends first, the other follows after a delay).
--   relink_after_hunt - the game ends sync when a hunt ends; re-send the invites you had sent, using the same request.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")
local unlock = require("wilds_seamless_coop.features.unlock")
local net = require("wilds_seamless_coop.net")

local linked = { status = "", auto_status = "" }

local skipped = false
local sync_unlocked, sync_checked_at = false, -1
local sent_invites = {}     -- [guid string] = values the game passed to inviteLinkPartySync for that hunter
local partners = nil        -- members you were linked with when the hunt began
local relink_at, accept_at, invite_at = nil, 0, 0

local function synced_partners()
    local out = {}
    for _, m in ipairs(game.members(game.SESSION.LINK())) do
        if m.is_sync and not m.is_self then out[#out + 1] = m end
    end
    return out
end

------------------------------------------------------------------------------------------------------------------------
-- stay_linked
------------------------------------------------------------------------------------------------------------------------

local function on_leave_sync(args, m)
    if not util.on("stay_linked") then return end
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name():match("PARTY_SYNC_OPTION$") then
            local story_event = game.enum(td:get_full_name(), "LEAVE_StoryEvent", 1)
            if game.arg_int(args, i) == story_event and #synced_partners() > 0 then
                skipped = true
                util.info("story event: staying in Environment Link")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            return
        end
    end
end

local function after_leave_sync(retval, m)
    if not skipped then return retval end
    skipped = false
    if game.returns_bool(m) then return game.TRUE end
    return retval
end

------------------------------------------------------------------------------------------------------------------------
-- link_in_story
------------------------------------------------------------------------------------------------------------------------

local function after_can_sync_here(retval, m)
    if not util.on("link_in_story") or not game.returns_bool(m) then return retval end
    if util.now() - sync_checked_at > 5 then
        sync_checked_at = util.now()
        sync_unlocked = (tonumber(game.party_sync_progress()) or 0) > 0
    end
    if sync_unlocked or unlock.link_overridden() then return game.TRUE end
    return retval
end

------------------------------------------------------------------------------------------------------------------------
-- auto_accept_link
------------------------------------------------------------------------------------------------------------------------

-- Which id of a hunter the game passes when accepting ("hunter" or "user"), learned from an accept made by hand.
local function learn_accept(args, m)
    if recorder.mine then return end
    local guid
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name() == "System.Guid" then guid = game.arg_guid(args, i) end
    end
    for _, mem in ipairs(game.members(game.SESSION.LINK())) do
        if guid and guid == mem.hunter_id then util.config.learned.link_id = "hunter" end
        if guid and guid == mem.user_id then util.config.learned.link_id = "user" end
    end
end

-- The Link Party member who sent an Environment Link invite (app.Net_Party.InvitedLinkParty), or nil.
local function inviter(invite)
    local user = invite:get_field("_User")
    if user == nil then return nil end
    local ids = {}
    for _, getter in ipairs({ "get_HunterId", "get_UserId" }) do
        local ok, g = pcall(user.call, user, getter)
        if ok and g then ids[game.guid_str(g) or ""] = true end
    end
    for _, mem in ipairs(game.members(game.SESSION.LINK())) do
        if not mem.is_self and (ids[mem.hunter_id or "-"] or ids[mem.user_id or "-"]) then return mem end
    end
    return nil
end

-- Accept a pending Environment Link invite from a Link Party member, the way the game's own accept does:
-- NetworkRequestManager.acceptInviteLinkPartySync(inviter id, callback, invite password, flag).
local function accept_link_invite()
    local kind = util.config.learned.link_id
    if not kind then return end -- accept one invite by hand first, so the mod knows which id the game uses
    local has = game.method("app.cGUINetworkRequest", "hasInvitationPartySync", 0)
    local party, nrm = game.party(), game.request_manager()
    if not (has and party and nrm) or has:call(nil) ~= true then return end

    local list = party:call("get_InvitedSyncList")
    local count = list and list:call("get_Count") or 0
    for i = 0, count - 1 do
        local invite = list:call("get_Item(System.Int32)", i)
        local from = invite and inviter(invite)
        if from then
            local m = game.method("app.NetworkRequestManager", "acceptInviteLinkPartySync")
            if not m then return end
            local values = recorder.values("app.NetworkRequestManager.acceptInviteLinkPartySync")
            for j, td in ipairs(m:get_param_types() or {}) do
                local t = td:get_full_name()
                if t == "System.Guid" then values[j] = kind == "user" and from.user_id or from.hunter_id end
                if t == "System.String" then values[j] = invite:get_field("_Password") end
            end
            if util.try("accept Environment Link invite", recorder.call, nrm, m, values) then
                util.info("accepted Environment Link invite from " .. from.name)
            end
            accept_at = util.now() + 10
            return
        end
    end
end

------------------------------------------------------------------------------------------------------------------------
-- relink_after_hunt
------------------------------------------------------------------------------------------------------------------------

-- Remember every Environment Link invite the game sends for you, keyed by the invited hunter's id.
local function on_invite_sync(args, m)
    if recorder.mine then return end
    local values, guid = {}, nil
    for i, td in ipairs(m:get_param_types() or {}) do
        local t = td:get_full_name()
        if t == "System.Guid" then
            guid = game.arg_guid(args, i)
            values[i] = guid
        elseif t == "System.Boolean" then
            values[i] = game.arg_bool(args, i)
        elseif td:is_value_type() then
            values[i] = game.arg_int(args, i)
        end
    end
    if guid then
        sent_invites[guid] = values
        for _, mem in ipairs(game.members(game.SESSION.LINK())) do
            if guid == mem.hunter_id then util.config.learned.invite_id = "hunter" end
            if guid == mem.user_id then util.config.learned.invite_id = "user" end
        end
    end
end

local function on_hunt_start()
    partners = synced_partners()
end

local function on_hunt_sync_end()
    if util.on("relink_after_hunt") and partners and #partners > 0 then
        relink_at = util.now() + 5
    end
end

local function relink()
    local nrm = game.request_manager()
    local m = game.method("app.NetworkRequestManager", "inviteLinkPartySync")
    if not (nrm and m) then return end
    local still = {}
    for _, p in ipairs(synced_partners()) do still[p.hunter_id] = true end
    for _, p in ipairs(partners) do
        local values = sent_invites[p.hunter_id] or sent_invites[p.user_id]
        if values and not still[p.hunter_id] then
            if util.try("re-link " .. p.name, recorder.call, nrm, m, values) then
                util.info("re-sent Environment Link invite to " .. p.name)
            end
        end
    end
end


------------------------------------------------------------------------------------------------------------------------
-- auto_link
------------------------------------------------------------------------------------------------------------------------

local INVITE_KEY = "app.NetworkRequestManager.inviteLinkPartySync"
local invite_log = {}   -- [hunter id] = { stage, at, tries }
local unlinked_since = nil
local STAGE_RETRY, FOLLOW_DELAY, MAX_TRIES = 20, 20, 6

local function auto_invite()
    local now = util.now()
    local want = {}
    for _, mem in ipairs(game.members(game.SESSION.LINK())) do
        if not mem.is_self and not mem.is_sync and net.peer_by_hunter(mem.hunter_id) then want[#want + 1] = mem end
    end
    if #want == 0 then
        unlinked_since = nil
        linked.auto_status = "nobody to invite"
        return
    end
    local mm = game.mission_manager()
    local can = mm and game.method("app.MissionManager", "getCanPartySyncInfoInCurrentStage", 0)
    if not can or can:call(mm) ~= true then
        unlinked_since = nil
        linked.auto_status = "waiting for a field stage that allows Environment Link"
        return
    end

    unlinked_since = unlinked_since or now

    local stage = game.current_stage() or recorder.values(INVITE_KEY)[2]
    local nrm = game.request_manager()
    local m = game.method("app.NetworkRequestManager", "inviteLinkPartySync")
    if not (stage and nrm and m) then
        linked.auto_status = "stage unknown; invite once by hand so the mod can learn it"
        return
    end

    local p = rawget(_G, "seamless_net")
    local self_id = tostring(p and p.self_id() or "")
    for _, mem in ipairs(want) do
        local peer = net.peer_by_hunter(mem.hunter_id)
        -- the lower Steam id invites at once; the other waits, in case the first invite didn't get through
        local my_turn = self_id ~= "" and self_id < tostring(peer.id)
        if my_turn or now - unlinked_since >= FOLLOW_DELAY then
            local log = invite_log[mem.hunter_id] or { stage = -1, at = -100, tries = 0 }
            if log.stage ~= stage then log.tries = 0 end
            if now - log.at >= STAGE_RETRY and log.tries < MAX_TRIES then
                local kind = util.config.learned.invite_id
                if not kind then kind = (log.tries % 2 == 0) and "hunter" or "user" end
                local id = kind == "user" and mem.user_id or mem.hunter_id
                if game.guid_valid(id) then
                    if util.try("auto Environment Link invite", recorder.call, nrm, m,
                            recorder.values(INVITE_KEY, { [1] = id, [2] = stage })) then
                        util.info(string.format("sent Environment Link invite to %s (stage %s, %s id)", mem.name,
                            tostring(stage), kind))
                    end
                end
                log.stage, log.at, log.tries = stage, now, log.tries + 1
                invite_log[mem.hunter_id] = log
            end
            linked.auto_status = string.format("invited %s (try %d)", mem.name, log.tries)
        else
            linked.auto_status = "waiting for " .. mem.name .. " to invite"
        end
    end
end

------------------------------------------------------------------------------------------------------------------------

function linked.update()
    local now = util.now()
    local in_quest = game.in_session(game.SESSION.QUEST())

    if relink_at and now >= relink_at then
        if in_quest then
            relink_at = now + 3 -- still on the results screen / travelling back
        else
            relink_at = nil
            relink()
            partners = nil
        end
    end

    if util.on("auto_accept_link") and not in_quest and now >= accept_at then
        accept_at = now + 1
        accept_link_invite()
    end

    if util.on("auto_link") and not in_quest and now >= (invite_at or 0) then
        invite_at = now + 2
        util.try("auto link", auto_invite)
    end

    local n = #synced_partners()
    linked.status = n > 0 and ("linked with " .. n .. " hunter(s)") or "not linked"
end

function linked.init()
    -- Skipped at the Net_Party level (the routine that really leaves); the request wrapper above it still runs and
    -- answers its caller, so nothing waits for a callback that never comes.
    game.hook("app.Net_Party", "app.NetworkRequestManager.INet_LinkParty.leaveLinkPartySync", on_leave_sync, after_leave_sync)
    game.hook("app.NetworkRequestManager", "acceptInviteLinkPartySync", learn_accept)
    game.hook("app.MissionManager", "getCanPartySyncInfoInCurrentStage", nil, after_can_sync_here)
    game.hook("app.NetworkRequestManager", "inviteLinkPartySync", on_invite_sync)
    game.hook("app.cQuestDirector", "acceptQuest", on_hunt_start)
    game.hook("app.Net_Party", "onLeaveLinkPartySync", nil, function(retval)
        on_hunt_sync_end()
        return retval
    end)
end

return linked
