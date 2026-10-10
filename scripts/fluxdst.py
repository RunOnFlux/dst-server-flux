#!/usr/bin/env python3
"""Everything the image decides about the server's files, and the commands the hub runs.

    fluxdst.py migrate          moves a world from an earlier image's layout into this one
    fluxdst.py apply            writes the cluster from the environment and flux/*.json
    fluxdst.py installed        reads the downloaded mods' modinfo.lua into flux/mods-installed.json
    fluxdst.py catalog          asks the running server for its world options (flux/world-options.json)
    fluxdst.py probe <shard>    exit 0 once that shard's world is loaded

    flux-dst status             the shards, the players, the day and season, as JSON
    flux-dst mods | set-mods <json>
    flux-dst world | set-world <json>

`flux-dst` on the PATH is this file. Every command prints JSON or log lines; the hub runs the
`flux-dst` ones through appexec, so each answer is one JSON document on stdout.

THE FILES THE IMAGE OWNS, AND THE ONES IT DOES NOT. The environment wins for what it sets (a
variable that is set, even to "", is written on every start); a key or file the environment does
not mention is left as the owner or the hub left it. flux/world.json and flux/mods.json are the
hub's: when one exists, the image writes worldgenoverride.lua / modoverrides.lua from it on every
start. Without them, those Lua files are the owner's own and are only mirrored to the caves.
"""

import fcntl
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/dst/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/dst/data")
CLUSTER = os.environ.get("FLUX_CLUSTER", "Cluster_1")
FLUX_DIR = os.environ.get("FLUX_DIR", os.path.join(DATA_DIR, "flux"))
CONSOLE_DIR = os.environ.get("FLUX_CONSOLE_DIR", "/tmp")
CONSOLE_LOCK = os.environ.get("FLUX_CONSOLE_LOCK", "/tmp/flux-console.lock")
LUA_HELPER = os.environ.get("FLUX_LUA_HELPER", os.path.join(os.path.dirname(os.path.realpath(__file__)), "flux-lua.lua"))
WORKSHOP_APP = "322330"
SHARDS = ("Master", "Caves")

CLUSTER_DIR = os.path.join(DATA_DIR, CLUSTER)
WORLD_JSON = os.path.join(FLUX_DIR, "world.json")
MODS_JSON = os.path.join(FLUX_DIR, "mods.json")
INSTALLED_JSON = os.path.join(FLUX_DIR, "mods-installed.json")
CATALOG_JSON = os.path.join(FLUX_DIR, "world-options.json")
STATE_JSON = os.path.join(FLUX_DIR, "state.json")

# The previous image's default (wollwolke/dst-dedicated-server cluster_default.ini): a key every
# one of its servers shared, replaced by one of our own.
SHARED_CLUSTER_KEY = "ThisIsTheSecretKeyForClusterCommunication"

# The five play styles of the game's Host Game screen (scripts/map/levels/forest.lua, build
# 756039): the forest preset each one starts from, and the settings it changes. The caves have
# one preset, DST_CAVE, and get the same settings.
PLAYSTYLES = {
    "survival": ("SURVIVAL_TOGETHER", {}),
    "relaxed": ("RELAXED", {
        "ghostsanitydrain": "none", "portalresurection": "always", "temperaturedamage": "nonlethal",
        "hunger": "nonlethal", "darkness": "nonlethal", "lessdamagetaken": "always",
        "healthpenalty": "none", "wildfires": "never", "hounds": "rare", "resettime": "none",
        "shadowcreatures": "rare", "brightmarecreatures": "rare",
    }),
    "endless": ("ENDLESS", {
        "portalresurection": "always", "basicresource_regrowth": "always", "resettime": "none",
        "ghostsanitydrain": "none",
    }),
    "wilderness": ("WILDERNESS", {
        "spawnmode": "scatter", "basicresource_regrowth": "always", "ghostenabled": "none",
        "ghostsanitydrain": "none", "resettime": "none",
    }),
    "lightsout": ("LIGHTS_OUT", {"day": "onlynight"}),
}
CAVE_PRESET = "DST_CAVE"

INTENTIONS = ("cooperative", "competitive", "social", "madness")
KLEI_ID = re.compile(r"^KU_[A-Za-z0-9_-]{4,32}$")
WORKSHOP_ID = re.compile(r"^[0-9]{1,20}$")
OPTION_NAME = re.compile(r"^[a-z0-9_]{1,48}$")
OPTION_VALUE = re.compile(r"^[A-Za-z0-9_.-]{1,48}$")


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print("WARN " + msg, flush=True)


def env(*names):
    """The first of these variables that is SET (even to ""), or None. Later names are the previous
    image's, so a server deployed with its spec keeps its settings."""
    for name in names:
        if name in os.environ:
            return os.environ[name]
    return None


def one_line(value, limit):
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", value).strip()
    return value[:limit]


