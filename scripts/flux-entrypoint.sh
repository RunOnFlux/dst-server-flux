#!/bin/bash
# PID 1, and the supervisor of the Don't Starve Together cluster: the surface (Master) and the
# caves (Caves), two server processes in this one container, linked over the loopback.
#
# The game runs as CHILDREN, never exec, so a stop reaches us first and becomes a save, and a
# cluster that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update, a world from the previous image moved into place, the cluster
#     written from the environment and flux/*.json (fluxdst.py apply), a backup, then both shards,
#     each with its console on a FIFO the supervisor holds open
#   - once the world is up: the hub's lists (the world options of this game build, the installed
#     mods and their settings) and state "running" in flux/state.json
#   - every FLUX_UPDATE_CHECK_MINUTES: a newer game build or Workshop mod means a restart (players
#     are warned first and given FLUX_UPDATE_GRACE_MINUTES): an outdated DST server disappears
#     from the players' server list
#   - SIGTERM/SIGINT from Docker: SIGTERM to both shards, which save and quit (about 2 s, measured)
#   - a shard ending on its own: the other one stopped, a new generation in the same container
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42 (FluxOS starts it again, with a fresh budget)
#   - a Klei token refused (or none): the server is stopped and tried again every
#     FLUX_TOKEN_RETRY_MINUTES, the reason in flux/state.json for the hub to show
#
# Same family as runonflux/unturned-server-flux and 7dtd-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-60}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-5}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
FLUX_UPDATE_GRACE_MINUTES="${FLUX_UPDATE_GRACE_MINUTES:-5}"
FLUX_TOKEN_RETRY_MINUTES="${FLUX_TOKEN_RETRY_MINUTES:-15}"
FLUX_READY_TIMEOUT="${FLUX_READY_TIMEOUT:-1800}"
PY=(python3 /opt/flux/fluxdst.py)

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
c="$(flux_cluster_dir)"

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "${FLUX_DIR}"

caves=0
flux_caves_enabled "${DST_CAVES:-}" && caves=1
shards=(Master)
[ "${caves}" = "1" ] && shards+=(Caves)

for var in DST_PORT DST_CAVES_PORT DST_STEAM_PORT; do
  if [ -n "${!var:-}" ] && ! flux_valid_port "${!var}" >/dev/null; then
    flux_log "ERROR ${var}='${!var}' is not a port from 1024 to 65535; refusing to start"
    exit 42
  fi
done
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, caves $([ "${caves}" = "1" ] && echo on || echo off), ports ${DST_PORT:-11000}$([ "${caves}" = "1" ] && echo "+${DST_CAVES_PORT:-10999}")/udp)"

declare -A pid=()
helpers=()
terminating=0
stopping=0
generation=0
restart_history=()

# flux/state.json, what the hub shows while the server is not simply running: $1 = state, $2 = a
# sentence for the owner. Written beside, then renamed.
write_state() {
  local build
  build="$(flux_installed_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
  python3 - "$1" "${2:-}" "$(cat "${s}/version.txt" 2>/dev/null)" "${build}" "${caves}" "${FLUX_STATE_FILE}" <<'PY'
import json, os, sys, time
state, message, version, build, caves, path = sys.argv[1:]
data = {"state": state, "message": message or None, "version": version or None, "build": build or None,
        "caves": caves == "1", "since": int(time.time()), "image": os.environ.get("FLUX_IMAGE_VERSION", "dev")}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(data, f)
os.replace(path + ".tmp", path)
PY
}

# SIGTERM to every shard still running: each saves and quits. A shard that has logged "Shutting
# down" then WAITS FOR ONE MORE LINE on its console before the process ends (measured), so
# feed_newlines keeps one coming until it is gone.
stop_shards() {
  local sh
  stopping=1
  for sh in "${shards[@]}"; do
    [ -n "${pid[${sh}]:-}" ] && kill -TERM "${pid[${sh}]}" 2>/dev/null
  done
}

feed_newlines() {
  local sh
  for sh in "${shards[@]}"; do
    if [ -n "${pid[${sh}]:-}" ] && kill -0 "${pid[${sh}]}" 2>/dev/null; then
      # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
      timeout 1 bash -c 'printf "\n" >"$1"' _ "$(flux_console_fifo "${sh}")" 2>/dev/null
    fi
  done
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving the world and shutting down, no restart will follow"
  stop_shards
}
trap term_handler TERM INT

