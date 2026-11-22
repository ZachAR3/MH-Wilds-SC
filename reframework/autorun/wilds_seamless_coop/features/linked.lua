-- Environment Link (the game's "party sync"): keep Link Party members in one shared field.
-- Everything goes through the game's own menu requests (app.cGUINetworkRequest), which make their own callbacks:
-- the mod can't create callbacks on this REFramework.
--   stay_linked       - when a story event starts, the game leaves sync (PARTY_SYNC_OPTION.LEAVE_StoryEvent); skip that.
--   auto_link         - in a field together, send the game's "invite Link Party to my environment" (to Link Party
--                       members running this mod; the lower Steam id sends first, the other follows after a delay).
--   relink_after_hunt - the game ends sync when a hunt ends; send that invite again.
-- Sending the invite was checked live on 2026-11-21 (the game shows "Invited all Link Members to your environment").
-- Accepting stays with the player (the game's notice, Y, then Yes): the join window only works from the Invitation
-- List GUI, which exists only while that menu is open, and opened from anywhere else it crashed the game (2026-11-22).
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")

local linked = { status = "", auto_status = "" }

local skipped = false
local partners = nil        -- members you were linked with when the hunt began
local relink_at, invite_at = nil, 0

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
-- Environment Link invites go through the game's own menu request, cGUINetworkRequest.reqLinkPartySyncInvite: it
-- invites every Link Party member, makes its own callbacks and shows the game's "Invited all Link Members to your
-- environment." window (checked live 2026-11-21). The old path (NetworkRequestManager.inviteLinkPartySync with a
-- null callback, and a Guid that came out all zero) never worked.
------------------------------------------------------------------------------------------------------------------------

local function invite_party(why)
    local ok = util.try(why, game.menu, "reqLinkPartySyncInvite")
    if ok then util.info(why .. ": invited your Link Party to your environment") end
    return ok
end

------------------------------------------------------------------------------------------------------------------------
-- relink_after_hunt
------------------------------------------------------------------------------------------------------------------------

local function on_hunt_start()
    partners = synced_partners()
end

local function on_hunt_sync_end()
    if util.on("relink_after_hunt") and partners and #partners > 0 then
        relink_at = util.now() + 5
    end
end

local function relink()
    local still = {}
    for _, p in ipairs(synced_partners()) do still[p.hunter_id] = true end
    for _, p in ipairs(partners) do
        if not still[p.hunter_id] then
            invite_party("re-link after the hunt")
            return
        end
    end
end

------------------------------------------------------------------------------------------------------------------------
-- auto_link: in a field together with Link Party members who run the mod, invite them to your environment.
-- The lower Steam id invites first; the other one only if nothing happened after FOLLOW_DELAY.
------------------------------------------------------------------------------------------------------------------------

local invite_log = { stage = -1, at = -1000, tries = 0 }
local unlinked_since = nil
local RETRY, FOLLOW_DELAY, MAX_TRIES = 45, 20, 3

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

    local peer = net.peer_by_hunter(want[1].hunter_id)
    local self_id = tostring(net.self_id() or "")
    local my_turn = self_id ~= "" and self_id < tostring(peer.id)
    if not my_turn and now - unlinked_since < FOLLOW_DELAY then
        linked.auto_status = "waiting for " .. want[1].name .. " to invite"
        return
    end
    local stage = game.current_stage() or -1
    if invite_log.stage ~= stage then invite_log = { stage = stage, at = -1000, tries = 0 } end
    if invite_log.tries >= MAX_TRIES then
        linked.auto_status = "gave up in this area after " .. MAX_TRIES .. " invites (invite from the game menu)"
        return
    end
    if now - invite_log.at < RETRY then return end
    invite_log.at, invite_log.tries = now, invite_log.tries + 1
    invite_party("auto Environment Link")
    linked.auto_status = string.format("invited your Link Party (try %d)", invite_log.tries)
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

    if util.on("auto_link") and not in_quest and now >= (invite_at or 0) then
        invite_at = now + 2
        util.try("auto link", auto_invite)
    end

    local n = #synced_partners()
    linked.status = n > 0 and ("linked with " .. n .. " hunter(s)") or "not linked"
end

function linked.init()
    -- Only the hooks of features that are on at game start are installed.
    -- Skipped at the Net_Party level (the routine that really leaves); the request wrapper above it still runs and
    -- answers its caller, so nothing waits for a callback that never comes.
    if util.at_start("stay_linked") then
        game.hook("app.Net_Party", "app.NetworkRequestManager.INet_LinkParty.leaveLinkPartySync", on_leave_sync,
            after_leave_sync)
    end
    if util.at_start("relink_after_hunt") then
        game.hook("app.cQuestDirector", "acceptQuest", on_hunt_start)
        game.hook("app.Net_Party", "onLeaveLinkPartySync", nil, function(retval)
            on_hunt_sync_end()
            return retval
        end)
    end
end

-- Panel button: invite your Link Party to your environment now (the game's own request; works without any setting).
function linked.invite_now()
    return invite_party("Environment Link invite")
end

return linked
