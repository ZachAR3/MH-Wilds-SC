# MH Wilds Seamless Co-op

A mod for Monster Hunter Wilds that lets you and your friends play through the whole game together as one group,
without re-inviting each other all the time. It's inspired by the Seamless Co-op mods for Elden Ring and Monster
Hunter World, but it's written from scratch for Wilds.

> **This is an alpha, and right now most of it doesn't work.** 0.5.0 and 0.5.1 froze and crashed the game in real
> co-op sessions. 0.5.2 to 0.5.5 are cut-down builds: only the co-op group, save backups and (since 0.5.5) the
> automatic Environment Link invite are on. Everything else is switched off while it gets rebuilt one feature at a
> time ([docs/REBUILD_PLAN.md](docs/REBUILD_PLAN.md)).
> 0.5.2 to 0.5.4 could still crash the game when someone joined your Link Party or environment; 0.5.5 fixes
> that (8 scripted joins between two machines, no crash). Details in [docs/DETAILS.md](docs/DETAILS.md#crash-investigation-2026-11-22).

## ⚠️ Read this first

- **No guarantees against bans.** Using mods online is against Capcom's terms. The mod never touches quests,
  rewards, items or leaderboards, and it doesn't hide itself from or block the game's own cheat checks. Still,
  you use it at your own risk.
- **Back up your save.** The mod copies your save folder every time the game starts, but make your own backup too.
- **Everyone in the group needs the mod**, the same version of it, and has to be Steam friends with each other.

## What it does

What works now (0.5.5):

- **Co-op group**: invite a Steam friend once from the mod's menu (they can be offline or invisible). After that you
  stay grouped until someone leaves. The invite also sends a Steam chat invite (accept it while Wilds is closed:
  Steam starts the game with the invite and the mod joins the group).
- **Save backups** every time the game starts.
- A log line before every call the mod makes into the game, so crashes can be traced.
- **Auto Environment Link**: when a Link Party member who runs the mod is in a field with you, the mod sends the
  game's own "invite my Link Party to my environment" for you; they accept it as usual. Passed 3 of 3 live joins.
  There's also a panel button that sends the same invite by hand.

Being rebuilt (experimental, off by default, can crash the game):

- Re-linking after hunts
- Auto-joining group quests
- Putting the group back in one Link Party after a disconnect
- Fast travel together
- Story sync and shared cutscenes

## Requirements

- Monster Hunter Wilds on Steam (Windows, or Linux/Steam Deck through Proton)
- [REFramework](https://github.com/praydog/REFramework-nightly/releases), **nightly 01240** for Wilds. The included
  `seamless_net.dll` plugin is built against that exact version. With another version, you have to rebuild the
  plugin (see below).

## Install

1. Install REFramework: put its `dinput8.dll` in the game folder, next to `MonsterHunterWilds.exe`.
2. Copy this repo's `reframework` folder into the game folder and merge it with the one that's already there. If you
   are updating, delete the old `reframework/autorun/wilds_seamless_coop` folder first.
3. Build `seamless_net.dll` (see below), or grab it from a release if there is one, and put it in
   `reframework/plugins/`.
4. On Linux or Steam Deck, set the game's Steam launch options to `WINEDLLOVERRIDES="dinput8=n,b" %command%`.
5. Start the game and press **Insert** to open REFramework, then find *Wilds Seamless Co-op*.

To uninstall, delete `reframework/autorun/wilds_seamless_coop.lua`, the `reframework/autorun/wilds_seamless_coop`
folder and `reframework/plugins/seamless_net.dll`.

## Playing

1. One of you opens *Invite a Steam friend* and invites the other. The other accepts in their menu.
2. Make the Link Party and Environment Link from the game's own menu, as usual.
3. Play. If something goes wrong, the logs are in `reframework/data/wilds_seamless_coop/logs/`. After a crash, copy
   `re2_framework_log.txt` before starting the game again, because the game overwrites it.

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
