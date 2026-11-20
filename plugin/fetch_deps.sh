#!/usr/bin/env bash
# Downloads REFramework's plugin header and vendored Lua 5.4.3 sources for one commit.
# Usage: fetch_deps.sh <deps dir> [commit]   (default: the commit of REFramework nightly 01240)
set -euo pipefail
deps="$1"
commit="${2:-870709ed3da9ba2b8f47a0bf483440267ece2eee}"
raw="https://raw.githubusercontent.com/praydog/REFramework/$commit"
mkdir -p "$deps/include/reframework" "$deps/lua"
curl -sfL "$raw/include/reframework/API.h" -o "$deps/include/reframework/API.h"
for f in lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c ldblib.c ldebug.c ldo.c ldump.c lfunc.c lgc.c \
         linit.c liolib.c llex.c lmathlib.c lmem.c loadlib.c lobject.c lopcodes.c loslib.c lparser.c lstate.c \
         lstring.c lstrlib.c ltable.c ltablib.c ltm.c lundump.c lutf8lib.c lvm.c lzio.c lapi.h lauxlib.h lcode.h \
         lctype.h ldebug.h ldo.h lfunc.h lgc.h ljumptab.h llex.h llimits.h lmem.h lobject.h lopcodes.h lopnames.h \
         lparser.h lprefix.h lstate.h lstring.h ltable.h ltm.h lua.h lua.hpp luaconf.h lualib.h lundump.h lvm.h lzio.h; do
    curl -sfL "$raw/dependencies/lua/src/$f" -o "$deps/lua/$f"
done
echo "fetched REFramework $commit into $deps"
