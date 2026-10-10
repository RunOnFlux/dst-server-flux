# dst-server-flux

The Don't Starve Together dedicated server for [Flux](https://runonflux.io), as
`runonflux/dst-server-flux`. The game's native 64-bit Linux server (Steam app 343050), installed
and updated with SteamCMD on every start. **The surface and the caves run side by side in one
container**, linked over the loopback, under a supervisor that:

- writes the cluster from the environment: the Klei token, name, description, password, play
  style, player limit, PvP, admins, mods and the rest (`DST_*` below)
- saves both worlds on stop (SIGTERM, about 2 s measured; Flux allows 10)
- restarts the cluster in place when a shard dies, with a restart budget
- follows game updates and Workshop mod updates: an outdated DST server is hidden from the
  players' server list, so a newer build or mod means a restart (players are warned first)
- makes a backup of the cluster on every start and every 6 hours
- moves a world from the previous image's layout into this one
- gives the hub a console, a JSON status (players, day, season), the game's own list of world
  options and the installed mods' settings, and writes the worlds and mods the hub saves

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/dst/data` | `g:` (synced) | the persistent storage root: `Cluster_1/` (cluster.ini, the token, both shards' worlds and settings, admin/white/block lists) and `flux/` (our log, state, backups, the hub's files) |
| `/mnt/dst/server` | `ml:server` (local) | the game install, about 4.3 GB, and the Workshop mods (`ugc_mods/`). Downloaded again on a new node |

Spec: `g:/mnt/dst/data|ml:server:/mnt/dst/server`.

## Ports

| Variable | Default | |
|---|---|---|
| `DST_PORT` | 11000/udp | the surface's game port: players connect here |
| `DST_CAVES_PORT` | 10999/udp | the caves' game port: players are moved here when they go down a sinkhole, so it has to be public too |
| `DST_STEAM_PORT` | 27016/udp | the surface's Steam port |

The two shards talk to each other on `127.0.0.1:10888` (`FLUX_SHARD_PORT`), never public.
The public port and the container port must be the same number: the server announces its own
port to Klei's lobby.

## Environment

A variable that is **set** (even to `""`) is written on every start; one that is not set leaves
the file's own value. Names in brackets are the previous image's, still read.

| Variable | cluster.ini | |
|---|---|---|
| `DST_CLUSTER_TOKEN` (`CLUSTER_TOKEN`) | `cluster_token.txt` | **required.** accounts.klei.com > Games > Game Servers > Add New Server. Without one, or with one Klei refuses, the server does not start: `flux/state.json` says why, and it is tried again every 15 min |
| `DST_NAME` (`CLUSTER_NAME`) | `cluster_name` | the name in the server list |
| `DST_DESCRIPTION` | `cluster_description` | |
| `DST_PASSWORD` (`CLUSTER_PW`) | `cluster_password` | empty = no password |
| `DST_PLAYSTYLE` | worlds | `survival` (default), `relaxed`, `endless`, `wilderness`, `lightsout`: the Host Game screen's play styles. Changing it on an existing world changes its settings, not its map |
| `DST_CAVES` | `shard_enabled` | `true` (default) / `false`. Turning caves on later works: the sinkholes are already in the world |
| `DST_MAX_PLAYERS` (`MAX_PLAYERS`) | `max_players` | 1-64 |
| `DST_PVP` | `pvp` | |
| `DST_PAUSE_WHEN_EMPTY` | `pause_when_empty` | |
| `DST_INTENTION` | `cluster_intention` | `cooperative`, `competitive`, `social`, `madness` |
| `DST_LANGUAGE` | `cluster_language` | `en`, `pt`, `zh`... |
| `DST_ADMINS` (`GAME_ADMINS`) | `adminlist.txt` | Klei IDs (`KU_...`), comma separated |
| `DST_MODS` | `modoverrides.lua` | Workshop IDs or links, comma separated: downloaded and enabled with their default settings |
| `DST_MOD_COLLECTION` (`MOD_COLLECTION`) | `modoverrides.lua` | a Workshop collection: every mod in it downloaded and enabled |
| `DST_VOTE_ENABLED`, `DST_WHITELIST_SLOTS`, `DST_TICK_RATE`, `DST_MAX_SNAPSHOTS`, `DST_STEAM_GROUP_ID`, `DST_STEAM_GROUP_ONLY`, `DST_STEAM_GROUP_ADMINS` | the same keys | |

Supervisor knobs: `FLUX_BACKUP_HOURS` (6), `FLUX_BACKUP_KEEP` (5), `FLUX_UPDATE_CHECK_MINUTES` (30, 0 = off),
`FLUX_UPDATE_GRACE_MINUTES` (5), `FLUX_TOKEN_RETRY_MINUTES` (15), `FLUX_RESTART_MAX_ATTEMPTS` (5 in
`FLUX_RESTART_WINDOW` 3600 s, then exit 42), `SKIP_UPDATE`, `FLUX_OFFLINE` (local tests: an offline
cluster, no token needed).

Always set, whatever the files say: `console_enabled = true` (the image's saves, status and
lists go through the console), the shard link on the loopback, the ports, and a cluster key of the
server's own (the previous image gave every server the same one).

## For the hub

Commands, run through appexec. Each prints one JSON document.

| Command | |
|---|---|
| `flux-dst status` | `state` (from `flux/state.json`: `updating`, `starting`, `running`, `token_missing`, `token_refused`, `restarting`, `crashed`, `stopped`) and its `message`, `players` (`name`, `userid` KU_, `prefab`, `age` in days, `admin`, `shard` Master/Caves), `world` (`day`, `season`, `phase`, `seasondays`), `max_players`, `name` |
| `flux-dst world` | the play style and the owner's overrides, the play styles' own overrides, and `catalog`: every world option of this game build as the Host Game screen has it (name, label, group, values with their text, default), for the forest and the caves, world generation and settings apart |
| `flux-dst set-world '<json>'` | `{"playstyle": "relaxed", "forest": {"hounds": "often"}, "cave": {...}}` into `flux/world.json`; checked against the catalog. Applied on the next start: settings reach the existing world, generation options only a new one |
| `flux-dst mods` | the mods (`id`, `enabled`, `options`), the collection, and `installed`: each downloaded mod's name, version, author, description, `client_only` (players install it themselves: enabling it on a server does nothing), `all_clients_require`, and its `configuration_options` |
| `flux-dst set-mods '<json>'` | `{"mods": [{"id": "378160973", "enabled": true, "options": {"SHOWPLAYERSOPTIONS": 3}}], "collection": ""}` into `flux/mods.json`. Applied on the next start |
| `flux-console [--caves] <lua>` | one line of Lua into a shard's console, and what it printed. A bare word gets `()`: `flux-console c_save` |

`flux/world.json` and `flux/mods.json` are the hub's: while one exists the image writes
`worldgenoverride.lua` / `modoverrides.lua` from it on every start. Delete it to manage the Lua
file by hand. `flux/mods-installed.json` and `flux/world-options.json` are refreshed after every
start (the options only when the game build changed).

Useful console commands: `c_announce("text")`, `c_save()`, `c_rollback(1)` (back one save, up to
`max_snapshots`), `c_regenerateworld()` (a new world, both shards), `c_listallplayers()`,
`TheNet:Kick("KU_...")`, `TheNet:Ban("KU_...")`.

## Measured (build 756039, 2026-10-10)

- Master + Caves on a fresh world: **about 2.2 GiB together** (Master 1.3 GB, Caves 1.0 GB of
  anonymous memory), steady with the world running and one mod, ~0.4 core with nobody on. A
  plan under 3 GB cannot run the caves.
- First start of a new world: ~25 s for both shards (after the 4.3 GB download).
- The console is plain stdin (no terminal needed), and the answer is in the shard's
  `server_log.txt` at once. `print()` cuts a line at 4 KB; `io` is not available to it.
- **SIGTERM saves and logs "Shutting down", then the process waits for ONE MORE console line
  before it ends.** The supervisor keeps feeding newlines after the signal. `docker stop`: 3.8 s.
- No token / a refused one: `Account Failed (6): "E_INVALID_TOKEN"`, "Your Server Will Not Start",
  and the process hangs instead of exiting.
- `worldgenoverride.lua` is read on every start and the game writes it back after each save
  (with a `KLEI     1 ` header). Changed settings reach an existing world (hounds never -> often).
- A caves shard with no override file generates a second forest: the caves always get
  `DST_CAVE`.
- A world made without caves has its 10 sinkholes (plugged): caves can be turned on later.
- Mods download at start into `ugc_mods/<cluster>/<shard>/`, per shard. Installed versions are
  in `appworkshop_322330.acf` (`timeupdated`), compared against Steam's public
  GetPublishedFileDetails.
- The game's `json.encode` escapes `'` as `\'`, which JSON does not allow.
- Steam's UpToDateCheck is useless for DST (an older version is "up to date"): updates are found
  by comparing SteamCMD's public build id with the installed one.
- SteamCMD needs `+@sSteamCmdForcePlatformType linux` for an anonymous install of 343050, or it
  fails with "Missing configuration".

## Development

```bash
./tests/test-flux.sh                          # unit tests: flux-lib.sh and fluxdst.py
docker build -t dst-server-flux:local .
./tests/test-image.sh                         # the real supervisor in the image, stand-in Steam and server
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A real run, offline (no token needed):

```bash
docker run --rm -e FLUX_OFFLINE=true -v dst-install:/mnt/dst/server -v dst-data:/mnt/dst/data dst-server-flux:local
```

## Versions

- **1.0.0** (2026-10-10): first version.
