// seamless_net.dll - REFramework plugin giving the Wilds Seamless Co-op Lua mod a private Steam P2P message channel.
//
// Lua API (global table `seamless_net`, all functions safe to call with bad arguments - they never raise Lua errors):
//   available()          -> bool, reason
//   self_id()            -> SteamID64 string or nil
//   friends(all)         -> { { id = "7656...", name = "...", in_game = bool, state = n }, ... }
//                           all = false/nil: friends currently playing Monster Hunter Wilds (old behaviour)
//                           all = true: every Steam friend, online, offline or invisible (state 0 = offline/invisible)
//   trust({ids})         -> count   Steam ids (strings) we accept messages from even if they are not friends
//   send(id, data, rel)  -> bool   to a Steam friend (any presence) or a trusted id; data <= 16 KiB
//   poll()               -> { { from = "7656...", data = "..." }, ... } from friends, trusted ids or ourselves
//   invite(id, connect)  -> bool   Steam chat game invite to one friend (works whatever their presence)
//   overlay_invite(connect) -> bool opens Steam's own invite picker with this connect string
//   events()             -> {}   kept for older Lua; 1.3.0 registers no Steam callbacks (see below)
//   launch_connect()     -> string  connect string the game was launched with from a Steam invite ("" if none)
//   send_self(data)      -> bool   loopback inside the plugin to yourself (poll() returns it with from == self_id())
//   backup_saves(tag)    -> true, folder | false, reason   copies the Steam save folder of this game to
//                           reframework/data/wilds_seamless_coop/save_backups/<time>-<tag> (newest 20 kept)
//   scan(names)          -> { { type, method, params = {..}, ret, static }, ... } diagnostic: where the game's type
//                           database declares methods with these names ("~text" = method name contains text,
//                           app.* only; "@text" = every method of app.*/ace.* types whose name contains text)
//
// 1.3.0: messages go over the old ISteamNetworking P2P API (SendP2PPacket / ReadP2PPacket, channel 92), which the
// game never uses. 1.2.x used ISteamNetworkingMessages, the API the game's own Link Party / Environment Link traffic
// uses: Steam keeps one message session per user for every channel, so the plugin accepted and auto-restarted the
// sessions the game itself was opening and closing with the same partner, and registered its own session-request
// callback next to the game's. With the plugin loaded the game crashed during Link Party / Environment Link joins
// (4 of 4 runs, 2026-11-22; none without it). 1.3.0 shares no session, no callback and no relay setup with the game.
// The later bisect showed the plugin was not the cause: loading it only switched on the mod's Lua member list reads,
// which wrapped the game's per-player network objects and raced with the game freeing them. The mod 0.5.5 reads
// those as raw memory. 1.3.0 is kept because it stays out of the game's own sessions.
//
// Uses only steam_api64.dll as shipped with the game (flat C API, resolved at run time; no Steamworks files included).
// Steam flat-API bindings and struct layouts adapted from github.com/Hunterjet/mhwilds-seamless-coop
// (MIT License, Copyright (c) 2026 Seamless Co-op for Monster Hunter Wilds contributors).

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <filesystem>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

extern "C" {
#include "lua.h"
}
#include "reframework/API.h"

namespace {

constexpr std::uint32_t kAppId = 2246340; // Monster Hunter Wilds
constexpr int kChannel = 92;              // our own ISteamNetworking P2P channel
constexpr std::size_t kMaxBytes = 16 * 1024;
constexpr int kMaxPoll = 64;
constexpr DWORD kFriendRefreshMs = 3000;

constexpr int kP2PUnreliable = 0;      // EP2PSend: <= 1200 bytes
constexpr int kP2PReliable = 2;
constexpr std::size_t kMaxUnreliable = 1200;
constexpr int kFriendFlagImmediate = 0x04;


// ---- Bound functions ------------------------------------------------------------------------------------------------

struct Steam {
    using Accessor = void* (*)();
    Accessor user_acc{}, friends_acc{}, net_acc{};
    std::uint64_t (*get_steam_id)(void*){};
    int (*friend_count)(void*, int){};
    std::uint64_t (*friend_by_index)(void*, int, int){};
    const char* (*friend_name)(void*, std::uint64_t){};
    bool (*friend_game)(void*, std::uint64_t, void*){};
    bool (*send)(void*, std::uint64_t, const void*, std::uint32_t, int, int){};
    bool (*available)(void*, std::uint32_t*, int){};
    bool (*read)(void*, void*, std::uint32_t, std::uint32_t*, std::uint64_t*, int){};
    bool (*accept)(void*, std::uint64_t){};
    bool (*user_data_folder)(void*, char*, int){}; // optional: only the save backup needs it
    // optional (1.2.0): presence, invites
    int (*friend_state)(void*, std::uint64_t){};
    int (*friend_relationship)(void*, std::uint64_t){};
    bool (*invite_user)(void*, std::uint64_t, const char*){};
    void (*overlay_invite)(void*, const char*){};
    Accessor apps_acc{};
    int (*launch_cmdline)(void*, char*, int){};

