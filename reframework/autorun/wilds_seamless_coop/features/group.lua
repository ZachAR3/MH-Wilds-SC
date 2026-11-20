-- Co-op group: the people you play the whole game with. Saved by Steam id (config.group.members), so the mods find
-- each other on every start whatever anyone's Steam status (offline / invisible included) and the party can be
-- rebuilt after a disconnect (features/party.lua).
--
-- Joining:
--   * Invite button: pick any Steam friend (online or not). Their mod gets the invite as soon as their game runs
--     (and a Steam chat invite is sent too, so an offline friend sees it and can launch the game from it).
--   * Or just Link Party invite them in game: two modded hunters in one Link Party join each other's group.
-- Leaving: "Leave group" tells the others and forgets them.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")
local unlock = require("wilds_seamless_coop.features.unlock")

local group = {
    pending_out = {}, -- [steam id] = { name, at, until }
    pending_in = {},  -- [steam id] = { name, at }
    status = "",
}

local INVITE_FOR, INVITE_EVERY = 15 * 60, 15
local CONNECT_PREFIX = "+wsc_group="
local STRANGER_GRACE = 15
local next_invite_send, next_trust, next_scan = 0, 0, 0
local stranger_since = {} -- [hunter id] = first seen

local function members() return util.config.group.members end

function group.is_member(id) return id ~= nil and members()[id] ~= nil end

function group.count()
    local n = 0
    for _ in pairs(members()) do n = n + 1 end
    return n
end

