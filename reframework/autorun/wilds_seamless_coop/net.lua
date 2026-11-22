-- Mod-to-mod messages over seamless_net.dll (Steam P2P; works with offline/invisible Steam status).
--
-- Every few seconds each mod sends HELLO to: its co-op group (saved Steam ids, whatever their Steam status), pending
-- group invites, Steam friends shown in Wilds, and Steam friends whose name matches a Link Party member's Steam name
-- (so a plain in-game Link Party invite also finds the other mod).
--   * contact: anyone whose HELLO arrived recently (group messages, travel and party repair use contacts);
--   * peer:    a contact whose hunter is in our Link Party (story, cutscenes, Environment Link use peers).
-- Messages are JSON tables with a type field `t`.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")

local net = {
    PROTOCOL = 3,
    ghost = false, -- self-test only: treat our own loopback messages as a partner
    status = "starting",
    peers = {},    -- [steam id] = { id, name, hunter, lead, is_sync, progress, next_mission, state, seen, version }
    contacts = {}, -- [steam id] = { id, hunter, hunter_name, card, stage, in_quest, link_n, open, seen, version }
}

-- PEER_TIMEOUT must stay above QUIET_EVERY, or a contact only reached by the quiet HELLO keeps dropping.
local HELLO_EVERY, PEER_TIMEOUT, FRIENDS_EVERY = 3, 20, 10
local QUIET_EVERY = 15 -- HELLO to people who haven't answered yet (offline group members, pending invites)
local next_quiet = 0
local handlers, contact_handlers = {}, {}
local next_hello, next_friends = 0, 0
local all_friends = {} -- cached seamless_net.friends(true)
net.stats = { friends_in_game = 0, hello_sent = 0, hello_received = 0, why = "nothing received yet" }
net.extra_targets = nil -- function() -> { [steam id] = true } (group.lua: members and pending invites)
local told = {} -- reasons already written to the log, per sender
local function reject(from, why)
    net.stats.why = why
    if told[from] ~= why then
        told[from] = why
        util.info("HELLO from Steam id " .. tostring(from) .. " not linked: " .. why)
    end
end
net.state = {} -- small dynamic fields features want every peer to know (e.g. the current cutscene); sent in HELLO

-- Handler for peers (Link Party members) only, or, with any_contact, for every contact.
function net.on(t, fn, any_contact)
    if any_contact then contact_handlers[t] = fn else handlers[t] = fn end
end

local function plugin() return rawget(_G, "seamless_net") end
net.plugin = plugin

function net.available()
    local p = plugin()
    if not p then return false, "seamless_net.dll is not in reframework/plugins" end
    return p.available()
end

function net.self_id()
    local p = plugin()
    return p and p.self_id() or nil
end

local function encode(msg) return json.dump_string(msg) end

function net.send(id, msg, reliable)
    local p = plugin()
    if not p then return false end
    if net.ghost and id == p.self_id() then return p.send_self(encode(msg)) end
    return p.send(id, encode(msg), reliable ~= false)
end

-- Send to every verified peer.
function net.broadcast(msg, reliable)
    for id in pairs(net.peers) do net.send(id, msg, reliable) end
end

function net.peer_count()
    local n = 0
    for _ in pairs(net.peers) do n = n + 1 end
    return n
end

-- The peer playing the given hunter, or nil.
function net.peer_by_hunter(hunter)
    for _, p in pairs(net.peers) do
        if p.hunter == hunter then return p end
    end
    return nil
end

function net.contact_by_hunter(hunter)
    for _, c in pairs(net.contacts) do
        if c.hunter == hunter then return c end
    end
    return nil
end

-- Every Steam friend (online, offline, invisible), refreshed at most every 10 s.
function net.friends_all()
    local p = plugin()
    if p and util.now() >= next_friends then
        next_friends = util.now() + FRIENDS_EVERY
        local ok, list = pcall(p.friends, true)
        if ok and type(list) == "table" then all_friends = list end
    end
    return all_friends
end

function net.friend_name(id)
    for _, f in ipairs(all_friends) do
        if f.id == id then return f.name end
    end
    return nil
end

local my_card, card_at = nil, -100
local function card()
    if util.config.debug_no_net_reads then return nil end -- crash bisecting only (config.json)
    -- The card never changes during a session: read it until we have it, then only every 5 minutes (each read makes
    -- a game object).
    if not my_card and util.now() - card_at > 30 or util.now() - card_at > 300 then
        card_at = util.now()
        local ok, c = pcall(game.self_card)
        if ok and c then my_card = c end
    end
    return my_card
