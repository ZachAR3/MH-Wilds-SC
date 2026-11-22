# Rebuild plan (after 0.5.1)

## Why

0.5.x was built and tested against a fake copy of the game. In the first real session with two players it froze one
game (0.5.0) and crashed another (0.5.1), and the automatic Environment Link never fired.

The main cause: every automatic action called the game's raw network requests (`app.NetworkRequestManager.*`). Those
take a callback (`System.Action<...>`), and REFramework nightly 01240 can't create one (`sdk.create_delegate` fails),
so the game got a null callback. The 0.5.1 crash dump shows the game's memory manager hitting corrupted data on a
worker thread, reached through a REFramework hook. The exact mod line wasn't found, because the log was only written
every 5 s.

## Rules from now on

- Nothing is "done" until it has worked in the real game with two players. Tests against the fake game only check
  the mod's own logic.
- New features ship **off by default** and are only switched on after a live test passes.
- No game request is made if any of its callback parameters can't be filled. This check is global, not opt-in.
- No hooks on methods the game calls every frame or from worker threads (drawing and stage checks).
- No test runs or file swaps in the game folder while someone wants to play.

## Phase 0: make it safe (offline, no game needed)

1. Cut the mod down to what has worked live: the co-op group, the Steam P2P channel, the panel and save backups.
   Every feature that touches the game goes behind a toggle that is off by default.
2. Remove the per-frame hooks: *Keep visible* (`IsDrawReplicaPlFromProgress`, `isProgressDrawOffSelfFromOthers`),
   the `getCanPartySyncInfoInCurrentStage` override, and the early-unlock gates. Bring one back only if a later
   phase needs it.
3. Crash breadcrumbs: write "calling X" to the log and flush it right before every game call, and flush warnings
   immediately. The next crash log then shows the last thing the mod did.
4. Make `game.call` refuse any call that would pass a null callback.

Result: 0.5.2, which should be as stable as the vanilla game and lets the two of you stay grouped.

## Phase 1: probe (one short session, only when you say it's fine)

Look for a safer way in. The game's menu layer (`app.cGUINetworkRequest`, static methods) builds its own callbacks:

| Need | Menu-level entry point |
|---|---|
| Environment Link invite to the whole Link Party | `reqLinkPartySyncInvite(GUIBaseApp)` |
| Accept an Environment Link invite | `reqLinqPartySyncJoinWindow(GUIBaseApp, Nullable<Guid>)` |
| Join a Link Party quest | `reqLinqPartyQuestJoinWindow(GUIBaseApp, Nullable<Guid>, String, Boolean)` |
| Link Party invite | `reqLinqPartyInvite(GUIBaseApp, Net_MLUserInfo, SESSION_TYPE, Action)` |
| Accept a Link Party invite | `reqLinqPartyJoinWindow(GUIBaseApp, cNotifyUserInfoWithUserId, String)` |

The probe answers:

- where a valid `GUIBaseApp` comes from (what the game passes when you do each of these by hand);
- whether `sdk.create_delegate` works for the plain `System.Action` (no type arguments), or whether null is what the
  game itself passes there;
- whether the "...Window" variants just show the game's usual confirm prompt. If they do, the mod may open the prompt
  and you press confirm, which is fine and much safer.

### Phase 1 results (solo dry runs, 2026-11-21, Ollie offline)

- **Callbacks:** `sdk.create_delegate(td, 0)` returns nil on nightly 01240 (that is why every 0.5.x callback was null),
  and `(td, 1)` returns an object without a target. The mod can't make callbacks at all, so it only uses the menu
  requests, which make their own.
- **`GUIBaseApp`:** the Link Party HUD, `app.GUI020011`, found in `app.GUIManager._AllGUI`.
- **`reqLinkPartySyncInvite(GUI020011)` works.** The game shows "Connecting...", creates the session, invites, and
  shows "Invited all Link Members to your environment." with a Close button. No crash.
- **`reqLinqPartySyncJoinWindow(GUI020011, Nullable<Guid>)`** takes the mod's argument (the mod's hook read back
  the right hunter id). With no invite pending it shows "Unable to join the session. EA_186a7" and nothing else
  happens.
