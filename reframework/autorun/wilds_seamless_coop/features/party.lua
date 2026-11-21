-- Permanent Link Party: rebuild the Link Party with your co-op group after a disconnect or when someone starts the
-- game later ("auto_party"). Uses the game's own requests only:
--   inviter: NetworkRequestManager.inviteLinkParty(session, Net_MLUserInfo built from the member's saved card, cb)
--   invitee: NetworkRequestManager.acceptInviteLinkParty(inviter id, password, cb), told over the mod channel
-- Who invites: whoever already has a Link Party with others; otherwise the lower Steam id.
-- Leaving the Link Party yourself (game menu) pauses this until you are in a Link Party with your group again.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")
local net = require("wilds_seamless_coop.net")
local group = require("wilds_seamless_coop.features.group")

local party = { status = "" }

local EVERY, INVITE_RETRY, MAX_FAST_TRIES, SLOW_RETRY, ASK_EVERY = 3, 30, 6, 300, 15
local INVITE_KEY = "app.NetworkRequestManager.inviteLinkParty"
local ACCEPT_KEY = "app.NetworkRequestManager.acceptInviteLinkParty"
local next_run = 0
local tries = {}     -- [steam id] = { at, n }
local asked = {}     -- [steam id] = time we last asked them to invite us
local left_until = {} -- [steam id] = they left the Link Party by hand: don't invite them before this time
local left_by_hand = false
local pending_accept -- { from contact id, hunter, user, pw, n, at }

local function in_link_with(hunter)
    for _, m in ipairs(game.members(game.SESSION.LINK())) do
        if not m.is_self and m.hunter_id == hunter then return true end
    end
    return false
end

local function my_party_size() return #game.members(game.SESSION.LINK()) end

-- 0.5.0 froze a player's game a few seconds after an automatic invite: REFramework could not build the request's
-- callback (System.Action`2<Boolean, NETWORK_ERROR_CODE>), so the game got a null one. The game is only asked to
-- invite / accept when a real callback can be passed; otherwise automatic rebuilding stays off.
local callbacks_ok -- nil = not checked yet
local function can_request()
    if callbacks_ok == nil then
        callbacks_ok = true
        for _, name in ipairs({ "inviteLinkParty", "acceptInviteLinkParty" }) do
            local m = game.method("app.NetworkRequestManager", name)
            for _, td in ipairs(m and m:get_param_types() or {}) do
                if td:get_full_name():find("^System%.Action") then
                    local ok, d = pcall(sdk.create_delegate, td, 0)
                    if not (ok and d ~= nil) then callbacks_ok = false end
                end
            end
            if not m then callbacks_ok = false end
        end
        if not callbacks_ok then
            util.warn("automatic Link Party rebuilding is off: the game's invite request can't be called safely "
                .. "on this REFramework (invite your group from the game menu instead)")
        end
    end
    return callbacks_ok
end

-- Whether we (not contact c) send the invite: whoever has a Link Party with others; otherwise the lower Steam id.
-- Both games decide from the same HELLO data, so normally exactly one side invites.
local function i_invite(c)
    local mine, theirs = my_party_size(), (c.in_link and c.link_n or 0)
    if mine > 1 and theirs <= 1 then return true end
    if theirs > 1 and mine <= 1 then return false end
    return tostring(net.self_id() or "") < tostring(c.id)
end

local function password()
    local nm = game.network_manager()
    if not nm then return "" end
    local ok, with = pcall(nm.call, nm, "get_IsLinkPartyRecruitingWithPassword")
    if ok and with == true then
        local ok2, pw = pcall(nm.call, nm, "get_LinkPartyRecruitPassword")
        if ok2 and type(pw) == "string" then return pw end
    end
    return ""
end

-- Invite contact c to our Link Party with the game's own request.
local function invite(c)
    if not can_request() or util.now() < (left_until[c.id] or 0) then return end
    -- Only from an existing Link Party (the freeze happened inviting with none): the game's own menu creates one.
    if my_party_size() < 1 then
        party.status = "open a Link Party in the game menu and your group is invited to it automatically"
        return
    end
    local t = tries[c.id] or { at = -1000, n = 0 }
    local wait = t.n < MAX_FAST_TRIES and INVITE_RETRY or SLOW_RETRY
    if util.now() - t.at < wait then return end
    t.at, t.n = util.now(), t.n + 1
    tries[c.id] = t

    local nrm = game.request_manager()
    local m = game.method("app.NetworkRequestManager", "inviteLinkParty")
    if not (nrm and m) then
        party.status = "the game's Link Party invite request was not found (game update?)"
        return
    end
    local card = c.card or (util.config.group.members[c.id] or {}).card
    local ml, why = game.ml_from_card(card)
    if not ml then
        party.status = "can't invite " .. tostring(c.hunter_name) .. " yet: " .. tostring(why)
        return
    end
    -- The session the invite is made from: what the game used when you invited by hand, else alternate LINK / LOBBY.
    local learned = recorder.values(INVITE_KEY)
    local session = learned[1] or ((t.n % 2 == 1) and game.SESSION.LINK() or game.SESSION.LOBBY())
    local ok = util.try("Link Party invite", recorder.call, nrm, m, { [1] = session, [2] = ml })
    if ok then
        local me = game.self_card() or {}
        net.send(c.id, { t = "pinvite", hunter = me.HunterId, user = me.UserId, pw = password() })
        util.info(string.format("Link Party invite sent to %s (try %d)", tostring(c.hunter_name), t.n))
    end
    party.status = "inviting " .. tostring(c.hunter_name) .. " to your Link Party (try " .. t.n .. ")"
end

-- Accept a Link Party invite from a group member (told by their "pinvite" message).
local function accept()
    local a = pending_accept
    if not a or util.now() < a.at then return end
    if not can_request() then
        pending_accept = nil
        return
    end
    if in_link_with(a.hunter) or a.n >= 4 then
        pending_accept = nil
        return
    end
    local nrm = game.request_manager()
    local m = game.method("app.NetworkRequestManager", "acceptInviteLinkParty")
    if not (nrm and m) then return end
    local kind = util.config.learned.party_accept_id or ((a.n % 2 == 0) and "hunter" or "user")
    local id = kind == "user" and a.user or a.hunter
    a.n, a.at = a.n + 1, util.now() + 8
    if not game.guid_valid(id) then return end
    local values = recorder.values(ACCEPT_KEY)
    for i, td in ipairs(m:get_param_types() or {}) do
        local tn = td:get_full_name()
        if tn == "System.Guid" then values[i] = id end
        if tn == "System.String" then values[i] = a.pw or "" end
    end
    if util.try("accept Link Party invite", recorder.call, nrm, m, values) then
        util.info("accepting " .. tostring(a.name) .. "'s Link Party invite (" .. kind .. " id)")
    end
end

local function on_pinvite(c, msg)
    if not group.is_member(c.id) or not util.on("auto_party") or left_by_hand then return end
    if in_link_with(c.hunter) then return end
    pending_accept = { id = c.id, name = c.hunter_name, hunter = msg.hunter, user = msg.user, pw = msg.pw, n = 0,
        at = util.now() + 2 }
end

local function on_need(c)
    if not group.is_member(c.id) or not util.on("auto_party") or left_by_hand then return end
    -- only if our own view agrees that we are the inviter (their view may be a few seconds old)
    if c.hunter and not in_link_with(c.hunter) and not game.in_session(game.SESSION.QUEST()) and i_invite(c) then
        tries[c.id] = tries[c.id] and { at = -1000, n = tries[c.id].n } or nil
        invite(c)
    end
end

-- Learn which id the game passes when you accept a Link Party invite by hand.
local function learn_accept(args, m)
    if recorder.mine then return end
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name() == "System.Guid" then
            local g = game.arg_guid(args, i)
            for _, c in pairs(net.contacts) do
                if c.card and g == c.card.HunterId then util.config.learned.party_accept_id = "hunter" end
                if c.card and g == c.card.UserId then util.config.learned.party_accept_id = "user" end
            end
        end
    end
end

-- You left the Link Party from the game's menu: stop rebuilding it until you are back with your group.
local function on_leave(args, m)
    if recorder.mine then return end
    for i, td in ipairs(m:get_param_types() or {}) do
        if td:get_full_name():match("SESSION_TYPE$") and game.arg_int(args, i) == game.SESSION.LINK() then
            if not left_by_hand then util.info("you left the Link Party: automatic re-joining paused until you link up again") end
            left_by_hand = true
            for id in pairs(util.config.group.members) do net.send(id, { t = "pleft" }) end
        end
    end
end

local function on_pleft(c)
    if group.is_member(c.id) then
        left_until[c.id] = util.now() + SLOW_RETRY -- don't chase them; they come back by inviting/joining
        util.info(tostring(c.hunter_name) .. " left the Link Party")
    end
end

function party.update()
    local now = util.now()
    accept()
    if now < next_run then return end
    next_run = now + EVERY
    if not util.on("auto_party") then
        party.status = util.config.enabled == false and "mod off" or (util.sync_paused() and "paused (outsiders)" or "off")
        return
    end
    if not can_request() then
        party.status = "automatic rebuilding unavailable (not safe on this REFramework); invite from the game menu"
        return
    end
    -- back with the group in one Link Party: resume after a manual leave
    if left_by_hand then
        for id in pairs(util.config.group.members) do
            local c = net.contacts[id]
            if c and c.hunter and in_link_with(c.hunter) then left_by_hand = false end
        end
        if left_by_hand then
            party.status = "paused: you left the Link Party (invite your group again, or untick/tick the setting)"
            return
        end
    end
    if game.in_session(game.SESSION.QUEST()) then
        party.status = "waiting: in a quest"
        return
    end
    local missing = 0
    for id in pairs(util.config.group.members) do
        local c = net.contacts[id]
        if c and c.hunter and c.enabled and not c.open and not in_link_with(c.hunter) then
            missing = missing + 1
            if c.in_quest then
                party.status = tostring(c.hunter_name) .. " is in a quest; re-linking after it"
            else
                if i_invite(c) then
                    invite(c)
                else
                    if now - (asked[id] or -100) >= ASK_EVERY then
                        asked[id] = now
                        net.send(id, { t = "pneed" })
                    end
                    party.status = "waiting for " .. tostring(c.hunter_name) .. "'s Link Party invite"
                end
            end
        elseif c and c.hunter and in_link_with(c.hunter) then
            tries[id] = nil
        end
    end
    if missing == 0 then
        local online = 0
        for id in pairs(util.config.group.members) do if net.contacts[id] then online = online + 1 end end
        party.status = online > 0 and "your online group is in your Link Party" or "no group member online"
    end
end

function party.init()
    if not util.at_start("auto_party") then return end
    net.on("pinvite", on_pinvite, true)
    net.on("pneed", on_need, true)
    net.on("pleft", on_pleft, true)
    game.hook("app.NetworkRequestManager", "acceptInviteLinkParty", learn_accept)
    game.hook("app.NetworkRequestManager", "leaveSession", on_leave)
end

return party