    bool ok = false;
    bool tried = false;
    std::string reason = "not initialised";

    template <typename T>
    static void bind(HMODULE dll, T& fn, std::initializer_list<const char*> names, std::string& missing) {
        for (const char* n : names) {
            if (auto p = GetProcAddress(dll, n)) {
                fn = reinterpret_cast<T>(reinterpret_cast<void*>(p)); // GetProcAddress returns a generic pointer
                return;
            }
        }
        missing += missing.empty() ? "" : ", ";
        missing += *names.begin();
    }

    // Bound lazily: steam_api64.dll may load after the plugin.
    bool ready() {
        if (ok || tried) return ok;
        HMODULE dll = GetModuleHandleW(L"steam_api64.dll");
        if (dll == nullptr) {
            reason = "steam_api64.dll is not loaded yet";
            return false;
        }
        tried = true;
        std::string missing;
        bind(dll, user_acc, {"SteamAPI_SteamUser_v023", "SteamAPI_SteamUser_v022", "SteamAPI_SteamUser_v021"}, missing);
        bind(dll, friends_acc, {"SteamAPI_SteamFriends_v018", "SteamAPI_SteamFriends_v017"}, missing);
        bind(dll, net_acc, {"SteamAPI_SteamNetworking_v006"}, missing);
        bind(dll, get_steam_id, {"SteamAPI_ISteamUser_GetSteamID"}, missing);
        bind(dll, friend_count, {"SteamAPI_ISteamFriends_GetFriendCount"}, missing);
        bind(dll, friend_by_index, {"SteamAPI_ISteamFriends_GetFriendByIndex"}, missing);
        bind(dll, friend_name, {"SteamAPI_ISteamFriends_GetFriendPersonaName"}, missing);
        bind(dll, friend_game, {"SteamAPI_ISteamFriends_GetFriendGamePlayed"}, missing);
        bind(dll, send, {"SteamAPI_ISteamNetworking_SendP2PPacket"}, missing);
        bind(dll, available, {"SteamAPI_ISteamNetworking_IsP2PPacketAvailable"}, missing);
        bind(dll, read, {"SteamAPI_ISteamNetworking_ReadP2PPacket"}, missing);
        bind(dll, accept, {"SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser"}, missing);
        if (!missing.empty()) {
            reason = "steam_api64.dll is missing: " + missing;
            return false;
        }
        if (user_acc() == nullptr || net_acc() == nullptr) {
            tried = false; // Steam not initialised by the game yet; try again later
            reason = "Steam is not initialised yet";
            return false;
        }
        std::string optional;
        bind(dll, user_data_folder, {"SteamAPI_ISteamUser_GetUserDataFolder"}, optional);
        bind(dll, friend_state, {"SteamAPI_ISteamFriends_GetFriendPersonaState"}, optional);
        bind(dll, friend_relationship, {"SteamAPI_ISteamFriends_GetFriendRelationship"}, optional);
        bind(dll, invite_user, {"SteamAPI_ISteamFriends_InviteUserToGame"}, optional);
        bind(dll, overlay_invite, {"SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString"}, optional);
        bind(dll, apps_acc, {"SteamAPI_SteamApps_v008"}, optional);
        bind(dll, launch_cmdline, {"SteamAPI_ISteamApps_GetLaunchCommandLine"}, optional);
        ok = true;
        reason = "ok";
        return true;
    }
};

Steam g_steam;
std::mutex g_mutex;

struct Friend {
    std::string name;
};
std::unordered_map<std::uint64_t, Friend> g_friends; // friends currently in Monster Hunter Wilds
DWORD g_friends_at = 0;
bool g_friends_valid = false;

bool is_individual(std::uint64_t id) { return (id >> 32) == 0x01100001u && (id & 0xFFFFFFFFu) != 0; }

// ---- Trusted ids ----------------------------------------------------------------------------------------------------
// No Steam callbacks (1.3.0): pending P2P session requests from friends / trusted ids are accepted by polling
// (refresh_friends), and sending to someone accepts their session too.

std::mutex g_cb_mutex;
std::unordered_set<std::uint64_t> g_trusted;
struct Event {
    std::string kind;
    std::uint64_t from;
    std::string connect;
};
std::vector<Event> g_events; // stays empty: kept so events() keeps its shape for older Lua
std::vector<std::string> g_loopback; // send_self -> poll

constexpr int kRelationshipFriend = 3;

bool is_trusted(std::uint64_t id) {
    std::lock_guard lock{g_cb_mutex};
    return g_trusted.count(id) != 0;
}

bool is_friend(std::uint64_t id) {
    if (g_steam.friend_relationship == nullptr) return false;
    void* f = g_steam.friends_acc();
    return f != nullptr && g_steam.friend_relationship(f, id) == kRelationshipFriend;
}

// Who may talk to us: ourselves, trusted ids, Steam friends whatever their presence.
bool allowed(std::uint64_t id, std::uint64_t self) { return id != 0 && (id == self || is_trusted(id) || is_friend(id)); }

void refresh_friends() {
    const DWORD now = GetTickCount();
    if (g_friends_valid && now - g_friends_at < kFriendRefreshMs) return;
    g_friends_at = now;
    g_friends_valid = true;
    g_friends.clear();
    void* f = g_steam.friends_acc();
    if (f == nullptr) return;
    const int count = g_steam.friend_count(f, kFriendFlagImmediate);
    for (int i = 0; i < count && i < 2000; ++i) {
        const std::uint64_t id = g_steam.friend_by_index(f, i, kFriendFlagImmediate);
        if (!is_individual(id)) continue;
        alignas(8) unsigned char info[64]{}; // FriendGameInfo_t starts with CGameID; oversized on purpose
        if (!g_steam.friend_game(f, id, info)) continue;
        std::uint64_t game_id = 0;
        std::memcpy(&game_id, info, sizeof(game_id));
        if ((game_id & 0xFFFFFFu) != kAppId || ((game_id >> 24) & 0xFFu) != 0) continue;
        const char* name = g_steam.friend_name(f, id);
        g_friends[id] = Friend{name != nullptr ? name : ""};
        // Accept P2P session requests from friends in the game only; anyone else's requests time out.
        g_steam.accept(g_steam.net_acc(), id);
    }
    std::vector<std::uint64_t> trusted;
    {
        std::lock_guard lock{g_cb_mutex};
        trusted.assign(g_trusted.begin(), g_trusted.end());
    }
    for (const std::uint64_t id : trusted) g_steam.accept(g_steam.net_acc(), id);
}

std::uint64_t to_id(lua_State* L, int idx) {
    const char* s = lua_type(L, idx) == LUA_TSTRING ? lua_tostring(L, idx) : nullptr;
    return s != nullptr ? std::strtoull(s, nullptr, 10) : 0;
}

void push_id(lua_State* L, std::uint64_t id) {
    const std::string s = std::to_string(id);
    lua_pushlstring(L, s.data(), s.size());
}

// ---- Lua functions (no luaL_check*: they would raise errors across the DLL boundary) ------------------------------

int l_available(lua_State* L) {
    std::lock_guard lock{g_mutex};
    const bool ok = g_steam.ready();
    lua_pushboolean(L, ok);
    lua_pushstring(L, g_steam.reason.c_str());
    return 2;
}

int l_self_id(lua_State* L) {
    std::lock_guard lock{g_mutex};
    if (!g_steam.ready()) {
        lua_pushnil(L);
        return 1;
    }
    push_id(L, g_steam.get_steam_id(g_steam.user_acc()));
    return 1;
}

void push_all_friends(lua_State* L) {
    void* f = g_steam.friends_acc();
    if (f == nullptr) return;
    const int count = g_steam.friend_count(f, kFriendFlagImmediate);
    int out = 0;
    for (int i = 0; i < count && i < 2000; ++i) {
        const std::uint64_t id = g_steam.friend_by_index(f, i, kFriendFlagImmediate);
        if (!is_individual(id)) continue;
        lua_newtable(L);
        push_id(L, id);
        lua_setfield(L, -2, "id");
        const char* name = g_steam.friend_name(f, id);
        lua_pushstring(L, name != nullptr ? name : "");
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, g_friends.count(id) != 0);
        lua_setfield(L, -2, "in_game");
        lua_pushinteger(L, g_steam.friend_state != nullptr ? g_steam.friend_state(f, id) : -1);
        lua_setfield(L, -2, "state");
        lua_rawseti(L, -2, ++out);
    }
}

