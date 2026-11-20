-- Auto-follow: when a Link Party member's quest invite arrives (story hunts included: the game sends it the moment
-- their hunt starts), accept it through the game's own accept request, exactly as pressing "Join" would.
-- Only the follower needs the mod for this part.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")

local follow = { status = "waiting for an invite" }

local KEY = "app.NetworkRequestManager.acceptInviteLinkPartyQuest"
local DELAY, RETRY, TRIES = 0.5, 2.0, 5

local pending -- { name, ids = { HunterId = guid, UserId = guid }, at, tries }

-- Which of the inviter's ids the accept request takes. Learned when you accept an invite by hand once;
-- until then both are tried, HunterId first.
local function id_order()
    local learned = util.config.learned.follow_id
    if learned == "UserId" then return { "UserId", "HunterId" } end
    return { "HunterId", "UserId" }
end

local function on_invite(args)
    if not util.on("auto_follow") then return end
    local m = game.member(game.arg_obj(args, 1))
    if not m or m.is_self then return end
    pending = {
        name = m.name,
        ids = { HunterId = m.hunter_id, UserId = m.user_id },
        at = util.now() + DELAY,
        tries = 0,
    }
    follow.status = "invite from " .. m.name
    util.info("quest invite from " .. m.name)
end

-- When you accept by hand, note which id the game passed so auto-accept uses the same one.
local function on_manual_accept(args, m)
    if recorder.mine or not pending then return end
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name() == "System.Guid" then
            local g = game.arg_guid(args, i)
            for kind, id in pairs(pending.ids) do
                if id == g then
                    util.config.learned.follow_id = kind
                    util.info("learned: quest invites are accepted by " .. kind)
                end
            end
            break
        end
    end
    pending = nil
end

local function accept()
    local nrm = game.request_manager()
    local m = game.method("app.NetworkRequestManager", "acceptInviteLinkPartyQuest")
    if not (nrm and m) then return false end
    local kind = id_order()[(pending.tries % 2) + 1]
    local id = pending.ids[kind]
    if not game.guid_valid(id) then return false end
    local guid_index
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name() == "System.Guid" then guid_index = i break end
    end
    if not guid_index then
        util.warn("acceptInviteLinkPartyQuest has no Guid parameter; auto-follow needs an update (see Diagnostics)")
        util.config.auto_follow = false
        return false
    end
    local ok, res = util.try("accept quest invite", recorder.call, nrm, m, recorder.values(KEY, { [guid_index] = id }))
    util.info(string.format("joining %s's quest (%s, result %s)", pending.name, kind, tostring(res)))
    return ok and res ~= false
end

function follow.update()
    if not pending or util.now() < pending.at then return end
    if game.in_session(game.SESSION.QUEST()) then
        follow.status = "joined " .. pending.name .. "'s quest"
        pending = nil
        return
    end
    if pending.tries >= TRIES then
        follow.status = "couldn't join " .. pending.name .. "'s quest; accept it by hand once"
        util.warn(follow.status)
        pending = nil
        return
    end
    accept()
    pending.tries = pending.tries + 1
    pending.at = util.now() + RETRY -- re-checked next time: joined, or try again
end

function follow.init()
    game.hook("app.Net_Party", "addQuestInviteNotify", on_invite)
    game.hook("app.NetworkRequestManager", "acceptInviteLinkPartyQuest", on_manual_accept)
end

return follow
