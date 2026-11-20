-- Early unlock: Environment Link before the story unlocks it (mission 001075).
--
-- Normally online play unlocks at the end of mission 001040 (story progress 250) and Environment Link at 001075
-- (party-sync progress > 0). This only changes the *answers* of the game's own story gates while the story is the
-- reason they say no. It never writes story flags, progress or anything else to the save, and the progress values
-- the game sends to other players stay the real ones. Privacy / platform / connection checks are never touched
-- (e.g. app.savedata.cPrivacyParam.isEnableOnlinePlay is the player's own privacy setting and is left alone).
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")

local unlock = { hooked = {} }

local link_locked = false -- refreshed by update(); hooks stay cheap

local function active() return util.on("early_unlock") end

function unlock.update()
    local sync_progress = tonumber(game.party_sync_progress())
    link_locked = sync_progress ~= nil and sync_progress <= 0
end

-- True when Environment Link is still locked by the story and early unlock is on (used by features/linked.lua).
function unlock.link_overridden() return active() and link_locked end

local function gate(owner, name, post)
    if game.hook(owner, name, nil, post) then unlock.hooked[#unlock.hooked + 1] = owner .. "." .. name end
end

-- Name of enum value `v` of enum type `td`, or nil.
local function enum_name(td, v)
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local ok, data = pcall(f.get_data, f, nil)
            if ok and data == v then return f:get_name() end
        end
    end
    return nil
end

-- Error code used to refuse a join: the first enum value whose name says "not allowed", else none (no refusal).
local refusal
function unlock.refusal_code(rt)
    if refusal ~= nil then return refusal or nil end
    refusal = false
    local names = {}
    for _, f in ipairs(rt:get_fields()) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            if ok and type(v) == "number" then names[#names + 1] = { f:get_name(), v } end
        end
    end
    local list = {}
    for _, n in ipairs(names) do list[#list + 1] = n[1] .. "=" .. n[2] end
    util.trace(rt:get_full_name() .. ": " .. table.concat(list, ", "))
    for _, want in ipairs({ "REJECT", "DENY", "NOT_PERMIT", "PERMISSION", "BLOCK", "PRIVATE", "FULL" }) do
        for _, n in ipairs(names) do
            if n[1]:upper():find(want) then
                refusal = n[2]
                util.info("joins from outside the group are refused with " .. n[1])
                return refusal
            end
        end
    end
    util.warn("no refusal code found; outsiders can't be refused, only warned about")
    return nil
end

function unlock.init()
    -- (The online-menu gate app.MenuUtil.isEnableOnlineMenu cannot be hooked by REFramework nightly 01240, so the
    -- multiplayer menu itself still opens at its normal story point; only the Environment Link gates are covered.)
    -- "Environment Link not available: story not cleared" -> no.
    gate("app.MissionUtil", "isLinkNotStoryClear", function(retval)
        if active() and link_locked then return game.FALSE end
        return retval
    end)
    -- Accepting an Environment Link join:
    --   * closed group (outsiders not allowed, group not empty): a hunter outside the group is refused;
    --   * early unlock: only a story-progress refusal (ERR_STORY) is turned into success.
    -- Every other error (full party, blocked player, connection) is kept.
    local joiner
    if game.hook("app.Net_Party", "isEnableJoinAcceptPartySync", function(args)
        joiner = game.arg_guid(args, 1)
    end, function(retval, m)
        local rt = m:get_return_type()
        local code = sdk.to_int64(retval) & 0xFFFFFFFF
        local ok_code = rt and (game.enum(rt:get_full_name(), "NONE", nil) or game.enum(rt:get_full_name(), "SUCCESS", 0))
        if code == ok_code and unlock.refuse_join and rt then
            local refuse, why = unlock.refuse_join(joiner)
            local err = refuse and unlock.refusal_code(rt)
            if err then
                util.info("Environment Link join refused: " .. tostring(why))
                return sdk.to_ptr(err)
            end
        end
        if not active() then return retval end
        local name = rt and enum_name(rt, code)
        if name and name:find("STORY") then
            util.info("Environment Link join allowed despite " .. name)
            return sdk.to_ptr(ok_code)
        end
        return retval
    end) then unlock.hooked[#unlock.hooked + 1] = "app.Net_Party.isEnableJoinAcceptPartySync" end
    util.info("early unlock gates: " .. table.concat(unlock.hooked, ", "))
end

return unlock
