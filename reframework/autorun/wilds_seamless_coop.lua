-- Wilds Seamless Co-op: play Monster Hunter Wilds' story together as one group.
-- 0.5.2 is the safe build of the rebuild (docs/REBUILD_PLAN.md): the co-op group, the Steam P2P channel between the
-- mods (reframework/plugins/seamless_net.dll), the panel and save backups. Everything that drives the game
-- (Environment Link, quests, Link Party, fast travel, story, cutscenes) is experimental, off by default, and only
-- hooks the game when it is switched on at game start. It never creates or edits quests, rewards, items or
-- leaderboard data.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")
local net = require("wilds_seamless_coop.net")
local group = require("wilds_seamless_coop.features.group")
local party = require("wilds_seamless_coop.features.party")
local follow = require("wilds_seamless_coop.features.follow")
local linked = require("wilds_seamless_coop.features.linked")
local travel = require("wilds_seamless_coop.features.travel")
local story = require("wilds_seamless_coop.features.story")
local cutscene = require("wilds_seamless_coop.features.cutscene")
local safety = require("wilds_seamless_coop.features.safety")
local selftest = require("wilds_seamless_coop.selftest")

util.VERSION = "0.5.5"
local TICK = 0.25 -- seconds between feature updates
local FEATURES = { net, safety, group, party, follow, linked, travel, story, cutscene, selftest }

util.load_config()
for _, f in ipairs(FEATURES) do
    if f.init then util.try("init", f.init) end
end
recorder.init() -- after the features: it doesn't hook a method a feature already hooks
local p = rawget(_G, "seamless_net")
util.info("v" .. util.VERSION .. " loaded (plugin " .. tostring(p and p.version or "missing") .. ")")
if util.migrated then
    util.info("settings from an older version: every experimental feature was switched off")
    util.save_config()
end
if util.auto_link_enabled then
    util.info("0.5.5: Auto-invite to Environment Link is now a normal setting and switched on (untick it in the panel)")
    util.save_config()
