# Wilds Seamless Co-op: how it works (0.5.2)

0.5.2 is the safe build of the rebuild described in [REBUILD_PLAN.md](REBUILD_PLAN.md). 0.5.0 and 0.5.1 froze and
crashed the game in real two-player sessions, so everything that drives the game is now experimental and off.

## What works (on by default)

| Feature | What it does |
|---|---|
| **Co-op group** | Invite any Steam friend from the panel, including friends who are offline or invisible. The group is saved by Steam id and kept until someone leaves. |
| **Steam chat invite** | A group invite also sends a Steam game invite. Accepting it, with the mod installed, joins the group. It does **not** put you in the game's Link Party yet. |
| **Mod-to-mod channel** | The mods find each other over a private Steam peer-to-peer channel (`seamless_net.dll`) and show each member's state in the panel. |
| **Save backups** | The save folder is copied at every game start (newest 20 kept). |
| **Session logs** | `reframework/data/wilds_seamless_coop/logs/session-1..5.log`. Every call the mod makes into the game is written to the log *before* it happens, so a crash log shows the last thing the mod did. |

With only these on, the mod doesn't hook the game at all. The log says so at start:
`experimental features on: none (the game is not hooked)`.

## Experimental (off, not working in the real game yet)

Panel → *Experimental*. Each one only hooks the game if it was on when the game started, so restart the game after
switching one. Only switch one on when you're testing it together, and send the logs afterwards.

| Setting | What it is meant to do | Known state |
|---|---|---|
| Auto-invite to Environment Link | Link Party members in the same field get linked | Never fired in the real game |
| Auto-accept Environment Link invites | Accept Environment Link invites from your Link Party | Untested |
| Re-link after hunts | Re-send Environment Link invites after the game drops them at the end of a hunt | Untested |
| Auto-follow group quests | Join a quest a group member posts | Untested |
| Rebuild the Link Party | Re-invite group members to the Link Party after a disconnect | Froze the game in 0.5.0 |
| Fast travel together | Followers join the mover's area over Environment Link | Untested (the 0.5.0 warp replay is removed) |
| Stay in Environment Link through story events | Skip the game's "leave link" when a story event starts | Untested |
| Shared cutscenes | Start cutscenes together, skip by vote | Untested |
| Lead the story / Story sync | Followers take the leader's story steps on their own save (dry run first) | Untested |

All of them still depend on the game's network requests, which take a callback. REFramework nightly 01240 can't
create those callbacks, and since 0.5.2 the mod refuses to make such a request at all instead of passing null (what
froze and crashed 0.5.x). So on this REFramework most of them will only log `no callback object could be made`. That
is expected until Phase 1 of the rebuild moves them onto the game's own menu functions.

Removed in 0.5.2: *Keep visible*, *early Environment Link unlock*, and refusing Environment Link joins from outside the
group. They hooked methods the game calls all the time, and could have caused the crash. *Allow outsiders* now only
pauses group sync.

## Messages between the mods

The plugin only sends to your group, to invites you sent or got, and to hunters already in your Link Party. Friends
who just play Wilds never get anything. Mods that answer get a small status message every 3 s; anyone else on that
list (offline members, pending invites) gets one every 15 s. Nothing is posted in Steam chat except the one invite
sent when you press *Invite*. The plugin accepts messages only from your Steam friends and your group.

## Safety rules

- The mod never creates or edits quests, rewards, items or leaderboard data, and never blocks the game's own cheat
  checks.
- Story sync only ever runs on a follower whose story progress equals the leader's, never during a quest, and only
  after a save backup.
- Settings from 0.5.1 or older are reset to these safe defaults once; your co-op group is kept.

### Restoring a backup

1. Close the game. In Steam, open the game's Properties → General and turn **Steam Cloud off** for Wilds.
2. Copy the `win64_save` folder from `reframework/data/wilds_seamless_coop/save_backups/<date-time>-<reason>` over
   `<Steam>/userdata/<your Steam ID>/2246340/remote/win64_save`.
3. Start the game and check the save. Then turn Steam Cloud back on and choose **local files** if Steam asks.

## If something goes wrong

Send `reframework/data/wilds_seamless_coop/logs/` (the newest `session-N.log` is shown under *Diagnostics*). After a
crash, also send `reframework_crash.dmp` and copy `re2_framework_log.txt` **before** starting the game again: the
game overwrites it on every start.

## Tests

`lua5.4 tests/two_players.lua reframework/autorun` runs the mod for several players against a fake game (71 checks).
It checks the mod's own logic, with the experimental features switched on. It says nothing about whether the real
game accepts the mod's calls; only live tests do.