end

-- Stage, story progress and next mission for the HELLO, read at the member-list pace (see game.member_ttl).
local facts, facts_at = {}, -1000
local function game_facts()
    local now = util.now()
    if now - facts_at >= game.member_ttl() or now < facts_at then
        facts_at = now
        if util.config.debug_no_net_reads then return facts end -- crash bisecting only (config.json)
        facts = { stage = game.current_stage(), progress = game.story_progress(), next_mission = game.next_main_mission() }
    end
    return facts
end

local function hello()
    local me = game.self_member(game.SESSION.LINK())
    local c = card()
    local f = game_facts()
    return {
        t = "hello",
        proto = net.PROTOCOL,
        version = util.VERSION,
        hunter = (me and me.hunter_id) or (c and c.HunterId),
        in_link = me ~= nil,
        link_n = #game.members(game.SESSION.LINK()),
        card = c,
        stage = f.stage,
        in_quest = game.in_session(game.SESSION.QUEST()),
        progress = f.progress,
        next_mission = f.next_mission,
        lead = util.config.lead_story == true,
        open = util.outsiders,
        enabled = util.config.enabled ~= false,
        state = net.state,
    }
end

-- Steam ids that should get our HELLO. Only people who opted in (your group, invites you sent or got) and hunters
-- already in your Link Party (the game itself is connected to them). Friends who merely play Wilds are never
-- contacted, so nobody without the mod gets anything from it.
local function targets(p)
    local out = {}
    net.stats.friends_in_game = #p.friends()
    if net.extra_targets then
        for id in pairs(net.extra_targets()) do out[id] = true end
    end
    -- Mods that talk to us get answered, so both sides see each other even when only one side lists the other
    -- (without this the contact dropped and came back every ~16 s).
    for id in pairs(net.contacts) do out[id] = true end
    -- Link Party members not linked to a mod yet: Steam friends with the same Steam name (works when invisible).
    local unknown = {}
    for _, m in ipairs(game.members(game.SESSION.LINK())) do
        if not m.is_self and not net.contact_by_hunter(m.hunter_id) and type(m.online_id) == "string" and m.online_id ~= "" then
            unknown[m.online_id] = true
        end
    end
    if next(unknown) then
        for _, f in ipairs(net.friends_all()) do
            if unknown[f.name] then out[f.id] = true end
        end
    end
    out[p.self_id() or ""] = nil
    out[""] = nil
    return out
end