-- Member records sorted by name: { id, name, hunter, card, added }
function group.list()
    local out = {}
    for id, m in pairs(members()) do
        local r = { id = id }
        for k, v in pairs(m) do r[k] = v end
        out[#out + 1] = r
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function group.member_by_hunter(hunter)
    for id, m in pairs(members()) do
        if m.hunter == hunter then return id, m end
    end
    return nil
end

local function display(id, c)
    return (c and (c.hunter_name or c.steam_name)) or net.friend_name(id) or ("Steam id " .. tostring(id))
end

-- Steam ids the plugin must accept messages from even when they are not Steam friends.
local function update_trust()
    local p = net.plugin()
    if not (p and p.trust) then return end
    local ids = {}
    for id in pairs(members()) do ids[#ids + 1] = id end
    for id in pairs(group.pending_out) do ids[#ids + 1] = id end
    p.trust(ids)
end

local function save()
    util.save_config()
    next_trust = 0
end

local function add(id, c, how)
    if id == net.self_id() then return end
    local m = members()[id] or { added = os.date("%Y-%m-%d") }
    m.name = display(id, c)
    m.steam_name = (c and c.steam_name) or net.friend_name(id) or m.steam_name
    if c and c.hunter then m.hunter = c.hunter end
    if c and c.card then m.card = c.card end
    local fresh = members()[id] == nil
    members()[id] = m
    group.pending_out[id], group.pending_in[id] = nil, nil
    save()
    if fresh then util.info(m.name .. " joined your co-op group (" .. how .. ")") end
end

------------------------------------------------------------------------------------------------------------------------
-- Actions (panel)
------------------------------------------------------------------------------------------------------------------------

function group.invite(id, name)
    if not id or id == net.self_id() then return end
    group.pending_out[id] = { name = name or net.friend_name(id) or id, at = util.now(), ["until"] = util.now() + INVITE_FOR }
    next_invite_send, next_trust = 0, 0
    local p = net.plugin()
    if util.config.steam_chat_invite and p and p.invite then
        local ok = p.invite(id, CONNECT_PREFIX .. tostring(net.self_id()))
        util.info("invited " .. tostring(group.pending_out[id].name) .. " to your co-op group"
            .. (ok and " (Steam chat invite sent)" or " (Steam chat invite failed; their mod still gets it in game)"))
    else
        util.info("invited " .. tostring(group.pending_out[id].name) .. " to your co-op group")
    end
end

function group.cancel(id)
    group.pending_out[id] = nil
    net.send(id, { t = "gcancel" })
    next_trust = 0
end

function group.accept(id)
    local inv = group.pending_in[id]
    net.send(id, { t = "gaccept" })
    add(id, net.contacts[id] or { steam_name = inv and inv.name }, "invite accepted")
end

function group.decline(id)
    group.pending_in[id] = nil
    net.send(id, { t = "gdecline" })
end

function group.remove(id)
    local m = members()[id]
    members()[id] = nil
    net.send(id, { t = "gleave" })
    save()
    if m then util.info("removed " .. tostring(m.name) .. " from your co-op group") end
end

function group.leave()
    for id in pairs(members()) do net.send(id, { t = "gleave" }) end
    util.config.group.members = {}
    save()
    util.info("you left your co-op group")
end

------------------------------------------------------------------------------------------------------------------------
-- Messages
------------------------------------------------------------------------------------------------------------------------

local function on_invite(c, msg)
    if group.is_member(c.id) then
        net.send(c.id, { t = "gaccept" }) -- already together (e.g. they reinstalled): just confirm
        return
    end
    if not group.pending_in[c.id] then
        util.info(display(c.id, c) .. " invited you to their co-op group (accept in the mod panel)")
    end
    group.pending_in[c.id] = { name = msg.name or display(c.id, c), at = util.now() }
end

local function on_accept(c)
    if group.pending_out[c.id] or group.is_member(c.id) then add(c.id, c, "accepted your invite") end
end

local function on_decline(c)
    if group.pending_out[c.id] then
        util.info(display(c.id, c) .. " declined your co-op group invite")
        group.pending_out[c.id] = nil
    end
end

local function on_cancel(c) group.pending_in[c.id] = nil end

local function on_leave(c)
    if group.is_member(c.id) then
        util.info(tostring(members()[c.id].name) .. " left your co-op group")
        members()[c.id] = nil
        save()
    end
end

-- A Steam invite accepted: "join" event while running, or the connect string the game was launched with.
local function on_steam_join(connect, from)
    local inviter = connect and connect:match("wsc_group=(%d+)")
    if not inviter then return false end
    inviter = from or inviter
    util.info("Steam invite accepted: joining " .. display(inviter) .. "'s co-op group")
    net.send(inviter, { t = "gaccept" })
    add(inviter, net.contacts[inviter], "Steam invite")
    return true
end

------------------------------------------------------------------------------------------------------------------------

-- Two modded hunters in one Link Party: join each other's group (the in-game invite path). Non-group hunters in the
-- Link Party are "strangers": story and cutscene sync pause while one is there.
local function scan_party()
    local now = util.now()
    local stranger, seen = nil, {}
    local all = game.members(game.SESSION.LINK())
    for _, m in ipairs(game.members(game.SESSION.QUEST())) do all[#all + 1] = m end -- SOS / quest joiners too
    for _, m in ipairs(all) do
        if not m.is_self and m.hunter_id then
            seen[m.hunter_id] = true
            local peer = net.peer_by_hunter(m.hunter_id)
            if peer and not group.is_member(peer.id) and util.config.enabled ~= false and not util.outsiders then
                add(peer.id, net.contacts[peer.id], "same Link Party")
            end
            if peer and group.is_member(peer.id) then
                local rec = members()[peer.id]
                if rec.hunter ~= m.hunter_id or rec.name ~= m.name then
                    rec.hunter, rec.name = m.hunter_id, m.name
                    local c = net.contacts[peer.id]
                    if c and c.card then rec.card = c.card end
                    save()
                end
                stranger_since[m.hunter_id] = nil
            else
                stranger_since[m.hunter_id] = stranger_since[m.hunter_id] or now
                if now - stranger_since[m.hunter_id] >= STRANGER_GRACE then stranger = m.name end
            end
        end
    end
    for h in pairs(stranger_since) do
        if not seen[h] then stranger_since[h] = nil end
    end
    if stranger ~= util.stranger then
        if stranger then
            util.warn(stranger .. " is playing with you but is not in your co-op group: story and cutscene sync paused")
        elseif util.stranger then
            util.info("only your co-op group is playing with you again: story and cutscene sync resumed")
        end
        util.stranger = stranger
    end
end

function group.update()
    local now = util.now()
    local p = net.plugin()
    if not p then return end

    for _, e in ipairs(p.events and p.events() or {}) do
        if e.kind == "join" then on_steam_join(e.connect, e.from) end
    end

    for id, inv in pairs(group.pending_out) do
        if now > inv["until"] then
            group.pending_out[id] = nil
            util.info("co-op group invite to " .. tostring(inv.name) .. " expired")
            next_trust = 0
        end
    end
    if now >= next_invite_send then
        next_invite_send = now + INVITE_EVERY
        local ok, me = pcall(game.self_card)
        local my_name = ok and me and me.HunterName or net.friend_name(net.self_id()) or "a hunter"
        for id in pairs(group.pending_out) do net.send(id, { t = "ginvite", name = my_name }) end
    end
    if now >= next_trust then
        next_trust = now + 30
        update_trust()
    end
    if now >= next_scan then
        next_scan = now + 1
        scan_party()
    end

    local online = 0
    for id in pairs(members()) do
        if net.contacts[id] then online = online + 1 end
    end
    group.status = string.format("%d member(s), %d online", group.count(), online)
end

-- Closed group: Environment Link joins by hunters outside the group are refused (features/unlock.lua asks this).
local function refuse_join(guid)
    if util.config.enabled == false or util.outsiders or group.count() == 0 or not game.guid_valid(guid) then return false end
    for _, m in pairs(members()) do
        local c = m.card or {}
        if guid == m.hunter or guid == c.HunterId or guid == c.UserId then return false end
    end
    for _, c in pairs(net.contacts) do
        local card = c.card or {}
        if guid == c.hunter or guid == card.HunterId or guid == card.UserId then return false end
    end
    local who = guid
    for _, m in ipairs(game.members(game.SESSION.LINK())) do
        if m.hunter_id == guid or m.user_id == guid then who = m.name end
    end
    return true, tostring(who) .. " is not in your co-op group (tick 'Allow outsiders' to let them in)"
end

function group.init()
    unlock.refuse_join = refuse_join
    net.extra_targets = function()
        local out = {}
        for id in pairs(members()) do out[id] = true end
        for id in pairs(group.pending_out) do out[id] = true end
        for id in pairs(group.pending_in) do out[id] = true end
        return out
    end
    net.on("ginvite", on_invite, true)
    net.on("gaccept", on_accept, true)
    net.on("gdecline", on_decline, true)
    net.on("gcancel", on_cancel, true)
    net.on("gleave", on_leave, true)
    local p = net.plugin()
    if p and p.launch_connect then
        local ok, cmd = pcall(p.launch_connect)
        if ok and type(cmd) == "string" and cmd ~= "" then group.launch_connect = cmd end
    end
end

-- The launch connect string needs Steam ready (net.update), so it is handled on the first tick that has a self id.
local launch_done = false
local base_update = group.update
function group.update()
    if not launch_done and group.launch_connect and net.self_id() then
        launch_done = true
        on_steam_join(group.launch_connect, nil)
    end
    base_update()
end

return group
