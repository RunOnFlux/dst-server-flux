# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the Don't Starve Together dedicated server for Flux,
`runonflux/dst-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux server, and a
supervisor in bash. Same family as `~/work/unturned-server-flux` and `~/work/7dtd-server-flux`;
read them for the patterns this one follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. Here the game is TWO processes, the surface (Master) and the
caves (Caves), and they live and die together: one ending stops the other and the cluster restarts
as one.

## Commands

```bash
./tests/test-flux.sh
docker build -t dst-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, migration, `fluxdst.py
  apply`, backup, both shards on their FIFOs, then the watchers (token, ready, updates, backups).
- `scripts/fluxdst.py`: every decision about the server's files (cluster.ini, server.ini, token,
  admins, worldgenoverride.lua, modoverrides.lua, the mods setup file, migration) and the hub's
  commands (`flux-dst status|mods|set-mods|world|set-world`). The one place those rules live.
- `scripts/flux-lua.lua`: reads the game's Lua files (modoverrides, modinfo, worldgenoverride) as
  JSON, in a sandbox with an instruction budget. A Workshop author's modinfo.lua is untrusted.
- `scripts/flux-console.sh`: `flux-console [--caves] <lua>` on the PATH.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.

## Things that will bite you

- **A stopped shard waits for one more console line.** After SIGTERM it saves, logs "Shutting
  down" and blocks reading stdin. One newline sent with the signal is consumed BEFORE the
  shutdown and does nothing: the supervisor keeps sending them until the process is gone.
- **Find a shard by `^\./dontstarve_dedicated_server_nullrenderer_x64 .*-shard <name>`.** A plain
  `-shard Caves` pattern also matches any shell whose command line mentions it (the test's own
  bash got killed that way). The stand-in server in the image test re-execs itself under that name.
- **A caves shard without worldgenoverride.lua or leveldataoverride.lua makes a second forest.**
- **`print()` on the console cuts a line at 4 KB.** Anything big (the world options) is written
  with `TheSim:SetPersistentString("../file", ...)`, which lands in the SHARD's folder with a
  `KLEI     1 ` header. `io` is not available to the console.
- **The game's json.encode writes `\'`**: parse its output with `klei_json`, never `json.loads`.
- **The client table includes the dedicated server itself** (`performance ~= nil`), and it is the
  whole cluster's: which shard a player is in comes from that shard's `AllPlayers`.
- **No token or a bad one: the server hangs, it does not exit.** `token_watch` ends it.
- **Flux stops a container with Docker's default 10 seconds.** Both shards' saves: 3.8 s measured.
- **The unit tests run with the machine's Python and skip the Lua ones without lua5.1.** The image
  test runs them all with the image's Python and Lua.