int l_friends(lua_State* L) {
    std::lock_guard lock{g_mutex};
    const bool all = lua_toboolean(L, 1) != 0;
    lua_newtable(L);
    if (!g_steam.ready()) return 1;
    refresh_friends();
    if (all) {
        push_all_friends(L);
        return 1;
    }
    int i = 0;
    for (const auto& [id, fr] : g_friends) {
        lua_newtable(L);
        push_id(L, id);
        lua_setfield(L, -2, "id");
        lua_pushlstring(L, fr.name.data(), fr.name.size());
        lua_setfield(L, -2, "name");
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "in_game");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}

int l_send(lua_State* L) {
    std::lock_guard lock{g_mutex};
    const std::uint64_t to = to_id(L, 1);
    std::size_t len = 0;
    const char* data = lua_type(L, 2) == LUA_TSTRING ? lua_tolstring(L, 2, &len) : nullptr;
    const bool reliable = lua_toboolean(L, 3) != 0;
    bool sent = false;
    if (g_steam.ready() && data != nullptr && len > 0 && len <= kMaxBytes) {
        refresh_friends();
        const std::uint64_t self = g_steam.get_steam_id(g_steam.user_acc());
        if (to != self && allowed(to, self)) {
            const int type = (reliable || len > kMaxUnreliable) ? kP2PReliable : kP2PUnreliable;
            sent = g_steam.send(g_steam.net_acc(), to, data, static_cast<std::uint32_t>(len), type, kChannel);
        }
    }
    lua_pushboolean(L, sent);
    return 1;
}

