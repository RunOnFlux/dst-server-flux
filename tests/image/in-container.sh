#!/bin/bash
# wait_for evals its first argument later: the single quotes are on purpose throughout.
# shellcheck disable=SC2016
# Runs INSIDE the image (tests/test-image.sh). The repository is mounted read-only at /repo.
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
# Waits up to $2 seconds for the command in $1 to succeed.
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 lua5.1 pgrep pkill mkfifo timeout sha256sum tail tee sed flock tar; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-dst is on the PATH" "0" "$(status command -v flux-dst)"
check "flux-dst starts (usage)" "64" "$(status flux-dst)"
check "the server's one missing library is installed" "0" "$(status bash -c 'ldconfig -p | grep -q libcurl-gnutls.so.4')"
for script in flux-entrypoint.sh flux-console.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done

# --- The unit tests, with the image's Python and Lua (the Lua ones are skipped elsewhere) -------
(cd /repo && FLUX_LUA_HELPER=/opt/flux/flux-lua.lua python3 -m unittest -q tests/test_fluxdst.py) >/tmp/unit.out 2>&1
check "the unit tests pass with the image's Python and Lua" "0" "$?"
check "and the Lua ones ran" "0" "$(status grep -vq skipped /tmp/unit.out)"
grep -q FAIL /tmp/unit.out && cat /tmp/unit.out

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd "installs" a server that behaves like DST where it matters (all measured on build
# 756039): its console is stdin, its answers go to <cluster>/<shard>/server_log.txt, which it
# rewrites on start; without a token it logs Klei's refusal and HANGS; on SIGTERM it saves and
# logs "Shutting down", and then waits for one more console line before it exits.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir="" info=0
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  [ "$1" = "+app_info_print" ] && info=1
  shift
done
build="$(cat /tmp/fake-latest-build 2>/dev/null || echo 100)"
if [ "${info}" = "1" ]; then
  printf '"343050"\n{\n"depots"\n{\n"branches"\n{\n"public"\n{\n"buildid"\t\t"%s"\n}\n}\n}\n}\n' "${build}"
  exit 0
fi
[ -n "${dir}" ] || exit 0
# /tmp/fake-0x6: Steam refuses the installed build's old manifests while its record (the acf) exists
if [ -e /tmp/fake-0x6 ] && [ -f "${dir}/steamapps/appmanifest_343050.acf" ]; then
  echo "Error! App '343050' state is 0x6 after update job."
  exit "$(cat /tmp/fake-0x6)"
fi
echo "steamcmd: starting"
if [ -e /tmp/fake-fail-once ]; then rm -f /tmp/fake-fail-once; echo "steamcmd: failing once"; exit 1; fi
[ -e /tmp/fake-slow ] && sleep 30
echo "steamcmd: installing build ${build}"
mkdir -p "${dir}/bin64" "${dir}/steamapps" "${dir}/mods"
echo 756039 >"${dir}/version.txt"
printf '"AppState"\n{\n"buildid"\t\t"%s"\n}\n' "${build}" >"${dir}/steamapps/appmanifest_343050.acf"
cat >"${dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64" <<'GAME'
#!/bin/bash
# Under the real binary's name, as the supervisor and flux-dst find the shards by it.
if [ -z "${FAKE_REEXEC:-}" ]; then
  FAKE_REEXEC=1 exec -a ./dontstarve_dedicated_server_nullrenderer_x64 bash "$0" "$@"
fi
root="" cluster="" shard=""
while [ $# -gt 0 ]; do
  case "$1" in
    -persistent_storage_root) root="$2"; shift ;;
    -cluster) cluster="$2"; shift ;;
    -shard) shard="$2"; shift ;;
  esac
  shift
done
dir="${root}/./${cluster}/${shard}"
mkdir -p "${dir}/save"
log="${dir}/server_log.txt"
: >"${log}"
say() { printf '[00:00:01]: %s\t\n' "$*" | tee -a "${log}"; }
say "PersistRootStorage is now ${dir}/"
term=0
trap 'term=1; say "Saving Dedicated server data..."; date >"${dir}/save/session"; say "Shutting down"' TERM
if ! grep -q 'offline_cluster = true' "${root}/${cluster}/cluster.ini" && \
   ! grep -q '^pds-' "${root}/${cluster}/cluster_token.txt" 2>/dev/null; then
  say '[200] Account Failed (6): "E_INVALID_TOKEN"'
  say '!!!! Your Server Will Not Start !!!!'
