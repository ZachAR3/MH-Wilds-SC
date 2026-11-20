#!/usr/bin/env bash
# Cross-compiles seamless_net.dll with mingw-w64 against REFramework's exact plugin header and Lua 5.4.3 sources.
# Usage: build.sh <deps dir> <output dir>
#   <deps dir> must contain include/reframework/API.h and lua/*.c|*.h from the REFramework commit the game runs
#   (870709ed3da9ba2b8f47a0bf483440267ece2eee for nightly 01240): see fetch_deps.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
deps="$1"
out="$2"
mkdir -p "$out"
obj="$(mktemp -d)"
trap 'rm -rf "$obj"' EXIT

CC=x86_64-w64-mingw32-gcc
CXX=x86_64-w64-mingw32-g++

# REFramework's Lua, compiled as C with no extra definitions, so its structures match the lua_State we are handed.
for f in "$deps"/lua/*.c; do
    case "$(basename "$f")" in lua.c|luac.c|onelua.c) continue ;; esac
    $CC -O2 -c "$f" -o "$obj/$(basename "$f" .c).o"
done

$CXX -std=c++20 -O2 -Wall -Wextra -DWIN32_LEAN_AND_MEAN -DNOMINMAX \
    -I"$deps/include" -I"$deps/lua" \
    -c "$here/seamless_net.cpp" -o "$obj/seamless_net.o"

$CXX -shared -o "$out/seamless_net.dll" "$obj"/*.o \
    -static -static-libgcc -static-libstdc++ -Wl,--exclude-all-symbols -s

echo "built $out/seamless_net.dll"