// Loopback to ourselves inside the plugin; poll() returns it with from == self_id().
int l_send_self(lua_State* L) {
    std::lock_guard lock{g_mutex};
    std::size_t len = 0;
    const char* data = lua_type(L, 1) == LUA_TSTRING ? lua_tolstring(L, 1, &len) : nullptr;
    bool sent = false;
    if (g_steam.ready() && data != nullptr && len > 0 && len <= kMaxBytes) {
        if (g_loopback.size() < static_cast<std::size_t>(kMaxPoll)) {
            g_loopback.emplace_back(data, len);
            sent = true;
        }
    }
    lua_pushboolean(L, sent);
    return 1;
}

int l_poll(lua_State* L) {
    std::lock_guard lock{g_mutex};
    lua_newtable(L);
    if (!g_steam.ready()) return 1;
    refresh_friends();
    const std::uint64_t self = g_steam.get_steam_id(g_steam.user_acc());
    int out = 0;
    for (const std::string& d : g_loopback) {
        lua_newtable(L);
        push_id(L, self);
        lua_setfield(L, -2, "from");
        lua_pushlstring(L, d.data(), d.size());
        lua_setfield(L, -2, "data");
        lua_rawseti(L, -2, ++out);
    }
    g_loopback.clear();
    void* net = g_steam.net_acc();
    std::vector<char> buf;
    std::uint32_t size = 0;
    for (int i = 0; net != nullptr && i < kMaxPoll && g_steam.available(net, &size, kChannel); ++i) {
        buf.resize(std::max<std::size_t>(size, 1));
        std::uint32_t got = 0;
        std::uint64_t from = 0;
        if (!g_steam.read(net, buf.data(), static_cast<std::uint32_t>(buf.size()), &got, &from, kChannel)) break;
        if ((g_friends.count(from) != 0 || allowed(from, self)) && got > 0 && got <= kMaxBytes) {
            lua_newtable(L);
            push_id(L, from);
            lua_setfield(L, -2, "from");
            lua_pushlstring(L, buf.data(), got);
            lua_setfield(L, -2, "data");
            lua_rawseti(L, -2, ++out);
        }
    }
    return 1;
}

