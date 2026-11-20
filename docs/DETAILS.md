# Wilds Seamless Co-op: how it works

Play Monster Hunter Wilds' story as one group: invite your friends once and from then on you share the Link Party,
the field, fast travel, the story steps, the cutscenes and every hunt, until someone leaves the group.

| Feature | What it does |
|---|---|
| **Co-op group** | Invite any Steam friend from the panel, including friends who are offline or invisible. The group is saved by Steam id and kept until someone leaves |
| **Permanent Link Party** | After a disconnect, or when someone starts the game later, the Link Party is rebuilt automatically with the game's own invite and accept |
| **Fast travel together** | When a group member fast travels or returns to base, everyone else in the group warps to the same spot. If the warp fails, the game falls back to joining their area |
| Auto-follow | When a group member posts a quest or starts a story hunt, you join within about 1 s |
| Stay linked | The game drops Environment Link when a story event starts; the mod keeps you linked |
| Auto-accept link | Environment Link invites from your Link Party are accepted automatically |
| Re-link after hunts | The game ends Environment Link after every hunt; the mod sends the invites again |
| Keep visible | Other hunters aren't hidden during story segments |
| Early unlock | Environment Link is available before mission 001075 unlocks it |
| **Story lockstep** | One player ticks *Lead the story*. Each follower's game takes the same story steps on its own save |
| **Shared cutscenes** | Cutscenes wait until everyone has reached them and start together; skipping is a vote |
| **Closed group** | Environment Link joins from hunters outside the group are refused. *Allow outsiders* lets SOS / random hunters in and pauses story, cutscene, travel and party sync |
| **Save backups** | The save folder is copied at every game start and before story steps are mirrored (newest 20 kept) |
| Session logs | `reframework/data/wilds_seamless_coop/logs/session-1..5.log`; the oldest is overwritten |

Settings: open the REFramework menu (**Insert**), then *Wilds Seamless Co-op*. *Seamless Co-op on* is the master
switch: when it is off, the game plays exactly as it does without the mod (save backups still run).

## Co-op group

- **Invite button:** *Invite a Steam friend* lists your whole friends list: friends in Wilds first, then online,
  then offline or invisible, with a search box. The invite is held for 15 minutes and resent every 15 s, so the
  friend's mod picks it up as soon as their game is running. A Steam chat invite is sent too, which an offline
  friend can use to launch the game; accepting it joins the group.
- **The in-game way also works:** if you Link Party invite a modded hunter by hand, both of you join each other's
  group.
- The friend accepts the invite in their panel. *Remove* drops one member and *Leave group* leaves the group.
- Invisible Steam status is fine: the mods talk directly by Steam id, so no presence is needed. Players must be
  Steam friends to invite each other the first time; after that, group members are trusted by Steam id.

## Permanent Link Party

When a group member is online but not in your Link Party (after a disconnect or a late start), exactly one side
invites the other: whoever already has a Link Party with others, otherwise the lower Steam id. The other side
accepts automatically. The invite is sent from the hunter card saved when you were last together (no Steam lookups
are involved). Invites are retried every 30 s, six times, then every 5 minutes. Nothing is sent during a quest.
**Leaving the Link Party from the game menu pauses this** until you are in a Link Party with your group again.

## Fast travel together

The mover's fast travel (`app.mcFastTravel.warpPlayer`) is watched. Its stage, position, rotation and warp options
are sent to the group, and each follower makes the same warp call for their own hunter, a step to the side. If the
follower isn't on the target stage 20 s later, they join the mover's Environment Link instead, which loads the
mover's area. Followers wait while they are in a quest, a cutscene, a loading screen or another warp, and give up
after 60 s. *Fast travel follow → Join their area* skips the warp and always uses the Environment Link join.

## How it fits together

- **Everyone runs their own copy of the story.** Each game plays the mission, its NPCs and its cutscenes itself;
  the mod keeps those copies in step. That is also how each follower's save progresses.
- **One player leads the story:** tick *Lead the story* in the panel (exactly one player). When the leader's game
  loads a mission, sets a mission flag or clears an objective, the step is sent to the followers. Each follower's
  game calls the same routine with the same values. Nothing is mirrored during a quest.
- **Cutscenes:** before a game plays a cutscene, it waits (at most 30 s) until every linked partner on the same
  mission has reached the same cutscene, then all start together. Pressing skip casts a vote; when every watcher has
  voted, everyone skips.
- **Messages between the mods** go through `reframework/plugins/seamless_net.dll`, a private Steam peer-to-peer
  channel. It only sends to your group, to invites you sent or got, and to hunters already in your Link Party:
  friends who merely play Wilds never get anything. Mods that answer get a small status message every 3 s; anyone
  else on that list (offline members, pending invites) one every 15 s. Nothing is posted in Steam chat except the
  one invite sent when you press *Invite*. It accepts messages only from your Steam friends and your group.
  Everyone must run the same mod version.

## Safety rules

- **Followers only take story steps while their story progress equals the leader's.** A save that is behind or ahead
  is never touched (the panel says why).
- **Never during a quest, and never quest results:** the game itself shares hunts. Quests, rewards, items and
  leaderboard data are never created or edited.
