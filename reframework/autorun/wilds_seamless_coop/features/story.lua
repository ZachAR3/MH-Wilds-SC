-- Story lockstep: one player leads the story ("Lead the story" in the panel); every follower at the same story point
-- takes the same steps on their own save, through the same game routines.
--
-- How: the leader's game calls a story routine (load a mission, activate an objective, clear an objective, set a
-- mission flag) -> the mod sends {routine, plain arguments} to the followers -> each follower's mod calls the same
-- routine on its own game. Only routines whose arguments are plain values are mirrored, and every routine names its
-- mission explicitly. Nothing is invented: a follower only ever repeats what the leader's game itself did.
--
-- Safety:
--   * followers mirror only while their story progress equals the leader's (a save ahead or behind is never touched);
--   * never during a quest (hunts are shared by the game itself; quest objectives and results are never mirrored);
--   * a save backup is made first - no backup, no mirroring (features/safety.lua);
--   * mode "dry" (the default) only logs what would be mirrored.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local net = require("wilds_seamless_coop.net")
local safety = require("wilds_seamless_coop.features.safety")

local story = { log = {}, status = "" }

-- { type, routine, target }: target "manager" = the MissionManager; "controller" = the MissionController of the
-- mission given as the routine's first argument. Signatures verified against the game (TDB 81).
-- (MissionManager.callActivateObjective would belong here, but REFramework nightly 01240 cannot hook it.)
local STEPS = {
    { "app.MissionManager", "reqLoadMission", "manager" },               -- (MissionIDList.ID)
    { "app.MissionManager", "setEnableMissionDynamicFlag", "manager" },  -- (MissionIDList.ID, Int32, Boolean)
    { "app.MissionController", "setClearObjective", "controller" },      -- (MissionIDList.ID, Int32, Boolean)
}

local by_key = {}
local depth = 0 -- > 0 while inside a watched routine: only the outermost call is a step
local replaying = false
local warned = nil

local function key_of(s) return s[1] .. "." .. s[2] end

local function note(line)
    table.insert(story.log, 1, os.date("%H:%M:%S ") .. line)
    if #story.log > 30 then table.remove(story.log) end
end

local function in_quest() return game.in_session(game.SESSION.QUEST(), true) end

------------------------------------------------------------------------------------------------------------------------
-- Leader: report the game's own story steps
------------------------------------------------------------------------------------------------------------------------

-- Plain-value arguments of a hooked call, or nil if any argument is an object (those calls are never mirrored).
local function plain_args(args, m)
    local out = {}
    for i, td in ipairs(m:get_param_types() or {}) do
        local t = td:get_full_name()
        if t == "System.Boolean" then
            out[i] = game.arg_bool(args, i)
        elseif td:is_value_type() and t ~= "System.Guid" then
            out[i] = game.arg_int(args, i)
        else
            return nil
        end
    end
    return out
end

local function report(step, args, m)
    if util.config.verbose then util.debug("story routine " .. step[2] .. " " .. json.dump_string(plain_args(args, m) or "objects")) end
    if util.story_mode() == "off" or replaying or net.peer_count() == 0 or not net.is_leader() then return end
    if in_quest() then return end
    local values = plain_args(args, m)
    if not values then return end
    net.broadcast({
        t = "step",
        key = key_of(step),
        args = values,
        progress = game.story_progress(), -- the leader's progress *before* this step
    })
    note("you: " .. step[2] .. " " .. json.dump_string(values))
end

------------------------------------------------------------------------------------------------------------------------
-- Follower: take the same step
------------------------------------------------------------------------------------------------------------------------

local function target(kind, values)
    local mm = game.mission_manager()
    if kind == "manager" or mm == nil then return mm end
    local ok, controller = pcall(mm.call, mm, "getEnableMissionController", values[1])
    if ok then return controller end
    return nil
end

local function refuse(why)
    if warned ~= why then
        warned = why
        util.warn("story not mirrored: " .. why)
        note("not mirrored: " .. why)
    end
end

local function on_step(peer, msg)
    if util.story_mode() == "off" or net.leader() ~= peer then return end
    local step = by_key[msg.key]
    if not step or type(msg.args) ~= "table" then return end

    local mine = tonumber(game.story_progress())
    if mine == nil or mine ~= tonumber(msg.progress) then
        return refuse(string.format("your story progress is %s, %s's is %s (must be equal)",
            tostring(mine), peer.name, tostring(msg.progress)))
    end
    if in_quest() then return refuse("you are in a quest") end

    local m = game.method(step[1], step[2], #msg.args)
    if not m then return end
    local values = {}
    for i, td in ipairs(m:get_param_types() or {}) do
        local v = msg.args[i]
        if td:get_full_name() == "System.Boolean" then
            if type(v) ~= "boolean" then return end
        else
            v = math.tointeger(v)
            if v == nil then return end
        end
        values[i] = v
    end
    local obj = target(step[3], values)
    if not obj then
        note("can't mirror " .. step[2] .. " " .. json.dump_string(msg.args) .. ": mission not loaded here")
        return
    end

    if util.story_mode() == "dry" then
        note("[dry run] would mirror " .. step[2] .. " " .. json.dump_string(msg.args))
        return
    end
    if not safety.ensure_backup("story") then return refuse("the save backup failed (" .. safety.backup_status .. ")") end
    warned = nil
    replaying = true
    local ok = util.try("mirror " .. step[2], game.call, obj, m, values)
    replaying = false
    note((ok and "mirrored " or "FAILED ") .. step[2] .. " " .. json.dump_string(msg.args))
end

------------------------------------------------------------------------------------------------------------------------

function story.update()
    local leader = net.leader()
    if safety.tripped then
        story.status = "OFF - the game's cheat check fired at " .. safety.tripped
    elseif net.peer_count() == 0 then
        story.status = "no co-op partner"
    elseif leader == "self" then
        story.status = "you lead the story"
    elseif leader then
        story.status = "following " .. leader.name .. "'s story"
    else
        story.status = "nobody leads: one player ticks 'Lead the story'"
    end
end

function story.init()
    if not (util.at_start("lead_story") or util.at_start("story_sync")) then return end
    for _, step in ipairs(STEPS) do
        by_key[key_of(step)] = step
        game.hook(step[1], step[2], function(args, m)
            depth = depth + 1
            if depth == 1 then util.try("report " .. step[2], report, step, args, m) end
        end, function(retval)
            depth = math.max(0, depth - 1)
            return retval
        end)
    end
    net.on("step", on_step)
end

return story