int l_trust(lua_State* L) {
    std::unordered_set<std::uint64_t> ids;
    if (lua_type(L, 1) == LUA_TTABLE) {
        for (lua_Integer i = 1; i <= 256; ++i) {
            if (lua_geti(L, 1, i) != LUA_TSTRING) { lua_pop(L, 1); break; }
            const std::uint64_t id = std::strtoull(lua_tostring(L, -1), nullptr, 10);
            lua_pop(L, 1);
            if (is_individual(id)) ids.insert(id);
        }
    }
    std::size_t n = 0;
    {
        std::lock_guard lock{g_cb_mutex};
        g_trusted = std::move(ids);
        n = g_trusted.size();
    }
    {
        std::lock_guard lock{g_mutex};
        g_friends_valid = false; // re-accept sessions with the new list on the next refresh
    }
    lua_pushinteger(L, static_cast<lua_Integer>(n));
    return 1;
}

// connect strings: printable ASCII only, <= 255 bytes
bool clean_connect(lua_State* L, int idx, std::string& out) {
    std::size_t len = 0;
    const char* c = lua_type(L, idx) == LUA_TSTRING ? lua_tolstring(L, idx, &len) : nullptr;
    if (c == nullptr || len == 0 || len > 255) return false;
    for (std::size_t i = 0; i < len; ++i)
        if (c[i] < 0x20 || c[i] > 0x7e) return false;
    out.assign(c, len);
    return true;
}

int l_invite(lua_State* L) {
    std::lock_guard lock{g_mutex};
    const std::uint64_t to = to_id(L, 1);
    std::string connect;
    bool ok = false;
    if (g_steam.ready() && g_steam.invite_user != nullptr && is_individual(to) && clean_connect(L, 2, connect)) {
        if (void* f = g_steam.friends_acc()) ok = g_steam.invite_user(f, to, connect.c_str());
    }
    lua_pushboolean(L, ok);
    return 1;
}

int l_overlay_invite(lua_State* L) {
    std::lock_guard lock{g_mutex};
    std::string connect;
    bool ok = false;
    if (g_steam.ready() && g_steam.overlay_invite != nullptr && clean_connect(L, 1, connect)) {
        if (void* f = g_steam.friends_acc()) {
            g_steam.overlay_invite(f, connect.c_str());
            ok = true;
        }
    }
    lua_pushboolean(L, ok);
    return 1;
}

int l_events(lua_State* L) {
    std::vector<Event> evs;
    {
        std::lock_guard lock{g_cb_mutex};
        evs.swap(g_events);
    }
    lua_newtable(L);
    int i = 0;
    for (const auto& e : evs) {
        lua_newtable(L);
        lua_pushlstring(L, e.kind.data(), e.kind.size());
        lua_setfield(L, -2, "kind");
        push_id(L, e.from);
        lua_setfield(L, -2, "from");
        lua_pushlstring(L, e.connect.data(), e.connect.size());
        lua_setfield(L, -2, "connect");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}

int l_launch_connect(lua_State* L) {
    std::lock_guard lock{g_mutex};
    char buf[1024] = {};
    int n = 0;
    if (g_steam.ready() && g_steam.apps_acc != nullptr && g_steam.launch_cmdline != nullptr) {
        if (void* a = g_steam.apps_acc()) n = g_steam.launch_cmdline(a, buf, sizeof(buf));
    }
    lua_pushlstring(L, buf, n > 0 ? strnlen(buf, sizeof(buf)) : 0);
    return 1;
}

int l_callbacks(lua_State* L) {
    std::lock_guard lock{g_mutex};
    lua_pushboolean(L, false); // 1.3.0 registers no Steam callbacks
    return 1;
}

// ---- Save backup ----------------------------------------------------------------------------------------------------

namespace fs = std::filesystem;
constexpr std::size_t kKeepBackups = 20;

fs::path game_dir() {
    wchar_t buf[MAX_PATH * 4];
    const DWORD n = GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(std::size(buf)));
    return fs::path(std::wstring(buf, n)).parent_path();
}