- **Backup first:** the mod copies your Steam save folder to
  `reframework/data/wilds_seamless_coop/save_backups/<date-time>-<reason>` at every game start and before mirroring
  (at most every 15 min). If the copy fails, nothing is mirrored. *Back up saves now* in the panel makes one by hand.
- **Story sync starts in "Dry run".** The follower's panel (*Story steps*) lists every step it *would* take, and
  nothing changes on its save. Switch to **On** only after a dry-run session looked right.
- **Outsiders pause sync:** with *Allow outsiders* ticked, or while a hunter outside the group has been in your
  Link Party or quest for 15 s, story, cutscene, fast-travel and party sync stop. Quest following still works.
- **Tripwire:** if the game's own quest cheat check ever fires, the mod says so and switches story sync off. The
  check itself is never blocked.

### Restoring a backup

1. Close the game. In Steam, open the game's Properties → General and turn **Steam Cloud off** for Wilds.
2. Copy the `win64_save` folder from the backup over `<Steam>/userdata/<your Steam ID>/2246340/remote/win64_save`.
3. Start the game and check the save. Then turn Steam Cloud back on and choose **local files** if Steam asks.

## Install (every player)

1. Copy `dinput8.dll` and the `reframework` folder (it contains `autorun/` and `plugins/seamless_net.dll`) into the
   game folder, next to `MonsterHunterWilds.exe`.
2. Linux / Steam Deck: set the Steam launch option `WINEDLLOVERRIDES="dinput8=n,b" %command%`.
3. Start the game. *Diagnostics* should show `Plugin: 1.2.0` and a non-zero *Steam callbacks* count.

`seamless_net.dll` is built for REFramework commit 870709e (nightly 01240, Lua 5.4.3). If you update REFramework,
rebuild the plugin (see *Building the plugin*), or the co-op channel may not load.

## First sessions

1. **Form the group:** one player invites the other from *Invite a Steam friend*, and the other accepts in their
   panel. Alternatively, Link Party invite each other by hand.
2. **Teach the mod once by hand** (it remembers this in `reframework/data/wilds_seamless_coop/config.json`). The
   follower accepts one Link Party quest invite and one Environment Link invite by hand. The leader sends one
   Environment Link invite and one Link Party invite to each friend by hand.
3. **Dry-run story session:** both players at the same story point and linked. One ticks *Lead the story* and plays
   a story mission. Followers check *Story steps* for "[dry run] would mirror ..." lines and that cutscenes started
   together.
4. **Story sync On:** the same again, with *Story sync* set to On on the followers.

## Test checklist

- [ ] Group invite to a friend whose game is closed → they start the game → the invite appears in their panel.
- [ ] The same with the friend set to invisible on Steam.
- [ ] One player restarts the game → the Link Party is rebuilt without anyone pressing anything.
- [ ] Fast travel → the partner arrives next to you (or, if the warp fails, joins your area).
- [ ] Leader posts an optional quest → followers land in it without pressing anything.
- [ ] A cutscene waits for everyone ("Seamless Co-op: waiting ..." on screen) and starts together; skip by vote.
- [ ] Dry run: followers' *Story steps* list the leader's steps. On: objectives and next mission match.
- [ ] A non-group hunter is refused; with *Allow outsiders* ticked, an SOS joiner gets in and sync pauses.

If something fails, send `reframework/data/wilds_seamless_coop/logs/` (the newest `session-N.log` is shown under
*Diagnostics*), `re2_framework_log.txt`, and `signatures.json` (*Diagnostics* → **Write signatures.json**).

## What has been tested

- In the real game (TDB 81, REFramework nightly 01240, Proton): every hook target exists, the plugin loads and its
  Steam callbacks register, save backups work, and the self-test message loop runs through the follower code.
- Offline, `lua5.4 tests/two_players.lua reframework/autorun` runs the mod for up to five
  players against a fake game. Its 67 checks cover the group, offline invites, Steam invites, the Link Party
  rebuild, outsiders, fast travel, lockstep, cutscenes and backups.
- **Not tested with a second real player:** messages to an invisible friend, the Steam chat invite, the fast-travel
  warp replay, the Link Party rebuild, outsider refusal, cutscene holds and story mirroring.

## Building the plugin

The sources are in `plugin/` (Linux, mingw-w64):

```bash
./fetch_deps.sh deps           # REFramework API header + its Lua 5.4.3 sources (optional 2nd arg: commit)
./build.sh deps out            # -> out/seamless_net.dll
```

## Credits

- Type and method names, and the Steam flat-API bindings the plugin is adapted from:
  [Hunterjet/mhwilds-seamless-coop](https://github.com/Hunterjet/mhwilds-seamless-coop) (MIT,
  © 2026 Seamless Co-op for Monster Hunter Wilds contributors).
- The feature set is inspired by MHW Seamless Co-op (Nexus mod 8805) and Elden Ring Seamless Co-op. No code from
  either is used.
- [REFramework](https://github.com/praydog/REFramework) by praydog.

Unofficial; not affiliated with Capcom. Modding online behaviour always carries some account risk.
