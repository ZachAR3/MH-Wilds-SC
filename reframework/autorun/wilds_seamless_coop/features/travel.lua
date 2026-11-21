-- Fast travel together: when a group member fast travels (or goes back to base), everyone else in the group goes too.
--   mover:    the game's own warp (app.mcFastTravel.warpPlayer(hunter, stage, position, rotation, WarpInfo, gimmick))
--             is watched; its stage, position, rotation and warp options are sent to the group.
--   follower: joins the mover's Environment Link, which loads the mover's area. (0.5.0 replayed the warp itself
--             with null game objects; that was removed in 0.5.2 until it can be tested live.)
-- Last mover wins. Never during quests, cutscenes or another warp.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")
local recorder = require("wilds_seamless_coop.recorder")
local net = require("wilds_seamless_coop.net")
local group = require("wilds_seamless_coop.features.group")
local cutscene = require("wilds_seamless_coop.features.cutscene")

local travel = { status = "" }

local JOIN_KEY = "app.Net_Party.app.NetworkRequestManager.INet_LinkParty.joinPartySync"
local GIVE_UP, AREA_CHECK = 60, 20

local seq = 0
local last_seen = {}  -- [steam id] = last travel seq handled
local job             -- { from, name, hunter, msg, at, until, mode, done_at }
local pending_out     -- travel captured in the pre-hook, completed in the post-hook

local function addr(o)
    local ok, a = pcall(function() return o:get_address() end)
    return ok and a or nil
end

local function vec3_of(v)
    if v == nil then return nil end
    local ok, r = pcall(function() return { x = v.x, y = v.y, z = v.z } end)
    if ok and type(r.x) == "number" then return r end
    return nil
end

local function quat_of(q)
    if q == nil then return nil end
    local ok, r = pcall(function() return { x = q.x, y = q.y, z = q.z, w = q.w } end)
    if ok and type(r.w) == "number" then return r end
    return nil
end

local function call0(o, name)
    local ok, v = pcall(o.call, o, name)
    if ok then return v end
    return nil
end

------------------------------------------------------------------------------------------------------------------------
-- Mover: capture our own fast travel
------------------------------------------------------------------------------------------------------------------------

local function on_warp(args)
    pending_out = nil
    if not util.on("follow_travel") then return end
    local hunter = game.arg_obj(args, 1)
    local me = game.master_hunter()
    if not (hunter and me and addr(hunter) == addr(me)) then return end
    local info = game.arg_obj(args, 5)
    local gimmick = game.arg_obj(args, 6)
    pending_out = {
        this = game.arg_this(args),
        stage = game.arg_int(args, 2),
        pos = vec3_of(sdk.to_valuetype(args[2 + 3], "via.vec3")),
        rot = quat_of(sdk.to_valuetype(args[2 + 4], "via.Quaternion")),
        info = info and {
            b = call0(info, "get_BeginSec"), v = call0(info, "get_VisibleSec"), e = call0(info, "get_EndSec"),
            o = call0(info, "get_Option"), m = call0(info, "get_IsPlayerButtonMask"),
            s = call0(info, "get_WarpSituationType"), n = call0(info, "get_IsNearyWarp"),
        },
        gimmick = gimmick and gimmick:get_type_definition():get_full_name() or nil,
    }
end

local function after_warp(retval)
    local p = pending_out
    pending_out = nil
    if not p then return retval end
    -- the warp's own fields are the most reliable read of what was requested
    if p.this then
        p.pos = vec3_of(p.this:get_field("_WarpPosition")) or p.pos
        p.rot = quat_of(p.this:get_field("_CharacterRotation")) or p.rot
        local st = p.this:get_field("_TargetStage")
        if type(st) == "number" then p.stage = st end
    end
    if not p.pos then
        util.warn("fast travel seen but its destination could not be read; your group will join your area instead")
    end
    seq = seq + 1
    local msg = { t = "travel", seq = seq, stage = p.stage, pos = p.pos, rot = p.rot, info = p.info }
    util.trace("travel out " .. json.dump_string(msg) .. " gimmick=" .. tostring(p.gimmick))
    local n = 0
    for id in pairs(util.config.group.members) do
        if net.contacts[id] then
            net.send(id, msg)
            n = n + 1
        end
    end
    if n > 0 then
        travel.status = "you travelled; your group follows"
        util.info(string.format("fast travel to stage %s sent to %d group member(s)", tostring(p.stage), n))
    end
    return retval
end

------------------------------------------------------------------------------------------------------------------------
-- Follower
------------------------------------------------------------------------------------------------------------------------

local function on_travel(c, msg)
    if not group.is_member(c.id) or not util.on("follow_travel") then return end
    if type(msg.seq) ~= "number" or (last_seen[c.id] and msg.seq <= last_seen[c.id] and msg.seq > 1) then return end
    last_seen[c.id] = msg.seq
    job = { from = c.id, name = c.hunter_name or "partner", hunter = c.hunter, msg = msg, at = util.now() + 1,
        ["until"] = util.now() + GIVE_UP, mode = "area" }
    travel.status = "following " .. job.name .. "'s fast travel"
end

local function busy()
    if game.in_session(game.SESSION.QUEST()) then return "in a quest" end
    local mm = game.mission_manager()
    if mm and (call0(mm, "isFastTravel") or call0(mm, "get_RequestFastTravel")) then return "already travelling" end
    local ft = game.fast_travel()
    if ft and call0(ft, "get_IsWarp") then return "already warping" end
    if cutscene.status ~= "" then return "in a cutscene" end
    if (game.current_stage() or -1) < 0 then return "loading" end
    return nil
end

-- Join the mover's Environment Link: the game loads their area for us.
local function join_area(hunter)
    local party = game.party()
    local m = game.method("app.Net_Party", "app.NetworkRequestManager.INet_LinkParty.joinPartySync")
    if not (party and m and game.guid_valid(hunter)) then return false end
    local values = recorder.values(JOIN_KEY, { [1] = hunter })
    return util.try("join area", recorder.call, party, m, values)
end

function travel.update()
    if not job then return end
    local now = util.now()
    if now < job.at then return end
    if now > job["until"] then
        travel.status = "couldn't follow " .. job.name .. " (" .. tostring(busy() or "timed out") .. ")"
        util.info(travel.status)
        job = nil
        return
    end
    if job.done_at then
        -- check we arrived; if not, fall back to joining their area once
        if now - job.done_at < AREA_CHECK then return end
        local here = game.current_stage()
        if here ~= job.msg.stage then
            if job.mode == "area_done" then
                travel.status = "couldn't reach " .. job.name .. "'s area (stage " .. tostring(job.msg.stage) .. ")"
                util.info(travel.status)
                job = nil
                return
            end
            util.info("not in " .. job.name .. "'s area after the warp; joining their Environment Link instead")
            job.mode, job.done_at = "area", nil
            return
        end
        travel.status = "followed " .. job.name
        job = nil
        return
    end
    local why = busy()
    if why then
        travel.status = "will follow " .. job.name .. " when not " .. why
        job.at = now + 1
        return
    end
    if job.mode == "area" then
        if game.current_stage() == job.msg.stage then
            job = nil
            return
        end
        join_area(job.hunter)
        job.mode, job.done_at = "area_done", now
    else
        job = nil
    end
end

function travel.init()
    if not util.at_start("follow_travel") then return end
    net.on("travel", on_travel, true)
    game.hook("app.mcFastTravel", "warpPlayer", on_warp, after_warp)
end

return travel
