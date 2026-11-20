-- Logging and settings shared by every module.
local util = {}

local PREFIX = "[SeamlessCoop] "
local CONFIG_FILE = "wilds_seamless_coop/config.json" -- relative to reframework/data
local LOG_SLOTS = 5                                   -- logs/session-1.log .. session-5.log, oldest overwritten

util.defaults = {
    enabled = true,           -- master switch: off = the game plays exactly as without the mod (save backups still run)
    follow_travel = true,     -- fast travel takes your group with you
    travel_mode = "warp",     -- "warp" (same spot, falls back to "area") | "area" (join the mover's Environment Link)
    steam_chat_invite = true, -- group invites also send a Steam chat invite (reaches offline/invisible friends)
    auto_follow = true,       -- accept Link Party quest invites automatically
    stay_linked = true,       -- don't drop Environment Link when a story event starts
    link_in_story = true,     -- allow Environment Link in story stages once the game has unlocked it
    auto_link = true,         -- send Environment Link invites to modded Link Party members when you are in a field together
    auto_accept_link = true,  -- accept Environment Link invites from Link Party members automatically
    auto_party = true,        -- rebuild the Link Party with your group after a disconnect or a late join
    relink_after_hunt = true, -- re-invite the hunters you were linked with when a hunt ends
    keep_visible = true,      -- keep other hunters drawn during story segments
    early_unlock = true,      -- multiplayer and Environment Link from the start of the story (no save changes)
    lead_story = false,       -- this player leads the story (exactly one player in the party ticks it)
    story_sync = "dry",       -- "off" | "dry" (log the leader's story steps only) | "on" (take them on your save)
    cutscene_sync = true,     -- start cutscenes together, skip by vote
    selftest_scan = false,    -- also write scan.json (where the game declares the routines the mod uses)
    selftest_watch = false,   -- poll selftest_request.json (automated tests only)
    selftest = false,         -- write selftest.json ~20 s after the game starts
    verbose = false,          -- extra log lines
}

util.config = {}

-- Runtime only (never saved): "Allow outsiders" is off every time the game starts.
util.outsiders = false        -- the player allowed non-group hunters in: story/cutscene sync paused
util.stranger = nil           -- name of a non-group hunter in your Link Party / Environment Link, if any

-- Settings that only make sense among your own group; paused while outsiders are allowed or present.
local GROUP_ONLY = { cutscene_sync = true, follow_travel = true, auto_party = true }

-- A feature switch, honouring the master switch and the outsider pause.
function util.on(key)
    if util.config.enabled == false then return false end
    if GROUP_ONLY[key] and util.sync_paused() then return false end
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
function util.warn(msg) push("warn", msg) end
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

function util.log_file() return file_name and ("reframework/data/" .. file_name) or "(not written yet)" end

function util.flush_log(force)
    if not file_dirty or (not force and os.clock() < next_flush) then return end
    next_flush = os.clock() + 5
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
    -- 0.4.x learned a developer-only stage getter on some PCs; the field manager's own getter is the right one.
    if type(util.config.learned.stage_getter) == "table" and util.config.learned.stage_getter.method == "getDevCurrentStage" then
        util.config.learned.stage_getter = nil
    end
end

function util.save_config()
    json.dump_file(CONFIG_FILE, util.config)
end

-- Wall-clock seconds since the game started (MSVC's clock() is wall time on Windows).
function util.now() return os.clock() end

-- Run fn(...) and log instead of throwing; returns ok, result.
function util.try(label, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then util.warn(label .. " failed: " .. tostring(res)) end
    return ok, res
end

return util
