-- Shared cutscenes between Environment-Linked co-op partners on the same story mission:
--   * start together - when your game is about to play a cutscene, it waits (up to TIMEOUT s) until every partner's
--     game has reached the same cutscene, then all play it at once;
--   * skip together  - pressing skip casts a vote; the cutscene is skipped for everyone once all watchers voted;
--   * the others' cutscene state is shown in the panel / on screen.
-- Each game plays its own copy of the cutscene (that's how the story stays in step); only timing is shared.
-- Quest-start cutscenes inside a hunt are left to the game, which already synchronises those.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")

local cutscene = { status = "" }

local TIMEOUT = 30

local held = nil      -- { param, method, id, since } a cutscene waiting for the others
local watching = nil  -- id of the cutscene playing here
local votes = {}      -- [id] = { [peer id | "self"] = true }
local others = {}     -- [peer id] = { id, phase = "ready" | "play" }
local passing = false -- true while the mod itself calls DemoMediator

local function dm() return sdk.get_managed_singleton("app.DemoMediator") end

-- Partners who share this cutscene: Environment-Linked peers on the same next main mission.
local function partners()
    local out, mine = {}, game.next_main_mission()
    for _, p in pairs(net.peers) do
        if p.is_sync and p.next_mission == mine then out[#out + 1] = p end
    end
    return out
end

local function active()
    return util.on("cutscene_sync") and net.peer_count() > 0 and not game.in_session(game.SESSION.QUEST())
end

local function tell(id, phase)
    net.state.cut = phase and { id = id, phase = phase } or nil
    net.broadcast({ t = "cut", id = id, phase = phase })
end

local function all_at(id, phases)
    for _, p in ipairs(partners()) do
        local o = others[p.id]
        if not (o and o.id == id and phases[o.phase]) then return false end
    end
    return true
end

------------------------------------------------------------------------------------------------------------------------
-- Start together
------------------------------------------------------------------------------------------------------------------------

-- Timeline event id of a play request (ace.DemoMediatorBase.cParamBase.ID).
local function event_id(param)
    if param == nil then return nil end
    local ok, id = pcall(param.get_field, param, "<ID>k__BackingField")
    if ok and type(id) == "number" then return id end
    return nil
end

local function on_request_play(args, m)
    if passing or not active() or #partners() == 0 then return end
    local param = game.arg_obj(args, 1)
    local id = event_id(param)
    if id == nil then return end
    if held then
        -- The game asks again for the same cutscene while we wait: keep waiting. Anything else passes untouched.
        if id == held.id then return sdk.PreHookResult.SKIP_ORIGINAL end
        return
    end
    tell(id, "ready")
    if all_at(id, { ready = true, play = true }) then return end
    param:add_ref() -- keep the request alive until we pass it on
    held = { param = param, method = m, id = id, since = util.now() }
    util.info("cutscene " .. tostring(id) .. ": waiting for your partner(s)")
    return sdk.PreHookResult.SKIP_ORIGINAL
end

local function release_held(reason)
    local h = held
    held = nil
    local d = dm()
    if d then
        passing = true
        util.try("play cutscene", game.call, d, h.method, { [1] = h.param })
        passing = false
    end
    pcall(h.param.release, h.param)
    util.info("cutscene " .. tostring(h.id) .. ": " .. reason)
end

------------------------------------------------------------------------------------------------------------------------
-- Skip together
------------------------------------------------------------------------------------------------------------------------

local function watchers()
    local out = {}
    for _, p in ipairs(partners()) do
        local o = others[p.id]
        if o and o.id == watching and o.phase == "play" then out[#out + 1] = p end
    end
    return out
end

local function check_votes()
    if not watching then return end
    local v = votes[watching] or {}
    if not v.self then return end
    for _, p in ipairs(watchers()) do
        if not v[p.id] then return end
    end
    votes[watching] = nil
    local d = dm()
    local m = game.method("app.DemoMediator", "requestSkip")
    if d and m then
        passing = true
        util.try("skip cutscene", game.call, d, m, {})
        passing = false
        util.info("cutscene skipped by vote")
    end
end

local function on_request_skip()
    if passing or not active() or not watching or #watchers() == 0 then return end
    votes[watching] = votes[watching] or {}
    if not votes[watching].self then
        votes[watching].self = true
        net.broadcast({ t = "vote", id = watching })
        util.info("you voted to skip")
    end
    check_votes()
    return sdk.PreHookResult.SKIP_ORIGINAL
end

------------------------------------------------------------------------------------------------------------------------

local function on_play_start(args)
    watching = game.arg_int(args, 1)
    util.debug("cutscene " .. tostring(watching) .. " started (" .. #partners() .. " linked partner(s) on this mission)")
    if active() then tell(watching, "play") end
end

local function on_play_end(args)
    local id = game.arg_int(args, 1)
    util.debug("cutscene " .. tostring(id) .. " ended")
    if id == watching then watching = nil end
    votes[id] = nil
    if active() then tell(id, nil) end
end

local function on_cut(peer, msg)
    others[peer.id] = msg.phase and { id = msg.id, phase = msg.phase } or nil
end

local function on_vote(peer, msg)
    votes[msg.id] = votes[msg.id] or {}
    votes[msg.id][peer.id] = true
    check_votes()
end

function cutscene.update()
    -- Late joiners learn the others' cutscene state from their HELLO.
    for id, p in pairs(net.peers) do
        if p.state.cut and not others[id] then others[id] = p.state.cut end
    end
    for id in pairs(others) do
        if not net.peers[id] then others[id] = nil end
    end

    if held then
        local waited = util.now() - held.since
        if all_at(held.id, { ready = true, play = true }) then
            release_held("everyone is here")
        elseif waited > TIMEOUT or not active() then
            release_held("played without waiting any longer")
        end
    end

    if held then
        cutscene.status = string.format("waiting for partner(s) to reach the cutscene (%ds)", math.floor(util.now() - held.since))
    elseif watching and votes[watching] and votes[watching].self then
        local n, total = 1, #watchers() + 1
        for _, p in ipairs(watchers()) do if votes[watching][p.id] then n = n + 1 end end
        cutscene.status = string.format("skip vote %d/%d", n, total)
    else
        cutscene.status = watching and ("watching cutscene " .. tostring(watching)) or ""
    end
end

function cutscene.init()
    if not util.at_start("cutscene_sync") then return end
    game.hook("app.DemoMediator", "requestPlay", on_request_play)
    game.hook("app.DemoMediator", "requestSkip", on_request_skip)
    game.hook("app.DemoMediator", "onPlayStartTimeline", on_play_start)
    game.hook("app.DemoMediator", "onPlayEndTimeline", on_play_end)
    net.on("cut", on_cut)
    net.on("vote", on_vote)
end

return cutscene