fi
[ "${shard}" = "Master" ] && say "[Shard] Starting master server"
date >"${dir}/save/session"
while true; do
  IFS= read -r line
  rc=$?
  [ "${rc}" -gt 128 ] && continue
  [ "${rc}" != "0" ] && { sleep 0.1; continue; }
  [ "${term}" = "1" ] && exit 0
  say "RemoteCommandInput: \"${line}\""
  n="$(sed -n 's/^local n="\([0-9a-f]*\)".*/\1/p' <<<"${line}")"
  case "${line}" in
    *'"..n.." R"'*) say "FLUX ${n} R"; say "FLUX ${n} END" ;;
    *GetClientTable*)
      [ "${shard}" = "Master" ] && say "FLUX ${n} P {\"name\":\"Wilson\\'s friend\",\"userid\":\"KU_test1234\",\"prefab\":\"wilson\",\"age\":3,\"admin\":false}"
      [ "${shard}" = "Caves" ] && say "FLUX ${n} H KU_test1234"
      say "FLUX ${n} W {\"day\":4,\"season\":\"autumn\",\"phase\":\"dusk\",\"cave\":$([ "${shard}" = Caves ] && echo true || echo false)}"
      say "FLUX ${n} END" ;;
    *flux-world-options.json*)
      printf 'KLEI     1 {"build":"756039","forest":{"settings":[{"name":"hounds","label":"Hound Attacks","options":[{"data":"never","text":"None"},{"data":"often","text":"More"}],"default":"default"}],"worldgen":[]},"cave":{"settings":[],"worldgen":[]}}' >"${dir}/flux-world-options.json"
      say "FLUX ${line##*FLUX } " | sed 's/") end)$//' >/dev/null
      say "FLUX $(sed -n 's/.*print("FLUX \([0-9a-f]*\) END").*/\1/p' <<<"${line}") END" ;;
    c_save*) say "Serializing world: session/X/0000000002" ;;
    *) say "answer to: ${line}" ;;
  esac
done
GAME
chmod +x "${dir}/bin64/dontstarve_dedicated_server_nullrenderer_x64"
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_SERVER_DIR=/tmp/t/server FLUX_DATA_DIR=/tmp/t/data FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_SECONDS=0
d="${FLUX_DATA_DIR}"
start() { /opt/flux/flux-entrypoint.sh >/tmp/entry.out 2>&1 & entry=$!; }
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "${d}/flux/state.json" 2>/dev/null; }
gpid() { pgrep -f "^\./dontstarve_dedicated_server_nullrenderer_x64 .*-shard $1( |\$)"; }

# 1. A cluster comes up, answers the hub, and saves on stop.
rm -rf /tmp/t
FLUX_OFFLINE=true DST_NAME="Test" DST_PLAYSTYLE=relaxed start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 30
check "both shards start" "2" "$(pgrep -fc '^\./dontstarve_dedicated_server_nullrenderer_x64')"
check "state running" "running" "$(state)"
wait_for 'grep -q "installed mods" /tmp/entry.out' 10
check "the world options were written for the hub" "Hound Attacks" "$(json 'd["forest"]["settings"][0]["label"]' <"${d}/flux/world-options.json")"
st="$(flux-dst status)"
check "status: the player, with the apostrophe" "Wilson's friend" "$(json 'd["players"][0]["name"]' <<<"${st}")"
check "status: the player is in the caves" "Caves" "$(json 'd["players"][0]["shard"]' <<<"${st}")"
check "status: the day" "4" "$(json 'd["world"]["day"]' <<<"${st}")"
check "status: both shards answered" "True True" "$(json 'd["shards"]["Master"]["answered"], d["shards"]["Caves"]["answered"]' <<<"${st}" | tr -d '(),')"
check "console: a bare word becomes a call" "answer to: c_listallplayers()" "$(flux-console c_listallplayers | sed 's/^\[[^]]*\]: //; s/\t$//')"
check "console: the caves" "answer to: print(1)" "$(flux-console --caves 'print(1)' | sed 's/^\[[^]]*\]: //; s/\t$//')"
check "console: the echo is left out" "1" "$(status grep -q RemoteCommandInput < <(flux-console 'print(2)'))"
check "the shards' output is in the container's, labelled" "0" "$(status grep -q '^\[Caves\] ' /tmp/entry.out)"

# 2. A shard that dies takes the cluster with it, and the cluster comes back in place.
kill -KILL "$(gpid Caves)"
wait_for 'grep -q "generation 2" /tmp/entry.out' 20
wait_for '[ "$(pgrep -fc "^\./dontstarve_dedicated_server_nullrenderer_x64")" = "2" ]' 20
check "a dead shard restarts the cluster" "0" "$(status grep -q 'Caves ended on its own' /tmp/entry.out)"
check "both shards are back" "2" "$(pgrep -fc '^\./dontstarve_dedicated_server_nullrenderer_x64')"

