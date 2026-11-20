# MH Wilds Seamless Co-op

A mod for Monster Hunter Wilds that lets you and your friends play through the whole game together as one group,
without re-inviting each other all the time. It's inspired by the Seamless Co-op mods for Elden Ring and Monster
Hunter World, but it's written from scratch for Wilds.

> **This is an alpha.** It has mostly been tested against a fake copy of the game and only lightly in the real one.
> Expect bugs, and expect things to break after game updates.

## ⚠️ Read this first

- **No guarantees against bans.** Using mods online is against Capcom's terms. The mod never touches quests,
  rewards, items or leaderboards, and it doesn't hide itself from or block the game's own cheat checks. Still,
  you use it at your own risk.
- **Back up your save.** The mod copies your save folder every time the game starts, but make your own backup too.
- **Everyone in the group needs the mod**, the same version of it, and has to be Steam friends with each other.

## What it does

- **Co-op group**: invite a Steam friend once from the mod's menu (they can be offline or invisible). After
  that you stay grouped until someone leaves.
- **The Link Party fixes itself**: if someone disconnects or starts the game later, the mod puts the party back
  together.
- **Fast travel together**: when one person fast travels, everyone else in the group comes along.
- **Auto-follow quests**: when someone in the group posts a quest, the others join it.
- **Story in sync**: one player leads, and the others' saves follow the same story steps. This starts as a dry
  run that only logs what it would do, until you switch it on.
- **Shared cutscenes**: cutscenes start together, and skipping one is a vote.
- **Closed group**: people outside your group can't join your Environment Link. Tick *Allow outsiders* if you
  want SOS flares or randoms; story sync pauses while you do.

## Requirements

- Monster Hunter Wilds on Steam (Windows, or Linux/Steam Deck through Proton)
- [REFramework](https://github.com/praydog/REFramework-nightly/releases), **nightly 01240** for Wilds. The included
  `seamless_net.dll` plugin is built against that exact version. With another version, you have to rebuild the
  plugin (see below).

## Install

1. Install REFramework: put its `dinput8.dll` in the game folder, next to `MonsterHunterWilds.exe`.
2. Copy this repo's `reframework` folder into the game folder and merge it with the one that's already there.
3. Build `seamless_net.dll` (see below), or grab it from a release if there is one, and put it in
   `reframework/plugins/`.
4. On Linux or Steam Deck, set the game's Steam launch options to `WINEDLLOVERRIDES="dinput8=n,b" %command%`.
5. Start the game and press **Insert** to open REFramework, then find *Wilds Seamless Co-op*.

To uninstall, delete `reframework/autorun/wilds_seamless_coop.lua`, the `reframework/autorun/wilds_seamless_coop`
folder and `reframework/plugins/seamless_net.dll`.

## Playing

1. One of you opens *Invite a Steam friend* and invites the other. The other accepts in their menu.
2. One player ticks **Lead the story**. Leave *Story sync* on **Dry run** for your first session, and check the
   *Story steps* list to see that it looks right.
3. Play. If something goes wrong, the logs are in `reframework/data/wilds_seamless_coop/logs/`.

More detail on how each part works is in [docs/DETAILS.md](docs/DETAILS.md).

## Building the plugin

You need mingw-w64 (on Linux):

```bash
cd plugin
./fetch_deps.sh deps
./build.sh deps out
```

That gives you `out/seamless_net.dll`.

## Tests

The tests run the mod for several players against a fake game, with no game needed:

```bash
lua5.4 tests/two_players.lua reframework/autorun
```

## Credits

- [REFramework](https://github.com/praydog/REFramework) by praydog
- The Steam bindings in the plugin are adapted from
  [Hunterjet/mhwilds-seamless-coop](https://github.com/Hunterjet/mhwilds-seamless-coop) (MIT, see
  `plugin/THIRD_PARTY_LICENSE.txt`)
- The idea comes from Elden Ring Seamless Co-op and MHW Seamless Co-op. No code from either is used.

Not affiliated with Capcom.
