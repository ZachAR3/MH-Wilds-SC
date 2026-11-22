-- Watches the game's own calls to the network methods the features drive, so the mod can
--   * reuse the exact flag/enum values the game passes (learned once, saved in config.learned), and
--   * write a signature dump + call log that makes a game update easy to fix.
-- Read-only: every hook lets the original method run unchanged.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")

local recorder = {}

recorder.WATCHED = {
    { "app.NetworkRequestManager", "acceptInviteLinkPartyQuest" },
    { "app.NetworkRequestManager", "acceptInviteLinkPartySync" },
    { "app.NetworkRequestManager", "inviteLinkPartySync" },
    { "app.NetworkRequestManager", "inviteLinkPartyQuest" },
    { "app.NetworkRequestManager", "leaveLinkPartySync" },
    { "app.Net_Party", "app.NetworkRequestManager.INet_LinkParty.joinPartySync" },
    { "app.Net_Party", "app.NetworkRequestManager.INet_LinkParty.leaveLinkPartySync" },
    { "app.Net_Party", "addQuestInviteNotify" },
    { "app.Net_Party", "checkAndAcceptSyncQuest" },
    -- Link Party (whole party, not Environment Link): used to rebuild the party after a disconnect / late join
    { "app.NetworkRequestManager", "inviteLinkParty" },
    { "app.NetworkRequestManager", "acceptInviteLinkParty" },
    { "app.NetworkRequestManager", "requestLinkRecruitJoin" },
    { "app.NetworkRequestManager", "requestLinkRecruitUpdate" },
    { "app.NetworkRequestManager", "joinSession" },
    { "app.NetworkRequestManager", "leaveSession" },
    -- the game's menu-level requests (what its own menus call; the mod uses these now)
    { "app.cGUINetworkRequest", "reqLinqPartyJoinWindow" },
    { "app.cGUINetworkRequest", "reqLinkPartySyncInvite" },
    { "app.cGUINetworkRequest", "reqLinqPartySyncInviteWindow" },
    { "app.cGUINetworkRequest", "reqLinqPartySyncJoinWindow" },
    { "app.cGUINetworkRequest", "reqLinqPartyInvite" },
    { "app.cGUINetworkRequest", "reqLinqPartyInviteWindow" },
    { "app.cGUINetworkRequest", "reqLinqPartyQuestJoinWindow" },
}

-- Types whose method signatures go into the dump.
local DUMP_TYPES = {
    "app.NetworkRequestManager", "app.Net_Party", "app.NetworkManager", "app.Net_UserInfoManager", "app.Net_UserInfo",
    "app.MissionManager", "app.cQuestDirector", "app.DemoMediator", "app.MissionUtil", "app.GUIManager",
    "app.MissionController", "app.cStoryFsmController", "app.cGUINetworkRequest", "app.MenuUtil",
    "app.Net_SessionService",
}

recorder.calls = {}   -- most recent first
recorder.mine = false -- true while the mod itself is calling, so its own calls are not "learned"

-- Plain Lua value of parameter i (decided by its declared type, never by guessing at the raw value).
-- Static methods have no `this`: their parameter i is args[1 + i], so the helpers get a shifted view.
local function decode(raw, i, td, static)
    local args = raw
    if static then args = setmetatable({}, { __index = function(_, k) return raw[k - 1] end }) end
    local t = td:get_full_name()
    if t == "System.Guid" then return game.arg_guid(args, i) end
    if t == "System.Nullable`1<System.Guid>" then return game.arg_nullable_guid(args[2 + i]) end
    if t == "System.Boolean" then return game.arg_bool(args, i) end
    if td:is_value_type() then return game.arg_int(args, i) end -- ints and enums
    local obj = game.arg_obj(args, i)
    if obj == nil then return "null" end
    return "<" .. obj:get_type_definition():get_full_name() .. ">"
end

local function watch(type_name, name)
    local key = type_name .. "." .. name
    game.hook(type_name, name, function(args, m)
        local ok, err = pcall(function()
            local ptypes, values, learned = {}, {}, {}
            for i, td in ipairs(m:get_param_types() or {}) do
                ptypes[i] = td:get_full_name()
                values[i] = decode(args, i, td, m:is_static())
                -- Keys are strings so the sparse table survives the JSON round trip.
                if ptypes[i] ~= "System.Guid" and type(values[i]) ~= "string" then learned[tostring(i)] = values[i] end
            end
            table.insert(recorder.calls, 1, { key = key, by_mod = recorder.mine, types = ptypes, values = values })
            if #recorder.calls > 60 then table.remove(recorder.calls) end
            -- Remember the flag/enum values the game itself passes, for when the mod makes the same call.
            if not recorder.mine then util.config.learned[key] = learned end
            util.trace(key .. (recorder.mine and " (mod) " or " (game) ") .. json.dump_string(values))
        end)
        if not ok then util.debug("recorder " .. key .. ": " .. tostring(err)) end
    end)
end

-- Values the game itself used for `key`, merged with `overrides` (overrides win).
function recorder.values(key, overrides)
    local out = {}
    for i, v in pairs(util.config.learned[key] or {}) do out[tonumber(i)] = v end
    for i, v in pairs(overrides or {}) do out[i] = v end
    return out
end

-- Call a game method as the mod (so the recorder doesn't learn from it).
function recorder.call(obj, method, values)
    recorder.mine = true
    local ok, res = pcall(game.call, obj, method, values)
    recorder.mine = false
    if not ok then error(res, 0) end
    return res
end

function recorder.dump()
    local out = { types = {}, calls = recorder.calls, learned = util.config.learned }
    for _, tname in ipairs(DUMP_TYPES) do
        local td = game.type(tname)
        local list = {}
        for _, m in ipairs(td and td:get_methods() or {}) do
            local rt = m:get_return_type()
            list[#list + 1] = string.format("%s%s %s(%s)", m:is_static() and "static " or "",
                rt and rt:get_full_name() or "void", m:get_name(), table.concat(game.param_types(m), ", "))
        end
        table.sort(list)
        out.types[tname] = list
    end
    json.dump_file("wilds_seamless_coop/signatures.json", out)
    util.info("wrote reframework/data/wilds_seamless_coop/signatures.json")
end

function recorder.init()
    -- Learning is only needed by the experimental features; with all of them off, the game isn't hooked at all.
    if not util.any_experimental_at_start() then return end
    -- One hook per method: skip what a feature already hooks (features init first).
    local taken = {}
    for _, h in ipairs(game.hook_requests) do taken[h[1] .. "." .. h[2]] = true end
    for _, w in ipairs(recorder.WATCHED) do
        if not taken[w[1] .. "." .. w[2]] then watch(w[1], w[2]) end
    end
end

return recorder