# 3. Stop: both shards save, the newline after "Shutting down" lets them end, inside Docker's 10 s.
wait_for 'grep -c "the cluster is up" /tmp/entry.out | grep -q 2' 20
t0="$(date +%s)"
kill -TERM "${entry}"
wait "${entry}"
rc=$?
check "a stop ends the container with 0" "0" "${rc}"
check "inside Docker's ten seconds" "0" "$(status test $(($(date +%s) - t0)) -lt 10)"
check "both shards saved" "2" "$(grep -c 'Saving Dedicated server data' /tmp/entry.out | tail -1 | awk '{print ($1 >= 2) ? 2 : $1}')"
check "no shard is left" "1" "$(status pgrep -f '^\./dontstarve_dedicated_server_nullrenderer_x64')"
check "state stopped" "stopped" "$(state)"
check "a backup was made at start" "0" "$(status ls "${d}"/flux/backups/*-Cluster_1.tar.gz)"

# 4. No token: nothing starts, the reason is in the state, and a stop is immediate.
rm -rf /tmp/t
start
wait_for '[ "$(state)" = "token_missing" ]' 20
check "no token: state" "token_missing" "$(state)"
check "no token: no shard" "1" "$(status pgrep -f '^\./dontstarve_dedicated_server_nullrenderer_x64')"
kill -TERM "${entry}"; wait "${entry}"
check "no token: a stop ends it with 0" "0" "$?"

# 5. A token Klei refuses: the hanging server is stopped, the reason is in the state.
rm -rf /tmp/t
DST_CLUSTER_TOKEN='kfake-not-a-pds-token-1234567890' start
wait_for '[ "$(state)" = "token_refused" ]' 20
check "refused token: state" "token_refused" "$(state)"
wait_for '! pgrep -f "^\./dontstarve_dedicated_server_nullrenderer_x64" >/dev/null' 15
check "refused token: the hanging shards are stopped" "1" "$(status pgrep -f '^\./dontstarve_dedicated_server_nullrenderer_x64')"
check "refused token: the token itself is never logged" "1" "$(status grep -q kfake-not /tmp/entry.out)"
kill -TERM "${entry}"; wait "${entry}"

# 6. A newer build on Steam with nobody online... the stand-in always has a player, so this is
#    the grace path with no grace: a planned restart, which updates.
rm -rf /tmp/t
echo 100 >/tmp/fake-latest-build
FLUX_OFFLINE=true FLUX_UPDATE_CHECK_SECONDS=3 FLUX_UPDATE_GRACE_MINUTES=0 start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 30
echo 101 >/tmp/fake-latest-build
wait_for 'grep -q "generation 2" /tmp/entry.out' 30
check "an update restarts the cluster" "0" "$(status grep -q 'planned: a game update (build 100 -> 101)' /tmp/entry.out)"
check "and installs the new build" "0" "$(status grep -q 'installing build 101' /tmp/entry.out)"
check "a planned restart is not a crash" "1" "$(status grep -q 'restarts within' /tmp/entry.out)"
kill -TERM "${entry}"; wait "${entry}"

check "no FLUX_RESTART_TIME: no scheduled restart" "1" "$(status grep -q 'scheduled restart' /tmp/entry.out)"

# 7. A scheduled restart: due within the next two minutes, warned a minute before, a planned
#    restart (not a crash) that saves and comes back in place.
rm -rf /tmp/t
echo 100 >/tmp/fake-latest-build
at="$(date -d '+1 minute' +%H:%M)"
FLUX_OFFLINE=true FLUX_RESTART_TIME="${at}" FLUX_RESTART_WARN_MINUTES=1 start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 30
wait_for 'grep -q "generation 2" /tmp/entry.out' 150
check "the scheduler announces itself" "0" "$(status grep -q "scheduled restart at ${at}" /tmp/entry.out)"
check "players are warned" "0" "$(status grep -q 'players warned: restart in' /tmp/entry.out)"
check "the restart is planned" "0" "$(status grep -q "planned: scheduled restart at ${at}" /tmp/entry.out)"
check "a scheduled restart is not a crash" "1" "$(status grep -q 'restarts within' /tmp/entry.out)"
wait_for 'grep -c "the cluster is up" /tmp/entry.out | grep -q 2' 30
check "both shards are back" "2" "$(pgrep -fc '^\./dontstarve_dedicated_server_nullrenderer_x64')"
kill -TERM "${entry}"; wait "${entry}"

