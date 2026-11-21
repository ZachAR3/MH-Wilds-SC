-- Safety net:
--   * save backups - a copy of the Steam save folder before the mod changes anything on a save: once per game start,
--     and again before story steps are mirrored (at most every BACKUP_EVERY seconds). Kept in
--     reframework/data/wilds_seamless_coop/save_backups (newest 20). No backup -> no mirroring.
--   * tripwire - if the game's own quest cheat check ever fires, say so loudly and switch story sync off.
--     The check itself is never blocked or changed.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")

local safety = { backup_status = "no backup yet", tripped = nil }

local BACKUP_EVERY = 15 * 60
local last_backup = nil
local startup_done = false

local function plugin() return rawget(_G, "seamless_net") end

-- Copy the save folder now. Returns true on success.
function safety.backup(tag)
    local p = plugin()
    if not (p and p.backup_saves) then
        safety.backup_status = "FAILED: seamless_net.dll (1.1.0 or newer) is not loaded"
        return false
    end
    local ok, result = p.backup_saves(tag)
    if ok then
        last_backup = util.now()
        safety.backup_status = os.date("%H:%M:%S ") .. tostring(result)
        util.info("saves backed up to " .. tostring(result))
    else
        safety.backup_status = "FAILED: " .. tostring(result)
        util.warn("save backup failed: " .. tostring(result))
    end
    return ok
end

-- True when a recent backup exists (making one if needed). Called before anything is changed on the save.
function safety.ensure_backup(tag)
    if last_backup and util.now() - last_backup < BACKUP_EVERY then return true end
    return safety.backup(tag)
end

local function trip(what)
    if safety.tripped then return end
    safety.tripped = os.date("%H:%M:%S ") .. what
    util.config.story_sync = "off"
    util.save_config()
    util.warn("THE GAME'S CHEAT CHECK FIRED (" .. what .. "). Story sync is now off. Stop playing online with the "
        .. "mod and send the log.")
end

function safety.update()
    if startup_done then return end
    local p = plugin()
    if not p then
        startup_done = true
        return
    end
    if p.available() then
        startup_done = true
        safety.backup("start")
    end
end

function safety.init()
    -- The tripwire only matters while story steps can be mirrored.
    if not util.at_start("story_sync") then return end
    game.hook("app.Net_SessionService", "reportCheatQuest", function() trip("reportCheatQuest") end)
end

return safety