local function on_hello(from, msg)
    net.stats.hello_received = net.stats.hello_received + 1
    if msg.proto ~= net.PROTOCOL then
        return reject(from, "different mod version (protocol theirs " .. tostring(msg.proto) .. ", yours "
            .. net.PROTOCOL .. "); both need the same zip")
    end
    local c = net.contacts[from]
    local fresh = c == nil
    c = c or { id = from }
    c.hunter = type(msg.hunter) == "string" and msg.hunter or c.hunter
    c.card = type(msg.card) == "table" and msg.card or c.card
    c.hunter_name = c.card and c.card.HunterName or c.hunter_name
    c.stage, c.in_quest, c.in_link, c.link_n = msg.stage, msg.in_quest == true, msg.in_link == true, tonumber(msg.link_n) or 0
    c.open, c.enabled, c.version, c.seen = msg.open == true, msg.enabled ~= false, msg.version, util.now()
    c.progress, c.next_mission = msg.progress, msg.next_mission
    c.steam_name = net.friend_name(from) or c.steam_name
    net.contacts[from] = c
    if fresh then util.info("mod contact: " .. tostring(c.hunter_name or c.steam_name or from) .. " (mod " .. tostring(msg.version) .. ")") end

    if not c.hunter then return reject(from, "they have not loaded a hunter yet") end
    local member, members = nil, game.members(game.SESSION.LINK())
    for _, m in ipairs(members) do
        if not m.is_self and m.hunter_id == c.hunter then member = m end
    end
    if not member then
        if net.peers[from] then util.info("co-op link with " .. net.peers[from].name .. " paused (not in your Link Party)") end
        net.peers[from] = nil
        return reject(from, string.format("their hunter is not in your Link Party (you see %d member(s) there)", #members))
    end
    told[from] = nil
    local known = net.peers[from] ~= nil
    net.peers[from] = {
        id = from,
        name = member.name,
        hunter = c.hunter,
        lead = msg.lead == true,
        is_sync = member.is_sync, -- in Environment Link with us (same field)
        progress = msg.progress,
        next_mission = msg.next_mission,
        state = type(msg.state) == "table" and msg.state or {},
        version = msg.version,
        seen = util.now(),
    }
    if not known then util.info("co-op link with " .. member.name .. " (mod " .. tostring(msg.version) .. ")") end
end

function net.update()
    local ok, reason = net.available()
    if not ok then
        net.status = reason
        return
    end
    local now = util.now()
    local p = plugin()

    if now >= next_hello then
        next_hello = now + HELLO_EVERY
        -- every 3 s to mods that answered recently; every 15 s to everyone else on the list
        local quiet = now >= next_quiet
        if quiet then next_quiet = now + QUIET_EVERY end
        local h = encode(hello())
        for id in pairs(targets(p)) do
            if quiet or net.contacts[id] then
                if p.send(id, h, false) then net.stats.hello_sent = net.stats.hello_sent + 1 end
            end
        end
    end

    for _, m in ipairs(p.poll()) do
        local okj, msg = pcall(json.load_string, m.data)
        if okj and type(msg) == "table" and type(msg.t) == "string" then
            if m.from == p.self_id() then
                -- Our own loopback: only the self-test uses it, as a pretend partner ("ghost").
                if net.ghost and msg.t == "hello" then
                    net.peers[m.from] = { id = m.from, name = "self-test ghost", hunter = msg.hunter, lead = true,
                        is_sync = true, progress = msg.progress, next_mission = msg.next_mission, state = {},
                        version = msg.version, seen = now }
                elseif net.ghost and net.peers[m.from] and handlers[msg.t] then
                    util.try("message " .. msg.t, handlers[msg.t], net.peers[m.from], msg)
                end
            elseif msg.t == "hello" then
                on_hello(m.from, msg)
            elseif contact_handlers[msg.t] then
                -- group messages may come before the first HELLO (e.g. an invite): a minimal contact record
                local c = net.contacts[m.from] or { id = m.from, seen = now, steam_name = net.friend_name(m.from) }
                util.try("message " .. msg.t, contact_handlers[msg.t], c, msg)
            elseif net.peers[m.from] then
                local fn = handlers[msg.t]
                if fn then util.try("message " .. msg.t, fn, net.peers[m.from], msg) end
            end
        end
    end

    for id, peer in pairs(net.peers) do
        if now - peer.seen > PEER_TIMEOUT then
            util.info("co-op link with " .. peer.name .. " lost")
            net.peers[id] = nil
        end
    end
    for id, c in pairs(net.contacts) do
        if now - (c.seen or 0) > PEER_TIMEOUT then
            util.info("mod contact lost: " .. tostring(c.hunter_name or c.steam_name or id))
            net.contacts[id] = nil
        end
    end

    local n = net.peer_count()
    local nc = 0
    for _ in pairs(net.contacts) do nc = nc + 1 end
    if n > 0 then
        net.status = "connected to " .. n .. " modded hunter(s) in your Link Party"
    elseif nc > 0 then
        net.status = nc .. " modded hunter(s) reachable, none in your Link Party yet"
    elseif net.stats.hello_received == 0 then
        net.status = "no other mod heard yet (invite your partner to the group, or Link Party invite them)"
    else
        net.status = "not linked: " .. net.stats.why
    end
end

-- Story leader: the player who ticked "Lead the story" - "self", a peer, or nil when nobody did.
-- If several did, the one with the lowest Steam id leads, so every game agrees.
function net.leader()
    local best, best_id = nil, nil
    local p = plugin()
    if util.config.lead_story and p then best, best_id = "self", tostring(p.self_id() or "") end
    for id, peer in pairs(net.peers) do
        if peer.lead and (best_id == nil or tostring(id) < best_id) then best, best_id = peer, tostring(id) end
    end
    return best
end

function net.is_leader() return net.leader() == "self" end

-- Self-test: HELLO to ourselves, so the ghost partner appears.
function net.hello_self()
    local p = plugin()
    return p ~= nil and p.send_self ~= nil and p.send_self(encode(hello()))
end

-- Force an immediate HELLO (e.g. right after net.state changes).
function net.announce() next_hello = 0 end

return net