# 5. Steam refuses the installed build's manifests (0x6): the record is set aside, the install runs as a new
# one, the server starts, and the depotcache lives on the install volume.
rm -rf /tmp/t
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -c "the cluster is up" /tmp/entry.out | grep -q 1' 30
kill -TERM "${entry}"; wait "${entry}"
echo 8 >/tmp/fake-0x6
echo 101 >/tmp/fake-latest-build
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 40
check "0x6 is answered with a fresh install, once" "1" "$(grep -c 'updating as a new install' /tmp/entry.out)"
check "the server came up on the new build" "101" "$(sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "${FLUX_SERVER_DIR}/steamapps/appmanifest_343050.acf" | head -1)"
check "the old record is not left behind" "1" "$(status test -e "${FLUX_SERVER_DIR}/steamapps/appmanifest_343050.acf.pre-fresh")"
check "the depotcache is on the install volume" "${FLUX_SERVER_DIR}/flux-steam/depotcache" "$(readlink "${HOME:-/root}/.local/share/Steam/depotcache")"
kill -TERM "${entry}"; wait "${entry}"
# the same, when SteamCMD prints the 0x6 line but exits 0 (the old build's binary is there: it must not start)
rm -rf /tmp/t
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -c "the cluster is up" /tmp/entry.out | grep -q 1' 30
kill -TERM "${entry}"; wait "${entry}"
echo 0 >/tmp/fake-0x6
echo 102 >/tmp/fake-latest-build
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 40
check "0x6 with exit 0 is answered with a fresh install too" "1" "$(grep -c 'updating as a new install' /tmp/entry.out)"
check "and the server came up on the newest build" "102" "$(sed -n 's/.*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "${FLUX_SERVER_DIR}/steamapps/appmanifest_343050.acf" | head -1)"
kill -TERM "${entry}"; wait "${entry}"
rm -f /tmp/fake-0x6 /tmp/fake-latest-build

# 6. A stop in the middle of the update is a clean stop (exit 0), not a failed preparation (42), and the
# SteamCMD output reaches the container's output while it runs.
rm -rf /tmp/t
touch /tmp/fake-slow
FLUX_OFFLINE=true DST_NAME="Test" start
sleep 3
# SteamCMD is still sleeping here: its first line must already be in the container's output (live, not at the end)
check "SteamCMD's output reaches the container's output while it is still running" "0" "$(status grep -q 'steamcmd: starting' /tmp/entry.out)"
kill -TERM "${entry}"
wait "${entry}"
rc=$?
check "a stop during the update ends the container with 0" "0" "${rc}"
check "and is logged as a stop, not as an error" "0" "$(status grep -q 'stopped on request before the server started' /tmp/entry.out)"
check "the container did not end with 42" "1" "$(status grep -q 'ending the container (42)' /tmp/entry.out)"
rm -f /tmp/fake-slow
pkill -f "sleep 30" 2>/dev/null
# a stop during the pause between two attempts must not start another SteamCMD run
rm -rf /tmp/t
touch /tmp/fake-fail-once /tmp/fake-slow
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -q "retrying in 5s" /tmp/entry.out' 20
t0="$(date +%s)"
kill -TERM "${entry}"
wait "${entry}"
check "a stop between two attempts ends the container with 0" "0" "$?"
check "quickly, without a second SteamCMD run" "0" "$(status test $(($(date +%s) - t0)) -lt 4)"
check "(one 'steamcmd: starting' in the output)" "1" "$(grep -c 'steamcmd: starting' /tmp/entry.out)"
rm -f /tmp/fake-slow /tmp/fake-fail-once
pkill -f "sleep 30" 2>/dev/null
rm -rf /tmp/t
FLUX_OFFLINE=true DST_NAME="Test" start
wait_for 'grep -q "the cluster is up" /tmp/entry.out' 30
check "SteamCMD's whole output is in the container's output" "0" "$(status grep -q 'steamcmd: installing build' /tmp/entry.out)"
kill -TERM "${entry}"; wait "${entry}"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl="${FLUX_SERVER_DIR}/flux-logs/flux.log"
check "flux.log is on the install volume" "0" "$(status test -s "${fl}")"
check "and not on the synced data volume" "1" "$(status test -e "${d}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q "Don't Starve Together server image by FluxCloud - https://runonflux.com" /tmp/entry.out)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl}")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/entry.out)" -ge 2 ] && echo 1 || echo 0)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo "--- entrypoint output"; tail -40 /tmp/entry.out; }
[ "${fail}" = "0" ]
