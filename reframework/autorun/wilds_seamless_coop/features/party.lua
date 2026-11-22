-- Permanent Link Party: re-invite your co-op group to the Link Party after a disconnect or when someone starts the
-- game later ("auto_party", experimental, untested live).
--   inviter: the game's own invite window, cGUINetworkRequest.reqLinqPartyInviteWindow(GUI, Net_MLUserInfo, session,
--            Action), with the member taken from your Hunter Friends list. It is only used after you have invited
--            someone by hand once, so the mod can copy the session type and check that the game itself passes no
--            callback there (the mod never makes one up).
--   invitee: the game shows its usual invite notification; accept it there (the mod tells you who invited you).
-- Who invites: whoever already has a Link Party with others; otherwise the lower Steam id.
-- Leaving the Link Party yourself (game menu) pauses this until you are in a Link Party with your group again.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")
local group = require("wilds_seamless_coop.features.group")

local party = { status = "" }

local EVERY, INVITE_RETRY, MAX_FAST_TRIES, SLOW_RETRY, ASK_EVERY = 3, 30, 6, 300, 15
local next_run = 0
local tries = {}     -- [steam id] = { at, n }
local asked = {}     -- [steam id] = time we last asked them to invite us
local left_until = {} -- [steam id] = they left the Link Party by hand: don't invite them before this time
local left_by_hand = false

local function in_link_with(hunter)
    for _, m in ipairs(game.members(game.SESSION.LINK())) do
        if not m.is_self and m.hunter_id == hunter then return true end
    end
    return false
end

local function my_party_size() return #game.members(game.SESSION.LINK()) end

-- Whether we (not contact c) send the invite: whoever has a Link Party with others; otherwise the lower Steam id.
-- Both games decide from the same HELLO data, so normally exactly one side invites.
local function i_invite(c)
    local mine, theirs = my_party_size(), (c.in_link and c.link_n or 0)
    if mine > 1 and theirs <= 1 then return true end
    if theirs > 1 and mine <= 1 then return false end
    return tostring(net.self_id() or "") < tostring(c.id)
end

-- How the game called its invite window when you invited by hand: { session = n, action_null = bool }.
local function learned_invite() return util.config.learned.party_invite end

local function learn_invite(args, m)
    -- static: args[2] = GUI, args[3] = Net_MLUserInfo, args[4] = SESSION_TYPE, args[5] = Action
    local ok, err = pcall(function()
        local session = sdk.to_int64(args[4]) & 0xFFFFFFFF
        local action_null = sdk.to_int64(args[5]) == 0
        -- the GUI the game opens it from: the mod may only open it from the same one (game.MENU_GUI)
        local gui = sdk.to_managed_object(args[2])
        local gui_type = gui and gui:get_type_definition():get_full_name() or nil
        util.config.learned.party_invite = { session = session, action_null = action_null, gui = gui_type }
        util.info(string.format("learned the game's Link Party invite (session %d, %s, from %s)", session,
            action_null and "no callback" or "with a callback", tostring(gui_type)))
    end)
    if not ok then util.debug("learn Link Party invite: " .. tostring(err)) end
end

-- Invite contact c to our Link Party with the game's own invite window.
local function invite(c)
    if util.now() < (left_until[c.id] or 0) then return end
    local how = learned_invite()
    if not how or not how.gui then
        party.status = "invite " .. tostring(c.hunter_name) .. " to your Link Party once from the game menu, so the "
            .. "mod can learn how the game does it"
        return
    end
    game.MENU_GUI.reqLinqPartyInviteWindow = how.gui
    if not how.action_null then
        party.status = "the game passes a callback to its invite window; automatic invites stay off (send the log)"
        return
    end
    local t = tries[c.id] or { at = -1000, n = 0 }
    local wait = t.n < MAX_FAST_TRIES and INVITE_RETRY or SLOW_RETRY
    if util.now() - t.at < wait then return end
    t.at, t.n = util.now(), t.n + 1
    tries[c.id] = t

    local card = c.card or (util.config.group.members[c.id] or {}).card or {}
    local ml, why = game.friend_ml(card.ShortHunterId)
    if not ml then
        party.status = "can't invite " .. tostring(c.hunter_name) .. ": " .. tostring(why)
        return
    end
    if game.menu_check("canLinkPartyInvite(app.Net_MLUserInfo, System.Boolean)", ml, false) == false then
        party.status = "the game won't invite " .. tostring(c.hunter_name) .. " right now (offline or busy)"
        return
    end
    local ok = util.try("Link Party invite", game.menu, "reqLinqPartyInviteWindow", ml, how.session, nil)
    if ok then
        net.send(c.id, { t = "pinvite" })
        util.info(string.format("opened the game's Link Party invite for %s (try %d)", tostring(c.hunter_name), t.n))
    end
    party.status = "inviting " .. tostring(c.hunter_name) .. " to your Link Party (try " .. t.n .. ")"
end

local function on_pinvite(c)
    if not group.is_member(c.id) or not util.on("auto_party") then return end
    util.info(tostring(c.hunter_name) .. " invited you to their Link Party: accept it in the game's notifications")
end

local function on_need(c)
    if not group.is_member(c.id) or not util.on("auto_party") or left_by_hand then return end
    -- only if our own view agrees that we are the inviter (their view may be a few seconds old)
    if c.hunter and not in_link_with(c.hunter) and not game.in_session(game.SESSION.QUEST()) and i_invite(c) then
        tries[c.id] = tries[c.id] and { at = -1000, n = tries[c.id].n } or nil
        invite(c)
    end
end

-- You left the Link Party from the game's menu: stop rebuilding it until you are back with your group.
local function on_leave(args, m)
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
    if now < next_run then return end
    next_run = now + EVERY
    if not util.on("auto_party") then
        party.status = util.config.enabled == false and "mod off" or (util.sync_paused() and "paused (outsiders)" or "off")
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
    game.hook("app.cGUINetworkRequest", "reqLinqPartyInviteWindow", learn_invite)
    game.hook("app.cGUINetworkRequest", "reqLinqPartyInvite", learn_invite)
    game.hook("app.NetworkRequestManager", "leaveSession", on_leave)
end

return party