- **Guids were broken in every 0.5.x build.** A method called on a REFramework value type works 16 bytes past its
  start, so:
  - `ToString()` showed the next field (the logged "hunter id" was really the user id);
  - `Guid.Parse` and `.ctor` never gave the game a usable argument;
  - `.ctor` on a value type the mod made wrote past the end of its buffer and crashed the game 5 s later.

  0.5.3 packs and reads Guid bytes itself and never calls a method on a value type. Guid getters (`get_HunterId`)
  return nil, so ids are read from fields (`Net_UserInfo.param.HunterId`).
- **Link Party invite target:** `Net_MLUserInfo.importFrom(Net_SocialUserInfoWithStatus)` from the Hunter Friends
  list (`NetworkManager._FriendManager:get_FriendList()`) gives the right ids. Building it from the saved card
  (`cBlockUserInfo`) did not, so that path is gone. `canLinkPartyInvite` says no while the friend is offline, which
  matches the game's own menu (only "View Hunter Profile").
- Still open, needs Ollie online: whether the game passes a null `Action` to `reqLinqPartyInvite[Window]` (the mod
  learns this from one invite you send by hand), and the receiving side of both invites.

### Join crash with everything off (fixed in 0.5.5, 2026-11-22)

The safe builds still crashed during Link Party / Environment Link joins. A scripted bisect between a PC and a Steam
Deck (table in [DETAILS.md](DETAILS.md#crash-investigation-2026-11-22)) cleared the plugin and Steam networking and
pinned it on the mod's member list reads, which wrapped the game's network objects for Lua. 0.5.5 reads them as raw
memory. Result: 8 joins and leaves with the plugin loaded and no crash (every earlier run with 0.5.4 and the
plugin crashed within 1 to 5 joins), and the member names, sync state and co-op link notices still worked.

Rule added: **the mod never wraps the game's per-player network objects** (`Net_UserInfoList`, `Net_UserInfo`,
`Net_UserParam`) on a timer. Anything that needs them reads raw memory with offsets from the type database.

## Phase 2: one feature at a time, live with Ollie

Each step: I build it (off by default), you both install it, switch on that one feature, and play normally for about
30 minutes. **It passes when it works three times with no crash.** Then it becomes on by default and we move to the
next step.

1. **Auto Environment Link:** once you're in a Link Party in the same field, you get linked (`reqLinkPartySyncInvite`,
   the invited player accepts it in the game's Invitation List as usual).
   Auto-accept is out: `reqLinqPartySyncJoinWindow` only works from the open Invitation List, and called from anywhere
   else it crashed both games. The panel also has a button that sends the same invite by hand.
   **Passed 2026-11-22** (scripted, PC + Steam Deck, 0.5.5): 3 of 3 Link Party joins got exactly one invite within
   2 s and ended in Environment Link, no crash, no warning. On by default since 0.5.5.
2. **Re-link after hunts:** the same call after the game drops the link at the end of a hunt.
3. **Auto-join quests:** a group member posts a quest and the others join (`reqLinqPartyQuestJoinWindow`).
4. **Link Party from the group:** a Steam invite or restart ends with both of you in the game's Link Party, not just
   in the mod's group (`reqLinqPartyInviteWindow`, target from your Hunter Friends list).
5. **Fast travel together:** done by joining the mover's area over Environment Link, not by replaying the warp
   (replaying it was the riskiest part of 0.5).
6. **Story sync and shared cutscenes:** last, dry run only at first. 2026-11-22: their hooks are safe on a new save
   (cutscenes play and skip normally, story steps are seen); the two-player part needs saves past the prologue. They may stay out if steps 1–5 already make
   playing through the story together comfortable.

On hold until someone asks for them: refusing outsiders (closed group), early Environment Link unlock, keep visible.

## What to send after a test

`reframework/data/wilds_seamless_coop/logs/` (both players), plus `reframework_crash.dmp` and `re2_framework_log.txt`
if it crashed. Copy `re2_framework_log.txt` before restarting the game: the game overwrites it on every start.
