-- Logging and settings shared by every module.
local util = {}

local PREFIX = "[SeamlessCoop] "
local CONFIG_FILE = "wilds_seamless_coop/config.json" -- relative to reframework/data
local LOG_SLOTS = 5                                   -- logs/session-1.log .. session-5.log, oldest overwritten

-- Bumped when a release has to reset saved settings (see load_config).
local CONFIG_VERSION = 3

util.defaults = {
    enabled = true,           -- master switch: off = the game plays exactly as without the mod (save backups still run)
    steam_chat_invite = true, -- group invites also send a Steam chat invite (reaches offline/invisible friends)
    auto_link = true,         -- send Environment Link invites to modded Link Party members in the same field
                              -- (experimental until 0.5.5; passed 3 of 3 live joins between two machines)
    -- Experimental (util.EXPERIMENTAL): not working in the real game yet. Off unless switched on, and their hooks are
    -- only installed when they are on at game start.
    follow_travel = false,     -- fast travel takes your group with you
    travel_mode = "area",      -- "warp" (same spot, falls back to "area") | "area" (join the mover's Environment Link)
    auto_follow = false,       -- accept Link Party quest invites automatically
    stay_linked = false,       -- don't drop Environment Link when a story event starts
    auto_party = false,        -- rebuild the Link Party with your group after a disconnect or a late join
    relink_after_hunt = false, -- re-invite the hunters you were linked with when a hunt ends
    lead_story = false,        -- this player leads the story (exactly one player in the party ticks it)
    story_sync = "off",        -- "off" | "dry" (log the leader's story steps only) | "on" (take them on your save)
    cutscene_sync = false,     -- start cutscenes together, skip by vote
    selftest_scan = false,     -- also write scan.json (where the game declares the routines the mod uses)
    selftest_watch = false,    -- poll selftest_request.json (automated tests only)
    selftest = false,          -- write selftest.json ~20 s after the game starts
    verbose = false,           -- extra log lines
}

-- { key, panel label } of the features that are not working in the real game yet.
util.EXPERIMENTAL = {
    { "relink_after_hunt", "Re-link after hunts" },
    { "auto_follow", "Auto-follow group quests" },
    { "auto_party", "Rebuild the Link Party with your group automatically" },
    { "follow_travel", "Fast travel together" },
    { "stay_linked", "Stay in Environment Link through story events" },
    { "cutscene_sync", "Shared cutscenes (start together, skip by vote)" },
    { "lead_story", "Lead the story (exactly one player in the group)" },
}

util.config = {}
util.migrated = false -- this start switched the experimental features off (settings from 0.5.1 or older)

-- What a setting was when the game started. Hooks are installed at start and can't be removed, so features that
-- hook the game decide from this whether to hook at all.
local at_start = {}
function util.at_start(key)
    if at_start.enabled == false then return false end
    local v = at_start[key]
    if key == "story_sync" then return v ~= nil and v ~= "off" end
    return v == true
end

-- Any experimental feature on at game start (the recorder's hooks are only needed then).
function util.any_experimental_at_start()
    for _, t in ipairs(util.EXPERIMENTAL) do
        if util.at_start(t[1]) then return true end
    end
    return util.at_start("story_sync")
end

-- Runtime only (never saved): "Allow outsiders" is off every time the game starts.
util.outsiders = false        -- the player allowed non-group hunters in: story/cutscene sync paused
util.stranger = nil           -- name of a non-group hunter in your Link Party / Environment Link, if any

-- Settings that only make sense among your own group; paused while outsiders are allowed or present.
local GROUP_ONLY = { cutscene_sync = true, follow_travel = true, auto_party = true }

-- A feature switch, honouring the master switch and the outsider pause.
local experimental_key = {}
function util.on(key)
    if util.config.enabled == false then return false end
    if GROUP_ONLY[key] and util.sync_paused() then return false end
    if next(experimental_key) == nil then
        for _, t in ipairs(util.EXPERIMENTAL) do experimental_key[t[1]] = true end
    end
    -- An experimental feature switched on during play waits for the next game start (its hooks aren't installed).
    if experimental_key[key] and not util.at_start(key) then return false end
    return util.config[key] == true
end

-- Why story/cutscene sync is paused right now, or nil.
function util.sync_paused()
    if util.outsiders then return "outsiders allowed" end
    if util.stranger then return util.stranger .. " is not in your group" end
    return nil
end

-- Effective story sync mode: "off" while the mod is off or sync is paused.
function util.story_mode()
    if util.config.enabled == false or util.sync_paused() then return "off" end
    return util.config.story_sync
end

------------------------------------------------------------------------------------------------------------------------
-- Log: panel history, re2_framework_log.txt and a per-session file (reframework/data/wilds_seamless_coop/logs)
------------------------------------------------------------------------------------------------------------------------

util.history = {}
local file_lines, file_dirty, file_name, next_flush = {}, false, nil, 0
local MAX_FILE_LINES = 4000

local function push(level, msg)
    local line = os.date("%H:%M:%S ") .. msg
    table.insert(util.history, 1, line)
    if #util.history > 40 then table.remove(util.history) end
    if level == "warn" then log.warn(PREFIX .. msg) else log.info(PREFIX .. msg) end
    if #file_lines < MAX_FILE_LINES then
        file_lines[#file_lines + 1] = os.date("%Y-%m-%d %H:%M:%S ") .. (level == "warn" and "WARN " or "") .. msg
        file_dirty = true
    end
end

function util.info(msg) push("info", msg) end
function util.warn(msg)
    push("warn", msg)
    util.flush_log(true)
end
function util.debug(msg)
    if util.config.verbose then push("info", msg) end
end
-- Only to the session file (diagnostics too noisy for the panel).
function util.trace(msg)
    if #file_lines < MAX_FILE_LINES then
        file_lines[#file_lines + 1] = os.date("%Y-%m-%d %H:%M:%S ") .. "trace " .. msg
        file_dirty = true
    end
end

-- Written to disk at once: if the game crashes right after, the log still shows what the mod was doing.
function util.breadcrumb(msg)
    util.trace(msg)
    util.flush_log(true)
end

function util.log_file() return file_name and ("reframework/data/" .. file_name) or "(not written yet)" end

function util.flush_log(force)
    if not file_dirty or (not force and os.clock() < next_flush) then return end
    next_flush = os.clock() + 1
    if not file_name then
        local slot = (tonumber(util.config.log_slot) or 0) % LOG_SLOTS + 1
        util.config.log_slot = slot
        file_name = "wilds_seamless_coop/logs/session-" .. slot .. ".log"
        util.save_config()
    end
    file_dirty = false
    local text = table.concat(file_lines, "\n") .. "\n"
    local ok = rawget(_G, "fs") and pcall(fs.write, file_name, text)
    if not ok then pcall(json.dump_file, file_name .. ".json", file_lines) end
end

------------------------------------------------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------------------------------------------------

function util.load_config()
    local saved = json.load_file(CONFIG_FILE) or {}
    for k, v in pairs(util.defaults) do
        if saved[k] == nil then util.config[k] = v else util.config[k] = saved[k] end
    end
    util.config.learned = type(saved.learned) == "table" and saved.learned or {}
    util.config.group = type(saved.group) == "table" and saved.group or {}
    util.config.group.members = type(util.config.group.members) == "table" and util.config.group.members or {}
    util.config.log_slot = saved.log_slot
    util.config.debug_no_reads = saved.debug_no_reads == true
    util.config.debug_no_net_reads = saved.debug_no_net_reads == true -- hidden: crash bisecting only, no panel switch
    -- 0.4.x learned a developer-only stage getter on some PCs; the field manager's own getter is the right one.
    if type(util.config.learned.stage_getter) == "table" and util.config.learned.stage_getter.method == "getDevCurrentStage" then
        util.config.learned.stage_getter = nil
    end
    -- 0.5.1 and older had every feature on, and some of them crashed the game: start from the safe defaults once.
    if next(saved) ~= nil and (tonumber(saved.config_version) or 1) < 2 then
        for _, t in ipairs(util.EXPERIMENTAL) do util.config[t[1]] = false end
        util.config.story_sync = "off"
        util.config.travel_mode = "area"
        util.migrated = true
    end
    -- 0.5.5: auto_link left the experimental list and is on by default; switch it on once for older settings.
    util.auto_link_enabled = next(saved) ~= nil and (tonumber(saved.config_version) or 1) < 3
    if util.auto_link_enabled then util.config.auto_link = true end
    util.config.config_version = CONFIG_VERSION
    for k, v in pairs(util.config) do at_start[k] = v end
end

function util.save_config()
    -- The hidden bisect switches are only written while on, so they don't show up in everyone's config.json.
    local out = {}
    for k, v in pairs(util.config) do out[k] = v end
    if not out.debug_no_reads then out.debug_no_reads = nil end
    if not out.debug_no_net_reads then out.debug_no_net_reads = nil end
    json.dump_file(CONFIG_FILE, out)
end

-- Wall-clock seconds since the game started (MSVC's clock() is wall time on Windows).
function util.now() return os.clock() end

-- Run fn(...) and log instead of throwing; returns ok, result.
function util.try(label, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then util.warn(label .. " failed: " .. tostring(res)) end
    return ok, res
end

-- Work for the game's main thread (panel buttons run on the render thread, where touching the game can crash it).
util.story_progress = nil -- refreshed on the main thread, shown in the panel
local main_queue = {}
function util.main(fn) main_queue[#main_queue + 1] = fn end
function util.take_main_queue()
    local q = main_queue
    main_queue = {}
    return q
end

return util