end
local on_now = {}
for _, t in ipairs(util.EXPERIMENTAL) do
    if util.at_start(t[1]) then on_now[#on_now + 1] = t[1] end
end
if util.at_start("story_sync") then on_now[#on_now + 1] = "story_sync=" .. tostring(util.config.story_sync) end
util.info("experimental features on: " .. (#on_now > 0 and table.concat(on_now, ", ") or "none (the game is not hooked)"))
util.flush_log(true)

-- Everything that touches the game runs on the game's own main thread, between its update jobs.
-- re.on_frame and re.on_draw_ui run on the render thread: reading the Link Party there while the game changes it (a
-- partner joining or leaving) crashed the game on the render thread (0.5.3, 2026-11-21/22). So the panel only shows
-- values the main thread stored and queues its buttons (util.main), and on_frame only draws.
-- Lua frees the game objects it wrapped when its garbage collector runs, on whatever thread is running Lua at that
-- moment (the render thread too). Freeing them while the game's own threads change the same objects crashed the game
-- in its object release queue during Link Party / Environment Link joins (2026-11-22). So the collector only runs
-- here, on the main thread: a full collection right after each feature update (every 0.25 s) and a little every
-- frame in between; on_frame turns automatic collection back on if this ever stops.
-- 0.5.4: without the mod the game survived 6 Environment Link joins in a row on the Steam Deck; with 0.5.3 it crashed
-- in that release queue within 3, so the mod releases what it read at once and reads the game less often.
-- 0.5.5: a crash bisect between two machines pinned it on the member list reads (7 joins clean with them off, a
-- crash within 5 with them on); they now read raw memory and wrap no game object (game.lua, "Raw member reads").
local GC_STEP_KB = 64
local GC_LIMIT_KB = 768 * 1024
collectgarbage("stop")
local gc_ticks, gc_auto = 0, false

local next_tick, next_progress = 0, 0
local function tick()
    gc_ticks = gc_ticks + 1
    if gc_auto and collectgarbage("count") < GC_LIMIT_KB then
        gc_auto = false
        collectgarbage("stop")
    end
    collectgarbage("step", GC_STEP_KB)
    for _, fn in ipairs(util.take_main_queue()) do util.try("panel action", fn) end
    local now = util.now()
    if now >= next_tick then
        next_tick = now + TICK
        for i, f in ipairs(FEATURES) do util.try("update " .. i, f.update) end
        -- Release every game object this update wrapped now, in the frame it was read, instead of whenever the
        -- collector gets to it (possibly mid Environment Link join, when the game is tearing those objects down).
        collectgarbage("collect")
        if now >= next_progress then
            next_progress = now + game.member_ttl()
            util.story_progress = game.story_progress()
        end
        util.flush_log()
    end
end
re.on_application_entry("LateUpdateBehavior", tick)

local gc_seen, gc_frames = 0, 0
re.on_frame(function()
    -- Safety net: the main-thread tick stopped (or Lua grew huge): hand collection back to Lua until it runs again.
    if gc_ticks ~= gc_seen then
        gc_seen, gc_frames = gc_ticks, 0
    else
        gc_frames = gc_frames + 1
    end
    if not gc_auto and (gc_frames > 600 or collectgarbage("count") > GC_LIMIT_KB) then
        gc_auto = true
        collectgarbage("restart")
        util.trace("main-thread update idle: Lua garbage collection automatic for now")
    end
    -- On-screen notices: cutscene waits / skip votes, following a fast travel.
    local cs = cutscene.status
    if cs:find("^waiting") or cs:find("^skip") then
        pcall(draw.text, "Seamless Co-op: " .. cutscene.status, 40, 40, 0xFFFFFFFF)
    elseif travel.status:find("^following") or travel.status:find("^will follow") then
        pcall(draw.text, "Seamless Co-op: " .. travel.status, 40, 40, 0xFFFFFFFF)
    end
end)

re.on_config_save(function()
    util.save_config()
    util.flush_log(true)
end)

------------------------------------------------------------------------------------------------------------------------
-- Panel (REFramework menu, Insert key)
------------------------------------------------------------------------------------------------------------------------

local STORY_MODES = { "off", "dry", "on" }
local STORY_LABELS = { "Off", "Dry run (log only, no save changes)", "On (take the leader's story steps)" }

local function combo(label, key, modes, labels)
    local current = 1
    for i, mode in ipairs(modes) do
        if util.config[key] == mode then current = i end
    end
    local changed, idx = imgui.combo(label, current, labels)
    if changed then
        util.config[key] = modes[idx]
        util.save_config()
    end
end

local function checkbox(label, key)
    local changed, value = imgui.checkbox(label, util.config[key])
    if changed then
        util.config[key] = value
        util.save_config()
    end
end

local filter = ""
local function draw_friend_picker()
    local changed, text = imgui.input_text("Search", filter)
    if changed then filter = text end
    local list = {}
    for _, f in ipairs(net.friends_all()) do
        if not group.is_member(f.id) and (filter == "" or f.name:lower():find(filter:lower(), 1, true)) then
            list[#list + 1] = f
        end
    end
    local function rank(f) return f.in_game and 0 or (f.state > 0 and 1 or 2) end
    table.sort(list, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    if #list == 0 then imgui.text("  (no matching Steam friends)") end
    for i, f in ipairs(list) do
        if i > 60 then
            imgui.text("  ... type to narrow the list")
            break
        end
        local where = f.in_game and "in Wilds" or (f.state > 0 and "online" or "offline / invisible")
        if group.pending_out[f.id] then
            imgui.text(string.format("  %s (%s) - invited", f.name, where))
            imgui.same_line()
            if imgui.button("Cancel##c" .. f.id) then group.cancel(f.id) end
        else
            if imgui.button("Invite##i" .. f.id) then group.invite(f.id, f.name) end
            imgui.same_line()
            imgui.text(string.format("%s  (%s)", f.name, where))
        end
    end
end

local function member_line(m)
    local c = net.contacts[m.id]
    if not c then return "offline (or no mod running)" end
    if c.open then return "online, allowing outsiders" end
    local peer = net.peers[m.id]
    if peer and peer.is_sync then return "with you (Environment Link)" end
    if peer then return "in your Link Party" end
    if c.in_quest then return "online, in a quest" end
    return "online, not in your Link Party yet"
end

local function draw_group()
    imgui.text("Co-op group: " .. group.status)
    for id, inv in pairs(group.pending_in) do
        imgui.text("  " .. tostring(inv.name) .. " invited you to their group")
        imgui.same_line()
        if imgui.button("Accept##a" .. id) then group.accept(id) end
        imgui.same_line()
        if imgui.button("Decline##d" .. id) then group.decline(id) end
    end
    for _, m in ipairs(group.list()) do
        imgui.text(string.format("  %s%s - %s", tostring(m.name),
            (m.steam_name and m.steam_name ~= m.name) and (" (" .. m.steam_name .. ")") or "", member_line(m)))
        imgui.same_line()
        if imgui.button("Remove##r" .. m.id) then group.remove(m.id) end
    end
    for id, inv in pairs(group.pending_out) do
        imgui.text(string.format("  %s - invited, waiting for them to accept in the mod", tostring(inv.name)))
        imgui.same_line()
        if imgui.button("Cancel##o" .. id) then group.cancel(id) end
    end
    if imgui.tree_node("Invite a Steam friend") then
        imgui.text("Any friend works, even offline or invisible: their mod picks the invite up when they play.")
        util.try("friend picker", draw_friend_picker)
        imgui.tree_pop()
    end
    if group.count() > 0 and imgui.button("Leave group") then group.leave() end
    imgui.text("(Link Party inviting a modded hunter in game also adds them to your group.)")
end

re.on_draw_ui(function()
    if not imgui.tree_node("Wilds Seamless Co-op v" .. util.VERSION) then return end

    checkbox("Seamless Co-op on", "enabled")
    local changed, value = imgui.checkbox("Allow outsiders (SOS flares, random joiners) - pauses group sync", util.outsiders)
    if changed then
        util.outsiders = value
        util.info(value and "outsiders allowed: story, cutscene, travel and party sync paused"
            or "group only again: sync resumed")
        net.announce()
    end
    local paused = util.sync_paused()
    if paused then imgui.text("  Story / cutscene / travel sync paused: " .. paused) end
    imgui.separator()

    util.try("group panel", draw_group)
    imgui.separator()

    imgui.text("Link Party: " .. party.status)
    imgui.text("Environment Link: " .. linked.status .. (linked.auto_status ~= "" and ("  (" .. linked.auto_status .. ")") or ""))
    if imgui.button("Invite my Link Party to my environment") then util.main(linked.invite_now) end
    imgui.same_line()
    imgui.text("(the game's own Environment Link invite, same as its menu)")
    if travel.status ~= "" then imgui.text("Fast travel: " .. travel.status) end
    imgui.text("Story: " .. story.status .. "   (your progress " .. tostring(util.story_progress) .. ")")
    if cutscene.status ~= "" then imgui.text("Cutscene: " .. cutscene.status) end
    imgui.text("Quests: " .. follow.status)
    imgui.text("Mods: " .. net.status)
    imgui.text("Save backup: " .. safety.backup_status)
    if imgui.button("Back up saves now") then util.main(function() safety.backup("manual") end) end

    checkbox("Group invites also send a Steam chat invite", "steam_chat_invite")
    checkbox("Auto-invite modded Link Party members to my environment", "auto_link")
    checkbox("Verbose log", "verbose")

    if imgui.tree_node("Experimental (not working in the real game yet)") then
        imgui.text("These can freeze or crash the game. Only switch one on when testing it together, and restart")
        imgui.text("the game afterwards: a feature only hooks the game if it was on when the game started.")
        for _, t in ipairs(util.EXPERIMENTAL) do
            checkbox(t[2], t[1])
            if util.config[t[1]] ~= util.at_start(t[1]) then
                imgui.same_line()
                imgui.text("(restart the game to apply)")
            end
        end
        combo("Story sync", "story_sync", STORY_MODES, STORY_LABELS)
        imgui.tree_pop()
    end
    if imgui.tree_node("Story steps") then
        for _, line in ipairs(story.log) do imgui.text(line) end
        imgui.tree_pop()
    end
    if imgui.tree_node("Diagnostics") then
        imgui.text("Session log: " .. util.log_file())
        imgui.text(string.format("Steam friends in Wilds: %d   hello sent: %d   received: %d", net.stats.friends_in_game,
            net.stats.hello_sent, net.stats.hello_received))
        local pl = rawget(_G, "seamless_net")
        imgui.text("Plugin: " .. tostring(pl and pl.version or "missing") .. "   Steam callbacks: "
            .. tostring(pl and pl.callbacks and pl.callbacks()))
        if imgui.button("Write signatures.json") then util.main(recorder.dump) end
        if imgui.button("Run self-test (writes selftest.json)") then util.main(selftest.run_all) end
        imgui.text("Self-test: " .. selftest.summary)
        imgui.text("Learned from the game: " .. json.dump_string(util.config.learned))
        for _, line in ipairs(util.history) do imgui.text(line) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)