// Steam gives <Steam>/userdata/<account>/<app>/local; the game's Steam Cloud saves are in ../remote.
bool save_dir(fs::path& out, std::string& why) {
    if (!g_steam.ready()) return why = g_steam.reason, false;
    if (g_steam.user_data_folder == nullptr) return why = "Steam can't tell where the saves are", false;
    char buf[1024] = {};
    if (!g_steam.user_data_folder(g_steam.user_acc(), buf, sizeof(buf)) || buf[0] == 0)
        return why = "Steam didn't return the save folder", false;
    fs::path local(buf);
    if (!local.has_filename()) local = local.parent_path(); // trailing slash
    out = local.parent_path() / "remote";
    std::error_code ec;
    if (!fs::is_directory(out, ec)) return why = "no save folder at " + out.string(), false;
    return true;
}

// tag: letters, digits, '-' and '_' only.
std::string clean_tag(const char* tag) {
    std::string out;
    for (const char* c = tag ? tag : ""; *c && out.size() < 32; ++c)
        if (std::isalnum(static_cast<unsigned char>(*c)) || *c == '-' || *c == '_') out += *c;
    return out.empty() ? "backup" : out;
}

bool backup_saves(const char* tag, std::string& result) {
    try {
        fs::path src;
        if (!save_dir(src, result)) return false;
        const fs::path root = game_dir() / "reframework" / "data" / "wilds_seamless_coop" / "save_backups";
        char stamp[32];
        const std::time_t now = std::time(nullptr);
        std::strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", std::localtime(&now));
        const fs::path dst = root / (std::string(stamp) + "-" + clean_tag(tag));
        fs::create_directories(dst);
        std::size_t files = 0;
        for (const auto& e : fs::recursive_directory_iterator(src)) {
            const fs::path to = dst / fs::relative(e.path(), src);
            if (e.is_directory()) {
                fs::create_directories(to);
            } else if (e.is_regular_file()) {
                fs::create_directories(to.parent_path());
                fs::copy_file(e.path(), to, fs::copy_options::overwrite_existing);
                if (fs::file_size(to) != e.file_size()) return result = "copy of " + e.path().string() + " is incomplete", false;
                ++files;
            }
        }
        if (files == 0) return result = "no save files in " + src.string(), false;

        // Keep the newest kKeepBackups folders (names sort by time).
        std::vector<fs::path> all;
        for (const auto& e : fs::directory_iterator(root))
            if (e.is_directory()) all.push_back(e.path());
        std::sort(all.begin(), all.end());
        for (std::size_t i = 0; i + kKeepBackups < all.size(); ++i) {
            std::error_code ec;
            fs::remove_all(all[i], ec);
        }
        result = dst.string();
        return true;
    } catch (const std::exception& e) {
        result = e.what();
        return false;
    }
}

int l_backup_saves(lua_State* L) {
    std::lock_guard lock(g_mutex);
    std::string result;
    const bool ok = backup_saves(lua_type(L, 1) == LUA_TSTRING ? lua_tostring(L, 1) : nullptr, result);
    lua_pushboolean(L, ok);
    lua_pushlstring(L, result.data(), result.size());
    return 2;
}

// ---- Type database scan (diagnostics) -------------------------------------------------------------------------------

const REFrameworkSDKData* g_sdk = nullptr;
constexpr int kMaxScanResults = 12000;

std::string type_name(REFrameworkTypeDefinitionHandle t) {
    if (t == nullptr) return "?";
    char buf[512];
    unsigned int len = 0;
    if (g_sdk->type_definition->get_full_name(t, buf, sizeof(buf), &len) != REFRAMEWORK_ERROR_NONE) return "?";
    return std::string(buf, std::min<std::size_t>(len, sizeof(buf)));
}

bool contains_nocase(const char* hay, const std::string& needle) {
    const std::size_t n = std::strlen(hay);
    if (needle.size() > n) return false;
    for (std::size_t i = 0; i + needle.size() <= n; ++i) {
        std::size_t j = 0;
        while (j < needle.size() && std::tolower(static_cast<unsigned char>(hay[i + j])) == needle[j]) ++j;
        if (j == needle.size()) return true;
    }
    return false;
}