def write_atomic(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".flux-tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except FileNotFoundError:
        return None


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def klei_json(raw):
    """JSON written by the game's own json.encode, which escapes an apostrophe as \\' (measured:
    "Winter\\'s Feast"): not valid JSON until that escape is undone."""
    return json.loads(re.sub(r"(?<!\\)((?:\\\\)*)\\'", r"\1'", raw))


def lua_read(mode, path, *args):
    """A Lua file of the game's as data (flux-lua.lua, sandboxed). None when it cannot be read."""
    try:
        out = subprocess.run(["lua5.1", LUA_HELPER, mode, path, *args], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        data = json.loads(out.stdout.strip() or "null")
    except ValueError:
        return None
    if out.returncode != 0 or not isinstance(data, dict):
        return None
    return data


# ------------------------------------------------------------------------------------------------
# INI files (cluster.ini, server.ini): edited in place, so comments, order and every key the image
# does not manage stay as they were.
# ------------------------------------------------------------------------------------------------

SECTION = re.compile(r"^\s*\[([^\]]+)\]\s*$")
KEY = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$")


class Ini:
    def __init__(self, text):
        self.lines = (text or "").splitlines()

    def _find(self, section, key):
        """(lines holding the key in that section, whether the section exists, where it ends)."""
        want = section.upper()
        cur, found, has_section, end = None, [], False, None
        for i, line in enumerate(self.lines):
            m = SECTION.match(line)
            if m:
                if cur == want and end is None:
                    end = i
                cur = m.group(1).strip().upper()
                has_section = has_section or cur == want
                continue
            m = KEY.match(line)
            if m and cur == want and m.group(1).lower() == key.lower():
                found.append(i)
        return found, has_section, end

    def get(self, section, key):
        found, _, _ = self._find(section, key)
        if not found:
            return None
        return KEY.match(self.lines[found[0]]).group(2)

    def set(self, section, key, value):
        """value None removes the key. Returns True when the file changed."""
        found, has_section, end = self._find(section, key)
        before = list(self.lines)
        if value is None:
            for i in reversed(found):
                del self.lines[i]
            return before != self.lines
        new = f"{key.lower()} = {value}"
        if found:
            self.lines[found[0]] = new
            for i in reversed(found[1:]):
                del self.lines[i]
        elif has_section:
            # After the section's last key, before the blank lines that end it.
            if end is None:
                end = len(self.lines)
            at = end
            while at > 0 and self.lines[at - 1].strip() == "":
                at -= 1
            self.lines.insert(at, new)
        else:
            if self.lines and self.lines[-1].strip() != "":
                self.lines.append("")
            self.lines += [f"[{section.upper()}]", new]
        return before != self.lines

    def text(self):
        return "\n".join(self.lines).rstrip("\n") + "\n"


def boolean(raw):
    v = raw.strip().lower()
    if v in ("1", "true", "yes", "on"):
        return "true"
    if v in ("0", "false", "no", "off"):
        return "false"
    return None


def int_range(lo, hi):
    def check(raw):
        raw = raw.strip()
        if not re.fullmatch(r"[0-9]{1,4}", raw):
            return None
        v = int(raw, 10)
        return str(v) if lo <= v <= hi else None
    return check


def text(limit, allow_empty=True):
    def check(raw):
        v = one_line(raw, limit)
        if not v and not allow_empty:
            return None
        return v
    return check


def choice(*values):
    def check(raw):
        v = raw.strip().lower()
        return v if v in values else None
    return check


def pattern(regex, allow_empty=True):
    def check(raw):
        v = raw.strip()
        if v == "" and allow_empty:
            return ""
        return v if re.fullmatch(regex, v) else None
    return check


# (section, key, variables, check). A variable that is set is written; an invalid value is
# reported and the file's own value kept.
CLUSTER_SETTINGS = [
    ("GAMEPLAY", "max_players", ("DST_MAX_PLAYERS", "MAX_PLAYERS"), int_range(1, 64)),
    ("GAMEPLAY", "pvp", ("DST_PVP", "PVP"), boolean),
    ("GAMEPLAY", "pause_when_empty", ("DST_PAUSE_WHEN_EMPTY", "PAUSE_WHEN_EMPTY"), boolean),
    ("GAMEPLAY", "vote_enabled", ("DST_VOTE_ENABLED",), boolean),
    ("NETWORK", "cluster_name", ("DST_NAME", "CLUSTER_NAME"), text(80, allow_empty=False)),
    ("NETWORK", "cluster_description", ("DST_DESCRIPTION", "CLUSTER_DESCRIPTION"), text(400)),
    ("NETWORK", "cluster_password", ("DST_PASSWORD", "CLUSTER_PW"), text(64)),
    ("NETWORK", "cluster_intention", ("DST_INTENTION", "CLUSTER_INTENTION"), choice(*INTENTIONS)),
    ("NETWORK", "cluster_language", ("DST_LANGUAGE",), pattern(r"[a-z]{2}(_[a-z]{2,4})?")),
    ("NETWORK", "whitelist_slots", ("DST_WHITELIST_SLOTS",), int_range(0, 64)),
    ("NETWORK", "tick_rate", ("DST_TICK_RATE",), choice("10", "15", "20", "30", "60")),
    ("MISC", "max_snapshots", ("DST_MAX_SNAPSHOTS",), int_range(1, 30)),
    ("STEAM", "steam_group_id", ("DST_STEAM_GROUP_ID", "STEAM_GROUP_ID"), pattern(r"[0-9]{1,20}")),
    ("STEAM", "steam_group_only", ("DST_STEAM_GROUP_ONLY", "STEAM_GROUP_ONLY"), boolean),
    ("STEAM", "steam_group_admins", ("DST_STEAM_GROUP_ADMINS", "STEAM_GROUP_ADMINS"), boolean),
]

NEW_CLUSTER = """[GAMEPLAY]
game_mode = survival
max_players = 6
pvp = false
pause_when_empty = true

[NETWORK]
cluster_name = Don't Starve Together on Flux
cluster_description =
cluster_password =
cluster_intention = cooperative

[MISC]
console_enabled = true
max_snapshots = 6

[SHARD]
shard_enabled = true
"""


def caves_enabled():
    v = os.environ.get("DST_CAVES", "")
    return v.strip() == "" or boolean(v) == "true"


def port(name, default):
    raw = os.environ.get(name, "").strip()
    if raw == "":
        return default
    if re.fullmatch(r"[0-9]{1,5}", raw) and 1024 <= int(raw) <= 65535:
        return int(raw)
    warn(f"{name}={raw!r} is not a port; using {default}")
    return default


def playstyle():
    """The play style the image writes the worlds for, or None when it does not manage them."""
    world = read_json(WORLD_JSON)
    candidates = []
    if isinstance(world, dict) and world.get("playstyle"):
        candidates.append(("flux/world.json", str(world["playstyle"])))
    raw = os.environ.get("DST_PLAYSTYLE", "").strip()
    if raw:
        candidates.append(("DST_PLAYSTYLE", raw))
    for source, value in candidates:
        v = value.lower().replace(" ", "").replace("_", "")
        if v in PLAYSTYLES:
            return v
        warn(f"{source}: play style {value!r} is not one of {', '.join(PLAYSTYLES)}")
    if isinstance(world, dict):
        return "survival"
    return None


def apply_cluster_ini():
    path = os.path.join(CLUSTER_DIR, "cluster.ini")
    existing = read_text(path)
    ini = Ini(existing if existing is not None else NEW_CLUSTER)
    if existing is None:
        log("cluster.ini: new cluster")
    for section, key, names, check in CLUSTER_SETTINGS:
        raw = env(*names)
        if raw is None:
            continue
        value = check(raw)
        if value is None:
            warn(f"{names[0]}={raw!r} is not a valid {key}; keeping {ini.get(section, key)!r}")
            continue
        if ini.set(section, key, value):
            shown = "(set)" if key == "cluster_password" and value else value
            log(f"cluster.ini: {key} = {shown}")
    # The play styles replaced game_mode: a server that still says endless or wilderness is
    # converted by the game on start; with the play style written into the worlds, it is survival.
    if playstyle() is not None or ini.get("GAMEPLAY", "game_mode") is None:
        ini.set("GAMEPLAY", "game_mode", "survival")
    # The console is how the image saves, reads the status and lists the world options.
    ini.set("MISC", "console_enabled", "true")
    offline = os.environ.get("FLUX_OFFLINE")
    if offline is not None:
        ini.set("NETWORK", "offline_cluster", boolean(offline) or "false")
    # Both shards run in this container and talk over the loopback.
    ini.set("SHARD", "shard_enabled", "true" if caves_enabled() else "false")
    ini.set("SHARD", "bind_ip", "127.0.0.1")
    ini.set("SHARD", "master_ip", "127.0.0.1")
    ini.set("SHARD", "master_port", str(port("FLUX_SHARD_PORT", 10888)))
    key = ini.get("SHARD", "cluster_key")
    if not key or key == SHARED_CLUSTER_KEY:
        ini.set("SHARD", "cluster_key", secrets.token_hex(16))
    if ini.text() != (existing or ""):
        write_atomic(path, ini.text())


def apply_server_ini(shard):
    master = shard == "Master"
    path = os.path.join(CLUSTER_DIR, shard, "server.ini")
    existing = read_text(path)
    ini = Ini(existing)
    ini.set("NETWORK", "server_port", str(port("DST_PORT", 11000) if master else port("DST_CAVES_PORT", 10999)))
    ini.set("SHARD", "is_master", "true" if master else "false")
    if master:
        ini.set("SHARD", "name", None)
    else:
        ini.set("SHARD", "name", "Caves")
    ini.set("STEAM", "master_server_port", str(port("DST_STEAM_PORT", 27016) if master else port("DST_CAVES_STEAM_PORT", 27017)))
    ini.set("STEAM", "authentication_port", str(8766 if master else 8767))
    if ini.get("ACCOUNT", "encode_user_path") is None:
        ini.set("ACCOUNT", "encode_user_path", "true")
    if ini.text() != (existing or ""):
        write_atomic(path, ini.text())
        log(f"{shard}/server.ini: port {ini.get('NETWORK', 'server_port')}")


def apply_token():
    raw = env("DST_CLUSTER_TOKEN", "CLUSTER_TOKEN")
    path = os.path.join(CLUSTER_DIR, "cluster_token.txt")
    if raw is not None and raw.strip():
        token = raw.strip()
        if not re.fullmatch(r"[!-~]{20,512}", token):
            warn("DST_CLUSTER_TOKEN is not a Klei cluster token (one line, no spaces); not written")
        elif (read_text(path) or "").strip() != token:
            write_atomic(path, token + "\n", 0o600)
            log("cluster_token.txt: written from DST_CLUSTER_TOKEN")
    present = bool((read_text(path) or "").strip())
    log("token: " + ("present" if present else "MISSING"))
    return present


def apply_admins():
    raw = env("DST_ADMINS", "GAME_ADMINS")
    if raw is None:
        return
    ids, bad = [], []
    for item in re.split(r"[\s,;]+", raw.strip()):
        if not item:
            continue
        (ids if KLEI_ID.fullmatch(item) else bad).append(item)
    for item in bad:
        warn(f"DST_ADMINS: {item!r} is not a Klei ID (KU_...); left out")
    ids = list(dict.fromkeys(ids))
    path = os.path.join(CLUSTER_DIR, "adminlist.txt")
    text_ = "".join(i + "\n" for i in ids)
    if (read_text(path) or "") != text_:
        write_atomic(path, text_)
        log(f"adminlist.txt: {len(ids)} admin(s)")


# ------------------------------------------------------------------------------------------------
# The worlds: worldgenoverride.lua, the file the game reads FOR USERS (a preset plus overrides;
# shardindex.lua). It is applied on every start, so changed SETTINGS reach an existing world
# (measured: hounds never -> often); world GENERATION options only matter when a world is made.
# The game rewrites the file after each save with the world's own overrides.
# ------------------------------------------------------------------------------------------------


def lua_string(s):
    out = []
    for ch in str(s):
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def lua_value(v, depth=0):
    if depth > 10:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v) if v == v and abs(v) != float("inf") else "0"
    if isinstance(v, str):
        return lua_string(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua_value(x, depth + 1) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"[{lua_string(k)}] = {lua_value(x, depth + 1)}" for k, x in v.items()) + " }"
    return "nil"


def catalog_values(location):
    """{option: set(values)} for a location from the server's own list, or None before it exists."""
    catalog = read_json(CATALOG_JSON)
    if not isinstance(catalog, dict) or not isinstance(catalog.get(location), dict):
        return None
    out = {}
    for kind in ("worldgen", "settings"):
        for item in catalog[location].get(kind) or []:
            if isinstance(item, dict) and item.get("name"):
                out[item["name"]] = {str(o.get("data")) for o in item.get("options") or [] if isinstance(o, dict)}
    return out


def clean_overrides(raw, location, source):
    if not isinstance(raw, dict):
        return {}
    known = catalog_values(location)
    out = {}
    for k, v in raw.items():
        k = str(k)
        if isinstance(v, bool):
            v = "true" if v else "false"
        v = str(v)
        if not OPTION_NAME.fullmatch(k) or not OPTION_VALUE.fullmatch(v):
            warn(f"{source}: {k!r} = {v!r} is not a world option; left out")
            continue
        if known is not None and (k not in known or v not in known[k]):
            warn(f"{source}: {k} = {v} is not an option of this game build's {location}; left out")
            continue
        out[k] = v
    return out


def worldgenoverride_text(preset, overrides):
    lines = ["return {", "\toverride_enabled = true,", f"\tworldgen_preset = {lua_string(preset)},",
             f"\tsettings_preset = {lua_string(preset)},", "\toverrides = {"]
    for k in sorted(overrides):
        lines.append(f"\t\t{k} = {lua_string(overrides[k])},")
    lines += ["\t},", "}", ""]
    return "\n".join(lines)


def apply_worlds():
    style = playstyle()
    world = read_json(WORLD_JSON)
    world = world if isinstance(world, dict) else {}
    caves_file = os.path.join(CLUSTER_DIR, "Caves", "worldgenoverride.lua")
    if style is None:
        # Not managed: the owner's own files. The caves still need their preset, or a caves shard
        # with no override file generates a SECOND FOREST.
        if caves_enabled() and not any(os.path.exists(os.path.join(CLUSTER_DIR, "Caves", f)) for f in ("worldgenoverride.lua", "leveldataoverride.lua")):
            write_atomic(caves_file, worldgenoverride_text(CAVE_PRESET, {}))
            log("Caves/worldgenoverride.lua: the caves preset")
        return
    preset, style_overrides = PLAYSTYLES[style]
    forest = dict(style_overrides)
    forest.update(clean_overrides(world.get("forest"), "forest", "flux/world.json forest"))
    write_atomic(os.path.join(CLUSTER_DIR, "Master", "worldgenoverride.lua"), worldgenoverride_text(preset, forest))
    cave_known = catalog_values("cave")
    cave = {k: v for k, v in style_overrides.items() if cave_known is None or (k in cave_known and v in cave_known[k])}
    cave.update(clean_overrides(world.get("cave"), "cave", "flux/world.json cave"))
    if caves_enabled():
        write_atomic(caves_file, worldgenoverride_text(CAVE_PRESET, cave))
    log(f"worlds: play style {style} ({preset}), {len(forest)} forest and {len(cave)} cave setting(s)")


# ------------------------------------------------------------------------------------------------
# Mods. The server downloads, at start, every Workshop item named in the install's
# mods/dedicated_server_mods_setup.lua (into the install's ugc_mods/, per shard), and loads the ones
# a shard's modoverrides.lua enables, with their configuration_options (measured).
# ------------------------------------------------------------------------------------------------


def split_ids(raw, source):
    ids = []
    for item in re.split(r"[\s,;]+", (raw or "").strip()):
        if not item:
            continue
        m = re.fullmatch(r"(?:workshop-)?([0-9]{1,20})", item) or re.search(r"[?&]id=([0-9]{1,20})", item)
        if m:
            ids.append(m.group(1))
        else:
            warn(f"{source}: {item!r} is not a Workshop ID; left out")
    return list(dict.fromkeys(ids))


def steam_post(url, fields, timeout=10):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "flux-dst"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def collection_items(collection):
    """The Workshop items in a collection, from Steam (no key needed), cached for when Steam is down."""
    cache = os.path.join(FLUX_DIR, f"collection-{collection}.json")
    try:
        data = steam_post("https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/",
                          {"collectioncount": 1, "publishedfileids[0]": collection})
        details = data["response"]["collectiondetails"][0]
        ids = [c["publishedfileid"] for c in details.get("children") or [] if str(c.get("filetype", 0)) == "0"]
        write_atomic(cache, json.dumps(ids))
        return ids
    except Exception as e:  # noqa: BLE001 - any failure falls back to the last answer
        cached = read_json(cache)
        if isinstance(cached, list):
            warn(f"collection {collection}: Steam did not answer ({e}); using the last list ({len(cached)} items)")
            return cached
        warn(f"collection {collection}: Steam did not answer ({e}); its mods are downloaded but not enabled")
        return []


def mods_config():
    """flux/mods.json as {"mods": [...], "collection": str}, or None when there is none."""
    raw = read_json(MODS_JSON)
    if not isinstance(raw, dict):
        return None
    return validate_mods(raw)[0]


def validate_mods(raw):
    errors = []
    mods, seen = [], set()
    for entry in raw.get("mods") or []:
        if not isinstance(entry, dict):
            errors.append("a mod entry is not an object")
            continue
        mid = str(entry.get("id", "")).strip()
        mid = mid[len("workshop-"):] if mid.startswith("workshop-") else mid
        if not WORKSHOP_ID.fullmatch(mid):
            errors.append(f"{entry.get('id')!r} is not a Workshop ID")
            continue
        if mid in seen:
            continue
        seen.add(mid)
        options = entry.get("options") or {}
        if not isinstance(options, dict):
            errors.append(f"mod {mid}: options is not an object")
            options = {}
        mods.append({"id": mid, "enabled": entry.get("enabled", True) is not False, "options": options})
    collection = str(raw.get("collection") or "").strip()
    if collection and not WORKSHOP_ID.fullmatch(collection):
        errors.append(f"collection {collection!r} is not a Workshop ID")
        collection = ""
    return {"mods": mods, "collection": collection}, errors


def modoverrides_text(mods):
    lines = ["-- Written by the Flux image from flux/mods.json (the hub's Mods tab) on every start.",
             "-- Edit the mods there; to manage this file by hand, delete flux/mods.json.", "return {"]
    for m in mods:
        opts = m.get("options") or {}
        body = f"enabled = {'true' if m['enabled'] else 'false'}"
        if opts:
            body += ", configuration_options = " + lua_value(opts)
        lines.append(f"\t[{lua_string('workshop-' + m['id'])}] = {{ {body} }},")
    lines += ["}", ""]
    return "\n".join(lines)


def apply_mods():
    config = mods_config()
    extra = split_ids(env("DST_MODS"), "DST_MODS")
    collection = (env("DST_MOD_COLLECTION", "MOD_COLLECTION") or "").strip()
    collection = (split_ids(collection, "DST_MOD_COLLECTION") or [""])[0]
    if config and config.get("collection"):
        collection = config["collection"]
    master_file = os.path.join(CLUSTER_DIR, "Master", "modoverrides.lua")
    managed = config is not None or extra or collection
    if managed:
        mods = list((config or {}).get("mods") or [])
        known = {m["id"] for m in mods}
        coll_ids = collection_items(collection) if collection else []
        for mid in extra + coll_ids:
            if mid not in known:
                mods.append({"id": mid, "enabled": True, "options": {}})
                known.add(mid)
        write_atomic(master_file, modoverrides_text(mods))
        ids = [m["id"] for m in mods]
        log(f"mods: {sum(1 for m in mods if m['enabled'])} enabled of {len(mods)}" + (f", collection {collection}" if collection else ""))
    else:
        ids = re.findall(r"workshop-([0-9]{1,20})", read_text(master_file) or "")
        ids = list(dict.fromkeys(ids))
        if ids:
            log(f"mods: {len(ids)} in the owner's modoverrides.lua")
    # Mods run on both shards: the caves get the surface's file.
    caves_file = os.path.join(CLUSTER_DIR, "Caves", "modoverrides.lua")
    if caves_enabled():
        master_text = read_text(master_file)
        if master_text is not None and read_text(caves_file) != master_text:
            write_atomic(caves_file, master_text)
        elif master_text is None and os.path.exists(caves_file):
            os.remove(caves_file)
    setup = ["-- Written by the Flux image on every start: the Workshop items to download.", ""]
    setup += [f'ServerModSetup("{i}")' for i in ids]
    if collection:
        setup.append(f'ServerModCollectionSetup("{collection}")')
    write_atomic(os.path.join(SERVER_DIR, "mods", "dedicated_server_mods_setup.lua"), "\n".join(setup) + "\n")


def cmd_apply():
    os.makedirs(os.path.join(CLUSTER_DIR, "Master"), exist_ok=True)
    if caves_enabled():
        os.makedirs(os.path.join(CLUSTER_DIR, "Caves"), exist_ok=True)
    apply_cluster_ini()
    apply_server_ini("Master")
    if caves_enabled():
        apply_server_ini("Caves")
    apply_admins()
    apply_worlds()
    if os.path.isdir(SERVER_DIR):
        apply_mods()
    # Offline (local tests only) needs no token; anything else cannot start without one.
    return 0 if apply_token() or boolean(os.environ.get("FLUX_OFFLINE", "")) == "true" else 3


# ------------------------------------------------------------------------------------------------
# Migration from runonflux's previous DST image (wollwolke/dst-dedicated-server): the cluster lived
# in /data/<CLUSTER_NAME>/ and the 4.3 GB game install in /data/dst_server (an m: mount, so it was
# SYNCED between instances). The same volume is mounted here at FLUX_DATA_DIR.
# ------------------------------------------------------------------------------------------------


def cmd_migrate():
    old_install = os.path.join(DATA_DIR, "dst_server")
    if os.path.isdir(os.path.join(old_install, "bin64")) or os.path.isdir(os.path.join(old_install, "steamapps")):
        subprocess.run(["rm", "-rf", old_install], check=False)
        log("removed the previous image's game install from the data volume (dst_server, re-downloaded locally)")
    if os.path.exists(os.path.join(CLUSTER_DIR, "cluster.ini")):
        return 0
    found = []
    try:
        names = os.listdir(DATA_DIR)
    except FileNotFoundError:
        return 0
    for name in names:
        path = os.path.join(DATA_DIR, name)
        if name in (CLUSTER, "flux") or not os.path.isdir(path):
            continue
        if os.path.isfile(os.path.join(path, "cluster.ini")):
            found.append((os.path.getmtime(path), name))
    if not found:
        return 0
    found.sort(reverse=True)
    name = found[0][1]
    os.replace(os.path.join(DATA_DIR, name), CLUSTER_DIR)
    log(f"moved the cluster {name!r} to {CLUSTER} (the previous image named the folder after the server)")
    for _, other in found[1:]:
        log(f"another cluster folder, {other!r}, is left where it is")
    return 0


# ------------------------------------------------------------------------------------------------
# The console, from Python: one line of Lua into a shard, and the lines it printed. Shares the lock
# with flux-console, so two answers never mix.
# ------------------------------------------------------------------------------------------------


def shard_running(shard):
    out = subprocess.run(["pgrep", "-f", rf"^\./dontstarve_dedicated_server_nullrenderer_x64 .*-shard {shard}( |$)"],
                         capture_output=True, text=True)
    return out.returncode == 0


def console_query(shard, lua, nonce, wait=None):
    """Sends `lua` to the shard; returns the payloads of its "FLUX <nonce> ..." lines, ending at
    "FLUX <nonce> END". None when the shard is not running or did not answer in time."""
    if wait is None:
        wait = float(os.environ.get("FLUX_CONSOLE_WAIT", "5"))
    fifo = os.path.join(CONSOLE_DIR, f"flux-console-{shard.lower()}")
    logf = os.path.join(CLUSTER_DIR, shard, "server_log.txt")
    if not shard_running(shard) or not os.path.exists(fifo):
        return None
    os.makedirs(os.path.dirname(CONSOLE_LOCK), exist_ok=True)
    with open(CONSOLE_LOCK, "w") as lock:
        deadline = time.time() + 15
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() > deadline:
                    return None
                time.sleep(0.1)
        start = os.path.getsize(logf) if os.path.exists(logf) else 0
        line = re.sub(r"[\x00-\x1f\x7f]", " ", lua) + "\n"
        try:
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            return None
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
        marker = re.compile(rf"FLUX {re.escape(nonce)} (\S+) ?(.*?)\s*$")
        out, end_at = [], time.time() + wait
        while time.time() < end_at:
            time.sleep(0.1)
            try:
                with open(logf, "rb") as f:
                    f.seek(start if os.path.getsize(logf) >= start else 0)
                    chunk = f.read().decode("utf-8", "replace")
            except FileNotFoundError:
                continue
            out = []
            for l in chunk.splitlines():
                if "RemoteCommandInput" in l:
                    continue
                m = marker.search(l)
                if m:
                    out.append((m.group(1), m.group(2)))
            if any(kind == "END" for kind, _ in out):
                return [(k, p) for k, p in out if k != "END"]
        return None


STATUS_LUA = (
    'local n="{n}" for _,c in ipairs(TheNet:GetClientTable() or {{}}) do '
    'if c.performance==nil and c.userid~=nil and c.userid~="" then '
    'print("FLUX "..n.." P "..json.encode({{name=c.name,userid=c.userid,prefab=c.prefab,age=c.playerage,admin=c.admin}})) end end '
    'for _,pl in ipairs(AllPlayers or {{}}) do if pl.userid then print("FLUX "..n.." H "..pl.userid) end end '
    'local s=TheWorld and TheWorld.state or {{}} '
    'print("FLUX "..n.." W "..json.encode({{day=(s.cycles or 0)+1,season=s.season,phase=s.phase,'
    'seasondays=s.remainingdaysinseason,fullmoon=s.isfullmoon,cave=TheWorld and TheWorld:HasTag("cave") or false}})) '
    'print("FLUX "..n.." END")'
)


def cmd_status():
    state = read_json(STATE_JSON, {}) or {}
    result = {"state": state.get("state", "unknown"), "message": state.get("message"), "build": state.get("build"),
              "caves": caves_enabled(), "shards": {}, "players": [], "world": None}
    # The client table is the whole cluster's (the game's Tab list); which shard a player stands
    # in is that shard's AllPlayers. A player in neither is between the two, or picking a character.
    seen, here = set(), {}
    for shard in SHARDS:
        nonce = secrets.token_hex(4)
        answer = console_query(shard, STATUS_LUA.format(n=nonce), nonce)
        result["shards"][shard] = {"running": shard_running(shard), "answered": answer is not None}
        for kind, payload in answer or []:
            if kind == "H":
                here[payload.strip()] = shard
                continue
            try:
                data = klei_json(payload)
            except ValueError:
                continue
            if kind == "P" and data.get("userid") not in seen:
                seen.add(data.get("userid"))
                data["shard"] = None
                result["players"].append(data)
            elif kind == "W" and shard == "Master":
                result["world"] = data
    for player in result["players"]:
        player["shard"] = here.get(player.get("userid"))
    ini = Ini(read_text(os.path.join(CLUSTER_DIR, "cluster.ini")))
    mp = ini.get("GAMEPLAY", "max_players")
    result["max_players"] = int(mp) if mp and mp.isdigit() else None
    result["name"] = ini.get("NETWORK", "cluster_name")
    print(json.dumps(result))
    return 0


READY_LUA = 'local n="{n}" if TheWorld~=nil then print("FLUX "..n.." R") end print("FLUX "..n.." END")'


def cmd_probe(shard):
    nonce = secrets.token_hex(4)
    answer = console_query(shard, READY_LUA.format(n=nonce), nonce, wait=3)
    return 0 if answer and any(k == "R" for k, _ in answer) else 1


# The world options, as the game's own Host Game screen has them (map/customize.lua): written by
# the server through its own file writer, because print() cuts a line at 4 KB (measured) and io is
# not available to the console. Labels are the game's English strings.
CATALOG_LUA = (
    'local C=require("map/customize") local S=STRINGS.UI.CUSTOMIZATIONSCREEN local out={{build=APP_VERSION}} '
    'for _,loc in ipairs({{"forest","cave"}}) do local r={{}} '
    'for _,kind in ipairs({{"worldgen","settings"}}) do '
    'local list=kind=="worldgen" and C.GetWorldGenOptions(loc,loc=="forest") or C.GetWorldSettingsOptions(loc,loc=="forest") '
    'for _,it in ipairs(list) do it.label=S[string.upper(it.name)] or it.name it.atlas=nil it.image=nil end r[kind]=list end out[loc]=r end '
    'TheSim:SetPersistentString("../flux-world-options.json", json.encode(out), false, function() print("FLUX {n} END") end)'
)


def cmd_catalog():
    nonce = secrets.token_hex(4)
    answer = console_query("Master", CATALOG_LUA.format(n=nonce), nonce, wait=15)
    src = os.path.join(CLUSTER_DIR, "Master", "flux-world-options.json")
    if answer is None or not os.path.exists(src):
        warn("the server did not write its world options")
        return 1
    raw = read_text(src) or ""
    os.remove(src)
    raw = re.sub(r"^KLEI\s+\d+\s", "", raw)
    try:
        data = klei_json(raw)
    except ValueError:
        warn("the server's world options are not JSON")
        return 1
    write_atomic(CATALOG_JSON, json.dumps(data))
    counts = {loc: sum(len(data[loc].get(k) or []) for k in ("worldgen", "settings")) for loc in ("forest", "cave") if isinstance(data.get(loc), dict)}
    log(f"world options: {counts.get('forest', 0)} forest, {counts.get('cave', 0)} cave (build {data.get('build')})")
    return 0


# ------------------------------------------------------------------------------------------------
# The installed mods, for the hub's Mods tab: what each downloaded mod calls itself and the options
# its author offers (configuration_options in modinfo.lua).
# ------------------------------------------------------------------------------------------------


def workshop_acf(shard):
    path = os.path.join(SERVER_DIR, "ugc_mods", CLUSTER, shard, f"appworkshop_{WORKSHOP_APP}.acf")
    text_ = read_text(path) or ""
    out = {}
    for mid, body in re.findall(r'"([0-9]+)"\s*\{([^{}]*)\}', text_):
        m = re.search(r'"timeupdated"\s+"([0-9]+)"', body)
        if m:
            out[mid] = int(m.group(1))
    return out


def clean_option(opt):
    if not isinstance(opt, dict):
        return None
    options = []
    for o in opt.get("options") or []:
        if isinstance(o, dict) and "data" in o:
            options.append({"description": str(o.get("description", o["data"])), "data": o["data"],
                            **({"hover": str(o["hover"])} if o.get("hover") else {})})
    return {"name": str(opt.get("name") or ""), "label": str(opt.get("label") or opt.get("name") or ""),
            "hover": str(opt.get("hover") or ""), "default": opt.get("default"), "options": options}


def cmd_installed():
    out = {}
    for shard in SHARDS:
        base = os.path.join(SERVER_DIR, "ugc_mods", CLUSTER, shard, "content", WORKSHOP_APP)
        if not os.path.isdir(base):
            continue
        updated = workshop_acf(shard)
        for mid in sorted(os.listdir(base)):
            if mid in out or not WORKSHOP_ID.fullmatch(mid):
                continue
            info = lua_read("modinfo", os.path.join(base, mid, "modinfo.lua"), f"workshop-{mid}")
            if info is None:
                out[mid] = {"error": "modinfo.lua could not be read"}
                continue
            opts = [o for o in (clean_option(x) for x in info.get("configuration_options") or []) if o]
            out[mid] = {
                "name": str(info.get("name") or mid).strip(),
                "version": str(info.get("version") or ""),
                "author": str(info.get("author") or ""),
                "description": str(info.get("description") or "")[:2000],
                "client_only": bool(info.get("client_only_mod")),
                "all_clients_require": bool(info.get("all_clients_require_mod")),
                "server_only": bool(info.get("server_only_mod")),
                "time_updated": updated.get(mid),
                "configuration_options": opts,
            }
    write_atomic(INSTALLED_JSON, json.dumps({"mods": out, "read_at": int(time.time())}))
    log(f"installed mods: {len(out)}")
    return 0


def stale_mods():
    """The installed Workshop items Steam has a newer version of. [] when Steam does not answer."""
    installed = {}
    for shard in SHARDS:
        for mid, t in workshop_acf(shard).items():
            installed[mid] = min(t, installed.get(mid, t))
    if not installed:
        return []
    fields = {"itemcount": len(installed)}
    for i, mid in enumerate(installed):
        fields[f"publishedfileids[{i}]"] = mid
    try:
        data = steam_post("https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/", fields)
    except Exception:  # noqa: BLE001
        return []
    stale = []
    for d in data.get("response", {}).get("publishedfiledetails") or []:
        mid = str(d.get("publishedfileid"))
        if mid in installed and int(d.get("time_updated") or 0) > installed[mid]:
            stale.append(mid)
    return stale


# ------------------------------------------------------------------------------------------------
# The hub's commands.
# ------------------------------------------------------------------------------------------------


def current_mods():
    config = mods_config()
    if config is not None:
        return {"managed": True, **config}
    master_file = os.path.join(CLUSTER_DIR, "Master", "modoverrides.lua")
    table = lua_read("table", master_file) if os.path.exists(master_file) else None
    mods = []
    for key, entry in (table or {}).items():
        m = re.fullmatch(r"workshop-([0-9]{1,20})", str(key))
        if not m or not isinstance(entry, dict):
            continue
        opts = entry.get("configuration_options") or {}
        mods.append({"id": m.group(1), "enabled": entry.get("enabled") is not False, "options": opts if isinstance(opts, dict) else {}})
    collection = (split_ids(env("DST_MOD_COLLECTION", "MOD_COLLECTION") or "", "DST_MOD_COLLECTION") or [""])[0]
    return {"managed": False, "mods": mods, "collection": collection}


def cmd_mods():
    print(json.dumps({"config": current_mods(), "installed": (read_json(INSTALLED_JSON, {}) or {}).get("mods", {}),
                      "env_mods": split_ids(env("DST_MODS") or "", "DST_MODS")}))
    return 0


def parse_arg_json(raw):
    try:
        data = json.loads(raw)
    except ValueError as e:
        print(json.dumps({"ok": False, "errors": [f"not JSON: {e}"]}))
        return None
    if not isinstance(data, dict):
        print(json.dumps({"ok": False, "errors": ["expected an object"]}))
        return None
    return data


def cmd_set_mods(raw):
    data = parse_arg_json(raw)
    if data is None:
        return 2
    config, errors = validate_mods(data)
    if errors:
        print(json.dumps({"ok": False, "errors": errors}))
        return 2
    write_atomic(MODS_JSON, json.dumps(config, indent=1))
    print(json.dumps({"ok": True, "restart_needed": True, "mods": len(config["mods"])}))
    return 0


def current_world():
    world = read_json(WORLD_JSON)
    if isinstance(world, dict):
        return {"managed": True, "playstyle": playstyle(), "forest": world.get("forest") or {}, "cave": world.get("cave") or {}}
    out = {"managed": False, "playstyle": playstyle()}
    for shard, loc in (("Master", "forest"), ("Caves", "cave")):
        t = lua_read("table", os.path.join(CLUSTER_DIR, shard, "worldgenoverride.lua"))
        out[loc] = (t or {}).get("overrides") or {}
    return out


def cmd_world():
    print(json.dumps({"config": current_world(), "catalog": read_json(CATALOG_JSON),
                      "playstyles": {k: {"preset": v[0], "overrides": v[1]} for k, v in PLAYSTYLES.items()}}))
    return 0


def cmd_set_world(raw):
    data = parse_arg_json(raw)
    if data is None:
        return 2
    errors = []
    style = str(data.get("playstyle") or "survival").lower()
    if style not in PLAYSTYLES:
        errors.append(f"play style {style!r} is not one of {', '.join(PLAYSTYLES)}")
    out = {"playstyle": style}
    for loc in ("forest", "cave"):
        raw_loc = data.get(loc) or {}
        if not isinstance(raw_loc, dict):
            errors.append(f"{loc} is not an object")
            continue
        known = catalog_values(loc)
        clean = {}
        for k, v in raw_loc.items():
            v = ("true" if v else "false") if isinstance(v, bool) else str(v)
            if not OPTION_NAME.fullmatch(str(k)) or not OPTION_VALUE.fullmatch(v):
                errors.append(f"{loc}: {k!r} = {v!r} is not a world option")
            elif known is not None and (k not in known or v not in known[k]):
                errors.append(f"{loc}: {k} = {v} is not an option of this game build")
            else:
                clean[str(k)] = v
        out[loc] = clean
    if errors:
        print(json.dumps({"ok": False, "errors": errors}))
        return 2
    write_atomic(WORLD_JSON, json.dumps(out, indent=1))
    print(json.dumps({"ok": True, "restart_needed": True}))
    return 0


def cmd_stale_mods():
    print(" ".join(stale_mods()))
    return 0


def main(argv):
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 64
    cmd, rest = argv[0], argv[1:]
    simple = {"migrate": cmd_migrate, "apply": cmd_apply, "installed": cmd_installed, "catalog": cmd_catalog,
              "status": cmd_status, "mods": cmd_mods, "world": cmd_world, "stale-mods": cmd_stale_mods}
    if cmd in simple and not rest:
        return simple[cmd]()
    if cmd == "probe" and len(rest) == 1 and rest[0] in SHARDS:
        return cmd_probe(rest[0])
    if cmd == "set-mods" and len(rest) == 1:
        return cmd_set_mods(rest[0])
    if cmd == "set-world" and len(rest) == 1:
        return cmd_set_world(rest[0])
    print(__doc__.strip(), file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
