# Wilds Seamless Co-op: how it works (0.5.5)

0.5.3 continues the rebuild described in [REBUILD_PLAN.md](REBUILD_PLAN.md). 0.5.0 and 0.5.1 froze and crashed the
game in real two-player sessions, so everything that drives the game is experimental and off. 0.5.3 moves Environment
Link and Link Party invites onto the game's own menu requests (Phase 1) and fixes how Guids are passed to the game.

0.5.4 and 0.5.5 fix the crash during Link Party / Environment Link joins that happened even with every experimental
feature off. It was traced (see [Crash investigation](#crash-investigation-2026-11-22)) to the mod reading the game's
member lists: each read handed the game's network objects to Lua, and REFramework took and dropped references on them
while the game was building and freeing them for the join. 0.5.5 reads those lists as plain memory and wraps no game
object; the hunter card is read the same way instead of through `conv2BlockUserInfo`.

0.5.5 also makes the first rebuilt feature a normal setting: **Auto Environment Link** passed its live test (three joins
in a row between two machines, one invite each, no crash) and is on by default.

## What works (on by default)

| Feature | What it does |
|---|---|
| **Co-op group** | Invite any Steam friend from the panel, including friends who are offline or invisible. The group is saved by Steam id and kept until someone leaves. |
| **Steam chat invite** | A group invite also sends a Steam game invite. Accepting it while Wilds is closed starts the game and joins the group (with the mod installed). Accepting it while Wilds is already running does nothing since plugin 1.3.0: accept the invite in the mod's panel instead. It does **not** put you in the game's Link Party. |
| **Mod-to-mod channel** | The mods find each other over a private Steam peer-to-peer channel (`seamless_net.dll`, Steam's classic P2P packets) and show each member's state in the panel. |
| **Auto Environment Link** | When a Link Party member who runs the mod is in a field with you, the mod sends the game's own "invite your Link Party to your environment" (the player with the lower Steam id sends it; at most 3 tries per area). They accept it in the game's Invitation List as usual. Live test 2026-11-22: 3 of 3 joins got exactly one invite and ended linked, no crash. Untick *Auto-invite modded Link Party members to my environment* in the panel to switch it off. |
| **Save backups** | The save folder is copied at every game start (newest 20 kept). |
| **Session logs** | `reframework/data/wilds_seamless_coop/logs/session-1..5.log`. Every call the mod makes into the game is written to the log *before* it happens, so a crash log shows the last thing the mod did. |

With only these on, the mod doesn't hook the game at all. The log says so at start:
`experimental features on: none (the game is not hooked)`.

## Experimental (off, not working in the real game yet)

Panel → *Experimental*. Each one only hooks the game if it was on when the game started, so restart the game after
switching one. Only switch one on when you're testing it together, and send the logs afterwards.

| Setting | What it is meant to do | Known state |
|---|---|---|
| Re-link after hunts | Send the Environment Link invite again after the game drops it at the end of a hunt | Untested |
| Auto-follow group quests | Join a quest a group member posts | Untested |
| Rebuild the Link Party | Re-invite group members to the Link Party after a disconnect | Rebuilt on the game's invite window; needs one invite sent by hand first (see below); untested |
| Fast travel together | Followers join the mover's area over Environment Link | Untested (the 0.5.0 warp replay is removed) |
| Stay in Environment Link through story events | Skip the game's "leave link" when a story event starts | Hooks safe on a new save (see [Story test](#story-test-2026-11-22)); the linked case untested |
| Shared cutscenes | Start cutscenes together, skip by vote | Hooks safe: cutscenes play and skip normally with them on; never tried with a linked partner |
| Lead the story / Story sync | Followers take the leader's story steps on their own save (dry run first) | The leader side sees the game's story steps; never sent between two players yet |

The game's network requests take a callback, and REFramework nightly 01240 can't create one
(`sdk.create_delegate` returns nil). Passing null instead is what froze and crashed 0.5.x, so the mod refuses any
such request (`no callback object could be made` in the log). Environment Link and Link Party invites now go through
the game's menu requests instead, which make their own callbacks. Fast travel, quests and the story features still
need callbacks, so they only log that line for now.

*Rebuild the Link Party* first has to learn how the game sends a Link Party invite: invite a group member once by
hand from the game's menu while the mod runs. Until then the panel says so and nothing is sent. The target is taken
from your Hunter Friends list, so group members need to be Hunter Friends, and online.

Panel → *Invite my Link Party to my environment* sends the game's own Environment Link invite (the same as its menu).
It needs no experimental switch.

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

## Crash investigation (2026-11-22)

Scripted runs between a PC and a Steam Deck (two Steam accounts): the PC hosts, invites the Deck to its Link Party
and then to its environment, the Deck accepts both and leaves the Link Party again, and this repeats. Every
crash happened during or right after a join, in the game's object release queue or managed heap, never in mod code.

| Setup (both machines unless said) | Joins | Crashes |
|---|---|---|
| No mod (Deck without REFramework) | 6 | 0 |
| 0.5.4 + plugin 1.3.0 | 5 | 1 (Deck, join 5) |
| Deck REFramework only, PC 0.5.4 + plugin | 3 | 1 (PC, join 3) |
| 0.5.4, member lists read every 15 s + plugin | 1 | 1 (PC, join 1) |
| 0.5.4, no plugin (mod-to-mod code idle) | 5 | 0 |
| 0.5.4 + plugin with all Steam P2P calls removed | 1 | 1 (Deck) |
| ... and the card / stage / mission reads off | 2 | 1 (Deck, join 2) |
| No plugin DLL, a pure-Lua stand-in for it (mod-to-mod code running) | 5 | 1 (Deck, join 5) |
| Same, with every game read off | 7 | 0 |
| **0.5.5** (raw member reads) + plugin 1.3.0 | 8 | 0 |

So neither the plugin DLL nor Steam networking caused it: the mod-to-mod code only made the mod read the member
lists more often (the QUEST list too). Separately, the Steam Deck sometimes crashes while starting the game with
REFramework alone (exe+0xa4d6790, before any mod code runs); starting again works.

## Story test (2026-11-22)

A new save on the PC (slot 2) with *Shared cutscenes*, *Stay in Environment Link*, *Lead the story* and story sync
"dry run" on: the opening and three prologue cutscenes played and were skipped (hold the skip key) with every hook
installed, and the prologue played on with no crash or warning. The PC and the Deck logged the same story steps
(`setEnableMissionDynamicFlag` with the same mission, flag and value) at the same points of the opening.

Not covered:

- **Story sync and shared cutscenes between two players.** Both act only between Environment-Linked partners on the
  same main mission, and the prologue has no Link Party or Environment Link. They need two saves that are past the
  prologue at the same story point.
- **A new save on the Deck.** On a Steam Deck the game asks Steam's on-screen keyboard for the hunter name, and that
  keyboard doesn't show in the hidden test setup, so character creation can't finish there. Slot 2 on the Deck is
  still empty.

## Tests

`lua5.4 tests/two_players.lua reframework/autorun` runs the mod for several players against a fake game (88 checks),
including the raw member reader against a fake copy of the game's memory layout.
It checks the mod's own logic, with the experimental features switched on. It says nothing about whether the real
game accepts the mod's calls; only live tests do.