int l_scan(lua_State* L) {
    lua_newtable(L);
    if (g_sdk == nullptr || lua_type(L, 1) != LUA_TTABLE) return 1;
    std::vector<std::string> exact, partial, whole;
    for (lua_Integer i = 1;; ++i) {
        const int t = lua_geti(L, 1, i);
        if (t != LUA_TSTRING) { lua_pop(L, 1); break; }
        std::string s = lua_tostring(L, -1);
        lua_pop(L, 1);
        if (!s.empty() && (s[0] == '~' || s[0] == '@')) {
            const bool types = s[0] == '@';
            s.erase(0, 1);
            for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            if (s.size() >= 4) (types ? whole : partial).push_back(s);
        } else if (!s.empty()) {
            exact.push_back(s);
        }
    }
    const auto* tdbf = g_sdk->tdb;
    const auto* tf = g_sdk->type_definition;
    const auto* mf = g_sdk->method;
    const auto tdb = g_sdk->functions->get_tdb();
    if (tdb == nullptr) return 1;

    int found = 0;
    std::vector<REFrameworkMethodHandle> methods;
    const unsigned int ntypes = tdbf->get_num_types(tdb);
    for (unsigned int ti = 0; ti < ntypes && found < kMaxScanResults; ++ti) {
        const auto t = tdbf->get_type(tdb, ti);
        if (t == nullptr) continue;
        const unsigned int nm = tf->get_num_methods(t);
        if (nm == 0 || nm > 20000) continue;
        const char* ns = tf->get_namespace(t);
        const bool app = ns != nullptr && (std::strncmp(ns, "app", 3) == 0 || std::strncmp(ns, "ace", 3) == 0);
        bool all = false;
        if (app && !whole.empty()) {
            const std::string full = type_name(t);
            for (const auto& w : whole) all = all || contains_nocase(full.c_str(), w);
        }
        methods.assign(nm, nullptr);
        unsigned int count = 0;
        if (tf->get_methods(t, methods.data(), nm * sizeof(REFrameworkMethodHandle), &count) != REFRAMEWORK_ERROR_NONE) continue;
        for (unsigned int mi = 0; mi < count && found < kMaxScanResults; ++mi) {
            const auto m = methods[mi];
            const char* name = m ? mf->get_name(m) : nullptr;
            if (name == nullptr) continue;
            bool hit = all;
            for (const auto& e : exact) hit = hit || e == name;
            if (!hit && app)
                for (const auto& p : partial) hit = hit || contains_nocase(name, p);
            if (!hit) continue;

            lua_newtable(L);
            const std::string tn = type_name(t);
            lua_pushlstring(L, tn.data(), tn.size());
            lua_setfield(L, -2, "type");
            lua_pushstring(L, name);
            lua_setfield(L, -2, "method");
            lua_pushboolean(L, mf->is_static(m));
            lua_setfield(L, -2, "static");
            const std::string rn = type_name(mf->get_return_type(m));
            lua_pushlstring(L, rn.data(), rn.size());
            lua_setfield(L, -2, "ret");
            lua_newtable(L);
            REFrameworkMethodParameter params[32];
            unsigned int np = 0;
            if (mf->get_num_params(m) <= 32 && mf->get_params(m, params, sizeof(params), &np) == REFRAMEWORK_ERROR_NONE) {
                for (unsigned int pi = 0; pi < np; ++pi) {
                    const std::string pn = type_name(params[pi].t) + " " + (params[pi].name ? params[pi].name : "");
                    lua_pushlstring(L, pn.data(), pn.size());
                    lua_seti(L, -2, pi + 1);
                }
            }
            lua_setfield(L, -2, "params");
            lua_seti(L, -2, ++found);
        }
    }
    return 1;
}

