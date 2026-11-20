-- Keep the other hunters in your Link Party drawn during story segments. The game hides them based on story
-- progress (MissionManager.IsDrawReplicaPlFromProgress / isProgressDrawOffSelfFromOthers). Purely local drawing.
local util = require("wilds_seamless_coop.util")
local game = require("wilds_seamless_coop.game")

local visible = {}

local has_party = false -- refreshed by update(); the hooks below can run every frame, so they stay cheap

local function active() return util.on("keep_visible") and has_party end

function visible.update()
    has_party = #game.members(game.SESSION.LINK()) > 1
end

function visible.init()
    game.hook("app.MissionManager", "IsDrawReplicaPlFromProgress", nil, function(retval, m)
        if active() and game.returns_bool(m) then return game.TRUE end
        return retval
    end)
    game.hook("app.MissionManager", "isProgressDrawOffSelfFromOthers", nil, function(retval, m)
        if active() and game.returns_bool(m) then return game.FALSE end
        return retval
    end)
end

return visible
