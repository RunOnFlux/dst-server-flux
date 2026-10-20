#!/bin/bash
# Shared helpers for the Don't Starve Together image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Two volumes: the install (SteamCMD's, disposable, local to the node: about 4.3 GB, and
# the Workshop mods under ugc_mods/) and the data, which is the server's persistent storage root:
# the cluster (settings, both worlds, the player lists) and our own files in flux/.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/dst/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/dst/data}"
# The cluster's folder under the data volume. FIXED, never the server's name: the previous image
# named the folder after CLUSTER_NAME, so renaming the server started a new, empty world.
FLUX_CLUSTER="${FLUX_CLUSTER:-Cluster_1}"
FLUX_DIR="${FLUX_DIR:-${FLUX_DATA_DIR}/flux}"
# flux.log is on a LOCAL volume, never a synced one: it is written on every line, and on a synced
# volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# What the hub reads: the state of the server (starting, updating, running, token problems).
FLUX_STATE_FILE="${FLUX_STATE_FILE:-${FLUX_DIR}/state.json}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_DIR}/backups}"
FLUX_GAME_BIN="${FLUX_GAME_BIN:-dontstarve_dedicated_server_nullrenderer_x64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-343050}"
# Steam's app for the GAME (the Workshop's app id), not the dedicated server's.
FLUX_WORKSHOP_APP="${FLUX_WORKSHOP_APP:-322330}"
# Each shard's console is its stdin: a FIFO the supervisor holds open and the server reads.
FLUX_CONSOLE_DIR="${FLUX_CONSOLE_DIR:-/tmp}"
FLUX_CONSOLE_LOCK="${FLUX_CONSOLE_LOCK:-/tmp/flux-console.lock}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Inputs.
# ---------------------------------------------------------------------------------------------

# $1 = a port as given. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# $1 = DST_CAVES as given. Caves are ON unless it says otherwise: they are half of the game.
flux_caves_enabled() {
  [ -z "$1" ] && return 0
  flux_truthy "$1"
}

# $1 = the cluster token. A Klei token is one line with no spaces ("pds-g^KU_xxxx^1^...").
# Returns 1 for anything that cannot be one, so a pasted sentence or two tokens never reach the
# file the server reads.
flux_valid_token() {
  local t="$1"
  [ "${#t}" -ge 20 ] && [ "${#t}" -le 512 ] || return 1
  [[ "${t}" =~ ^[!-~]+$ ]]
}

# $1 = a token. Prints a short fingerprint, so a refusal can be remembered without the token.
flux_token_fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

# $1 = a line of a shard's log. Prints the Klei account error when the server says it will not
# start (measured with no token and with a made-up one: `[200] Account Failed (6):
# "E_INVALID_TOKEN"`, then "!!!! Your Server Will Not Start !!!!" and the process HANGS, it does
# not exit). Returns 1 for any other line.
flux_token_error() {
  [[ "$1" =~ Account\ Failed\ \([0-9]+\):\ \"(E_[A-Z_]+)\" ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# $1 = an E_ code from flux_token_error. True when it is the TOKEN that is wrong (the owner has to
# make a new one), false for a code that may only mean Klei's servers had a bad moment.
flux_token_refused() {
  case "$1" in
    E_INVALID_TOKEN | E_EXPIRED_TOKEN | E_TOKEN* | E_BANNED*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The restart budget: a server that keeps dying is not fixed by restarting it here forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. Planned and requested ones (an update, the owner's restart)
# are the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Updates.
# ---------------------------------------------------------------------------------------------

# Reads `steamcmd +app_info_print` output on stdin; prints the public branch's build id.
flux_public_buildid() {
  awk '
    /"branches"/ { inb = 1 }
    inb && /"public"/ { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# $1 = the install's appmanifest. Prints the installed build id.
flux_installed_buildid() {
  [ -f "$1" ] || return 0
  awk '/"buildid"/ { gsub(/"/, "", $2); print $2; exit }' "$1"
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

flux_cluster_dir() {
  printf '%s' "${FLUX_DATA_DIR}/${FLUX_CLUSTER}"
}

# $1 = Master or Caves. The shard's own log, which the server rewrites on every start and where
# the answers to console commands land (at once: measured).
flux_shard_log() {
  printf '%s' "$(flux_cluster_dir)/$1/server_log.txt"
}

flux_console_fifo() {
  printf '%s' "${FLUX_CONSOLE_DIR}/flux-console-${1,,}"
}

# $1 = Master or Caves. The pid of that shard's server, or nothing. Anchored on the binary: a
# pattern like "-shard Master" alone also matches any shell whose command line mentions it.
flux_shard_pid() {
  pgrep -f "^\./${FLUX_GAME_BIN} .*-shard $1( |\$)" 2>/dev/null | head -1
}

# $1 = a console command as given. One line with no control characters: the console takes one
# line of Lua per command.
flux_console_line() {
  local cmd="${1//[$'\r\n']/ }"
  printf '%s' "${cmd}" | LC_ALL=C tr -d '\000-\037\177'
}

# $1 = Master or Caves, $2 = one line of Lua. Written into the shard's stdin; returns 1 when that
# shard is not running, without blocking.
flux_console() {
  local fifo cmd
  fifo="$(flux_console_fifo "$1")"
  [ -p "${fifo}" ] || return 1
  [ -n "$(flux_shard_pid "$1")" ] || return 1
  cmd="$(flux_console_line "$2")"
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  timeout 2 bash -c 'printf "%s\n" "$1" >"$2"' _ "${cmd}" "${fifo}"
}