// resolve({addr, ...}) -> { [i] = "Type.method+0xoff" }: nearest game method at or below each code address, for
// reading crash dumps (diagnostics only).
int l_resolve(lua_State* L) {
    lua_newtable(L);
    if (g_sdk == nullptr || lua_type(L, 1) != LUA_TTABLE) return 1;
    std::vector<std::uint64_t> want;
    for (lua_Integer i = 1;; ++i) {
        const int t = lua_geti(L, 1, i);
        if (t != LUA_TNUMBER && t != LUA_TSTRING) { lua_pop(L, 1); break; }
        want.push_back(t == LUA_TNUMBER ? static_cast<std::uint64_t>(lua_tointeger(L, -1))
                                        : std::strtoull(lua_tostring(L, -1), nullptr, 0));
        lua_pop(L, 1);
    }
    std::vector<std::uint64_t> best(want.size(), 0);
    std::vector<std::string> names(want.size());
    const auto* tdbf = g_sdk->tdb;
    const auto* tf = g_sdk->type_definition;
    const auto* mf = g_sdk->method;
    const auto tdb = g_sdk->functions->get_tdb();
    if (tdb == nullptr) return 1;
    std::vector<REFrameworkMethodHandle> methods;
    const unsigned int ntypes = tdbf->get_num_types(tdb);
    for (unsigned int ti = 0; ti < ntypes; ++ti) {
        const auto t = tdbf->get_type(tdb, ti);
        if (t == nullptr) continue;
        const unsigned int nm = tf->get_num_methods(t);
        if (nm == 0 || nm > 20000) continue;
        methods.assign(nm, nullptr);
        unsigned int count = 0;
        if (tf->get_methods(t, methods.data(), nm * sizeof(REFrameworkMethodHandle), &count) != REFRAMEWORK_ERROR_NONE) continue;
        for (unsigned int mi = 0; mi < count; ++mi) {
            if (methods[mi] == nullptr) continue;
            const auto f = reinterpret_cast<std::uint64_t>(mf->get_function(methods[mi]));
            if (f == 0) continue;
            for (std::size_t k = 0; k < want.size(); ++k) {
                if (f <= want[k] && f > best[k]) {
                    best[k] = f;
                    const char* n = mf->get_name(methods[mi]);
                    names[k] = type_name(t) + "." + (n ? n : "?");
                }
            }
        }
    }
    for (std::size_t k = 0; k < want.size(); ++k) {
        char off[32];
        std::snprintf(off, sizeof(off), "+0x%llx", static_cast<unsigned long long>(want[k] - best[k]));
        const std::string r = best[k] ? names[k] + off : std::string("?");
        lua_pushlstring(L, r.data(), r.size());
        lua_seti(L, -2, static_cast<lua_Integer>(k + 1));
    }
    return 1;
}

void on_lua_state_created(lua_State* L) {
    lua_newtable(L);
    lua_pushcfunction(L, l_available);
    lua_setfield(L, -2, "available");
    lua_pushcfunction(L, l_self_id);
    lua_setfield(L, -2, "self_id");
    lua_pushcfunction(L, l_friends);
    lua_setfield(L, -2, "friends");
    lua_pushcfunction(L, l_send);
    lua_setfield(L, -2, "send");
    lua_pushcfunction(L, l_poll);
    lua_setfield(L, -2, "poll");
    lua_pushcfunction(L, l_send_self);
    lua_setfield(L, -2, "send_self");
    lua_pushcfunction(L, l_backup_saves);
    lua_setfield(L, -2, "backup_saves");
    lua_pushcfunction(L, l_scan);
    lua_setfield(L, -2, "scan");
    lua_pushcfunction(L, l_resolve);
    lua_setfield(L, -2, "resolve");
    lua_pushcfunction(L, l_trust);
    lua_setfield(L, -2, "trust");
    lua_pushcfunction(L, l_invite);
    lua_setfield(L, -2, "invite");
    lua_pushcfunction(L, l_overlay_invite);
    lua_setfield(L, -2, "overlay_invite");
    lua_pushcfunction(L, l_events);
    lua_setfield(L, -2, "events");
    lua_pushcfunction(L, l_launch_connect);
    lua_setfield(L, -2, "launch_connect");
    lua_pushcfunction(L, l_callbacks);
    lua_setfield(L, -2, "callbacks");
    lua_pushstring(L, "1.3.0");
    lua_setfield(L, -2, "version");
    lua_setglobal(L, "seamless_net");
}

void on_lua_state_destroyed(lua_State*) {}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {
    v->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    v->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    v->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_sdk = param->sdk;
    param->functions->on_lua_state_created(on_lua_state_created);
    param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
    param->functions->log_info("[seamless_net] loaded");
    return true;
}