update_server() {
  local attempt validate
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/bin64/${FLUX_GAME_BIN}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  write_state updating "Downloading the latest Don't Starve Together server from Steam (about 4.3 GB the first time)."
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  validate=""
  for attempt in 1 2 3 4 5; do
    # The platform has to be named: without it, an anonymous install of 343050 fails with
    # "Missing configuration" (measured, steamcmd/steamcmd:ubuntu-24).
    # shellcheck disable=SC2086  # validate is "" or "validate"
    if steamcmd +@sSteamCmdForcePlatformType linux +force_install_dir "${s}" +login anonymous \
      +app_update "${FLUX_STEAM_APP}" -beta public ${validate} +quit; then
      [ -x "${s}/bin64/${FLUX_GAME_BIN}" ] && return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    sleep 5
  done
  if [ -x "${s}/bin64/${FLUX_GAME_BIN}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# A .tar.gz of the cluster (both worlds, settings, player lists), without the game's own copies of
# old logs. Skipped when nothing was saved since the last backup, so an idle server does not
# rotate good backups out with identical ones.
backup_world() {
  local why="$1" out name newest
  [ "${FLUX_BACKUP_KEEP}" -gt 0 ] 2>/dev/null || return 0
  [ -d "${c}/Master/save" ] || return 0
  mkdir -p "${FLUX_BACKUP_DIR}"
  # shellcheck disable=SC2012  # our own names, no spaces
  newest="$(ls -t "${FLUX_BACKUP_DIR}"/*-"${FLUX_CLUSTER}".tar.gz 2>/dev/null | head -1)"
  if [ -n "${newest}" ] && [ -z "$(find "${c}" -path '*/save/*' -newer "${newest}" -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  name="$(date -u +%Y%m%d-%H%M%S)-${FLUX_CLUSTER}.tar.gz"
  out="${FLUX_BACKUP_DIR}/${name}"
  if tar -C "${d}" --exclude="${FLUX_CLUSTER}/*/backup" -czf "${out}.part" "${FLUX_CLUSTER}" 2>/dev/null \
    && mv "${out}.part" "${out}"; then
    flux_log "backup (${why}): flux/backups/${name}, $(du -h "${out}" | cut -f1)"
  else
    rm -f "${out}.part"
    flux_log "WARN backup (${why}) failed"
  fi
  flux_prune "${FLUX_BACKUP_DIR}" "*-${FLUX_CLUSTER}.tar.gz" "${FLUX_BACKUP_KEEP}"
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  local sh
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    for sh in "${shards[@]}"; do flux_console "${sh}" "c_save()" >/dev/null 2>&1; done
    sleep 10
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

# shellcheck disable=SC2329  # run in the background below
# Waits for each shard's world to load (a console probe that only answers once TheWorld exists),
# then refreshes what the hub reads: the world options of this build and the installed mods.
ready_watch() {
  local started sh build have
  started="$(date +%s)"
  for sh in "${shards[@]}"; do
    until "${PY[@]}" probe "${sh}" >/dev/null 2>&1; do
      if [ $(($(date +%s) - started)) -gt "${FLUX_READY_TIMEOUT}" ]; then
        flux_log "WARN ${sh} has not loaded its world after ${FLUX_READY_TIMEOUT}s"
        exit 0
      fi
      sleep 3
    done
  done
  flux_log "the cluster is up: ${shards[*]} loaded in $(($(date +%s) - started))s"
  write_state running ""
  build="$(cat "${s}/version.txt" 2>/dev/null)"
  have="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("build",""))' "${FLUX_DIR}/world-options.json" 2>/dev/null)"
  if [ -n "${build}" ] && [ "${have}" != "${build}" ]; then
    "${PY[@]}" catalog 2>&1 | while IFS= read -r line; do flux_log "${line}"; done
  fi
  "${PY[@]}" installed 2>&1 | while IFS= read -r line; do flux_log "${line}"; done
}

# shellcheck disable=SC2329  # run in the background below
# The surface shard's log, watched for Klei refusing the cluster token: the server prints "Your
# Server Will Not Start" and then hangs, so the supervisor has to end it.
token_watch() {
  local line code
  while IFS= read -r line; do
    [[ "${line}" == *"[Shard] Starting master server"* ]] && exit 0
    if code="$(flux_token_error "${line}")"; then
      if flux_token_refused "${code}"; then
        printf 'token refused: Klei answered %s\n' "${code}" >"${FLUX_RESTART_MARKER}"
        write_state token_refused "Klei refused the cluster token (${code}). Make a new one at accounts.klei.com > Games > Game Servers and paste it into the server's settings."
      else
        printf 'token check failed: Klei answered %s\n' "${code}" >"${FLUX_RESTART_MARKER}"
        write_state token_error "Klei's account service answered ${code}; trying again in ${FLUX_TOKEN_RETRY_MINUTES} minutes."
      fi
      flux_log "ERROR Klei did not accept the cluster token (${code}): the server cannot start"
      exit 0
    fi
  done < <(tail -n +1 -F "$(flux_shard_log Master)" 2>/dev/null)
}

players_online() {
  "${PY[@]}" status 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("players") or []))' 2>/dev/null || echo 0
}

announce() {
  local msg="${1//\"/\'}"
  flux_console Master "c_announce(\"${msg}\")" >/dev/null 2>&1
}

# shellcheck disable=SC2329  # run in the background below
# A newer game build, or a newer version of an installed Workshop mod: players cannot join a
# server that is behind (the game: "server outdated", the server is hidden; a mod: a version
# mismatch on join). The restart updates both.
update_watch() {
  local latest installed stale why n left
  local every="${FLUX_UPDATE_CHECK_SECONDS:-$((FLUX_UPDATE_CHECK_MINUTES * 60))}"
  [ "${every}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep "${every}"
    why=""
    latest="$(steamcmd +@sSteamCmdForcePlatformType linux +login anonymous +app_info_update 1 \
      +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_buildid)"
    installed="$(flux_installed_buildid "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
    if [ -n "${latest}" ] && [ -n "${installed}" ] && [ "${latest}" != "${installed}" ]; then
      why="a game update (build ${installed} -> ${latest})"
    else
      stale="$("${PY[@]}" stale-mods 2>/dev/null)"
      [ -n "${stale}" ] && why="a mod update (${stale})"
    fi
    [ -n "${why}" ] || continue
    n="$(players_online)"
    if [ "${n}" -gt 0 ] 2>/dev/null; then
      flux_log "${why}: ${n} player(s) online, restarting in ${FLUX_UPDATE_GRACE_MINUTES} min"
      left="${FLUX_UPDATE_GRACE_MINUTES}"
      while [ "${left}" -gt 0 ]; do
        announce "Server restarting in ${left} minute(s) for an update. The world is saved."
        if [ "${left}" -gt 1 ]; then sleep 60; left=$((left - 1)); else sleep 50; left=0; fi
        [ "$(players_online)" = "0" ] && break
      done
      announce "Restarting now for an update. See you in a minute!"
      sleep 5
    else
      flux_log "${why}: nobody online, restarting now"
    fi
    printf 'planned: %s\n' "${why}" >"${FLUX_RESTART_MARKER}"
    exit 0
  done
}

start_shard() {
  local sh="$1" fifo
  fifo="$(flux_console_fifo "${sh}")"
  rm -f "${fifo}" "$(flux_shard_log "${sh}")"
  mkfifo -m 600 "${fifo}"
  (
    cd "${s}/bin64" || exit 1
    # The FIFO held open read-write, so the server never sees end-of-file when a writer
    # (flux-console, flux-dst) closes its end.
    exec 3<>"${fifo}"
    exec "./${FLUX_GAME_BIN}" -persistent_storage_root "${d}" -conf_dir . -cluster "${FLUX_CLUSTER}" \
      -shard "${sh}" <&3 > >(exec sed -u "s/^/[${sh}] /") 2>&1
  ) &
  pid[${sh}]=$!
}

start_generation() {
  local rc
  generation=$((generation + 1))
  stopping=0
  rm -f "${FLUX_RESTART_MARKER}"

  update_server || return 1
  [ "${terminating}" = "1" ] && return 2
  "${PY[@]}" migrate 2>&1 | while IFS= read -r line; do flux_log "${line}"; done
  local out
  out="$("${PY[@]}" apply 2>&1)"
  rc=$?
  while IFS= read -r line; do [ -n "${line}" ] && flux_log "${line}"; done <<<"${out}"
  if [ "${rc}" = "3" ]; then
    write_state token_missing "No Klei cluster token. Make one at accounts.klei.com > Games > Game Servers and paste it into the server's settings."
    flux_log "ERROR no cluster token (DST_CLUSTER_TOKEN): Don't Starve Together servers cannot start without one"
    return 3
  elif [ "${rc}" != "0" ]; then
    flux_log "ERROR the cluster could not be written (exit ${rc})"
    return 1
  fi
  backup_world "start"
  [ "${terminating}" = "1" ] && return 2

  write_state starting "The world is loading."
  flux_log "starting the cluster (generation ${generation}): ${shards[*]}"
  for sh in "${shards[@]}"; do start_shard "${sh}"; done
  helpers=()
  token_watch & helpers+=($!)
  ready_watch & helpers+=($!)
  update_watch & helpers+=($!)
  backupper & helpers+=($!)
  return 0
}

sweep_generation() {
  local p sh
  for p in "${helpers[@]}"; do kill "${p}" 2>/dev/null; done
  helpers=()
  pkill -f "tail -n \+1 -F $(flux_shard_log Master)" 2>/dev/null
  for sh in "${shards[@]}"; do
    p="$(flux_shard_pid "${sh}")"
    [ -n "${p}" ] && kill -KILL "${p}" 2>/dev/null
    pid[${sh}]=""
  done
}

# Until a shard ends. A stop or restart that is asked for (a signal, the restart marker) sends
# SIGTERM to both and keeps feeding newlines; one not honoured within FLUX_STOP_GRACE is killed.
# A shard ending on its own stops the other: the cluster restarts as one.
gen_reason=""
wait_for_generation() {
  local asked_at=0 now sh alive
  gen_reason=""
  while true; do
    alive=0
    for sh in "${shards[@]}"; do
      if [ -n "${pid[${sh}]:-}" ] && kill -0 "${pid[${sh}]}" 2>/dev/null; then
        alive=$((alive + 1))
      elif [ "${stopping}" = "0" ] && [ -z "${gen_reason}" ]; then
        wait "${pid[${sh}]}" 2>/dev/null
        gen_reason="${sh} ended on its own (exit $?)"
        flux_log "${gen_reason}: stopping the rest of the cluster"
        stop_shards
      fi
    done
    [ "${alive}" = "0" ] && break
    if [ "${stopping}" = "0" ] && { [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; }; then
      stop_shards
    fi
    if [ "${stopping}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      feed_newlines
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the cluster was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        for sh in "${shards[@]}"; do [ -n "${pid[${sh}]:-}" ] && kill -KILL "${pid[${sh}]}" 2>/dev/null; done
      fi
    fi
    sleep 0.5 &
    wait $!
  done
}

idle_until() {
  local until_ts="$1"
  while [ "$(date +%s)" -lt "${until_ts}" ]; do
    [ "${terminating}" = "1" ] && return 0
    sleep 2 &
    wait $!
  done
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" = "3" ]; then
    idle_until $(($(date +%s) + FLUX_TOKEN_RETRY_MINUTES * 60))
    continue
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation

  reason="${gen_reason}"
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    write_state stopped ""
    flux_log "stopped on request"
    exit 0
  fi
  [ -z "${reason}" ] && reason="the cluster ended on its own"

  if [[ "${reason}" == token* ]]; then
    flux_log "${reason}: trying again in ${FLUX_TOKEN_RETRY_MINUTES} min"
    idle_until $(($(date +%s) + FLUX_TOKEN_RETRY_MINUTES * 60))
    continue
  fi

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      write_state crashed "The server keeps stopping (${reason}). Check the console log."
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  write_state restarting "${reason}"
  flux_log "${reason}: restarting the cluster in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
