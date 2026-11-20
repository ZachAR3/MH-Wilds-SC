-- Wilds Seamless Co-op: play Monster Hunter Wilds' whole story together, like a seamless co-op mod.
--   * a permanent co-op group (invite any Steam friend once, offline/invisible included); the Link Party and
--     Environment Link are rebuilt automatically after disconnects and late joins;
--   * fast travel takes the group with you; quests are followed automatically;
--   * story lockstep: followers take the leader's story steps on their own save (features/story.lua);
--   * shared cutscenes: start together, skip by vote (features/cutscene.lua);
--   * "Allow outsiders" for SOS flares / random joiners pauses everything that syncs story.
-- Built on the game's own Link Party / Environment Link / quest-invite / fast-travel / story routines, plus a private
-- Steam P2P channel between the mods (reframework/plugins/seamless_net.dll). It never creates or edits quests,
-- rewards, items or leaderboard data, and backs up the save folder before it changes anything (features/safety.lua).
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")
local net = require("wilds_seamless_coop.net")
local group = require("wilds_seamless_coop.features.group")
local party = require("wilds_seamless_coop.features.party")
local follow = require("wilds_seamless_coop.features.follow")
local linked = require("wilds_seamless_coop.features.linked")
local travel = require("wilds_seamless_coop.features.travel")
local visible = require("wilds_seamless_coop.features.visible")
local unlock = require("wilds_seamless_coop.features.unlock")
local story = require("wilds_seamless_coop.features.story")
local cutscene = require("wilds_seamless_coop.features.cutscene")
local safety = require("wilds_seamless_coop.features.safety")
local selftest = require("wilds_seamless_coop.selftest")

util.VERSION = "0.5.0"
local TICK = 0.25 -- seconds between feature updates
local FEATURES = { net, safety, group, party, follow, linked, travel, visible, unlock, story, cutscene, selftest }

util.load_config()
recorder.init()
for _, f in ipairs(FEATURES) do
    if f.init then util.try("init", f.init) end
end
local p = rawget(_G, "seamless_net")
util.info("v" .. util.VERSION .. " loaded (plugin " .. tostring(p and p.version or "missing") .. ")")

local next_tick = 0
re.on_frame(function()
    local now = util.now()
    if now >= next_tick then
        next_tick = now + TICK
        for i, f in ipairs(FEATURES) do util.try("update " .. i, f.update) end
        util.flush_log()
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

local ADVANCED = {
    { "steam_chat_invite", "Group invites also send a Steam chat invite" },
    { "auto_party", "Rebuild the Link Party with your group automatically" },
    { "auto_follow", "Auto-follow group quests" },
    { "auto_link", "Auto-invite to Environment Link" },
    { "auto_accept_link", "Auto-accept Environment Link invites" },
    { "stay_linked", "Stay in Environment Link through story events" },
    { "link_in_story", "Allow Environment Link in story missions" },
    { "relink_after_hunt", "Re-link after hunts" },
    { "keep_visible", "Keep party members visible" },
    { "early_unlock", "Environment Link before the story unlocks it" },
    { "cutscene_sync", "Shared cutscenes (start together, skip by vote)" },
    { "verbose", "Verbose log" },
}
local STORY_MODES = { "off", "dry", "on" }
local STORY_LABELS = { "Off", "Dry run (log only, no save changes)", "On (take the leader's story steps)" }
local TRAVEL_MODES = { "warp", "area" }
local TRAVEL_LABELS = { "Warp to the same spot (falls back to joining their area)", "Join their area" }

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
    local changed, value = imgui.checkbox("Allow outsiders (SOS flares, random joiners) - pauses story sync", util.outsiders)
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

    checkbox("Lead the story (exactly one player in the group ticks this)", "lead_story")
    combo("Story sync", "story_sync", STORY_MODES, STORY_LABELS)
    checkbox("Fast travel together", "follow_travel")
    if util.config.follow_travel then combo("Fast travel follow", "travel_mode", TRAVEL_MODES, TRAVEL_LABELS) end
    imgui.separator()

    imgui.text("Link Party: " .. party.status)
    imgui.text("Environment Link: " .. linked.status .. (linked.auto_status ~= "" and ("  (" .. linked.auto_status .. ")") or ""))
    if travel.status ~= "" then imgui.text("Fast travel: " .. travel.status) end
    imgui.text("Story: " .. story.status .. "   (your progress " .. tostring(game.story_progress()) .. ")")
    if cutscene.status ~= "" then imgui.text("Cutscene: " .. cutscene.status) end
    imgui.text("Quests: " .. follow.status)
    imgui.text("Mods: " .. net.status)
    imgui.text("Save backup: " .. safety.backup_status)
    if imgui.button("Back up saves now") then safety.backup("manual") end

    if imgui.tree_node("Advanced settings") then
        for _, t in ipairs(ADVANCED) do checkbox(t[2], t[1]) end
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
        if imgui.button("Write signatures.json") then util.try("dump", recorder.dump) end
        if imgui.button("Run self-test (writes selftest.json)") then util.try("self-test", selftest.run_all) end
        imgui.text("Self-test: " .. selftest.summary)
        imgui.text("Early-unlock gates found: " .. (#unlock.hooked > 0 and table.concat(unlock.hooked, ", ") or "none"))
        imgui.text("Learned from the game: " .. json.dump_string(util.config.learned))
        for _, line in ipairs(util.history) do imgui.text(line) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)
