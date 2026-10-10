#!/bin/bash
# flux-console [--caves] <lua...>: types one line into a shard's console (the surface by default)
# and prints what the server wrote in the next moments.
#
#   flux-console 'c_announce("Hello")'
#   flux-console c_listallplayers
#   flux-console --caves 'c_save()'
#
# DST's console takes Lua. A bare word gets "()" added, so `c_save` and `c_listallplayers` work as
# typed. The answer is read back from the shard's own log (Cluster_1/<shard>/server_log.txt),
# where it lands at once (measured): the lines written after the command, without the server's
# echo of the command itself. It waits for the log to grow, up to FLUX_CONSOLE_WAIT seconds
# (default 2), and then a little more for the rest of the answer.
#
# ONE AT A TIME, under a lock shared with flux-dst, so two answers never mix. Exit 1 when the
# shard is not running, 64 without a command, 75 when the console stayed busy.
set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source /opt/flux/flux-lib.sh

shard=Master
if [ "${1:-}" = "--caves" ]; then
  shard=Caves
  shift
fi
[ $# -gt 0 ] || { echo "usage: flux-console [--caves] <lua...>" >&2; exit 64; }
cmd="$*"
[[ "${cmd}" =~ ^[A-Za-z_][A-Za-z0-9_.:]*$ ]] && cmd="${cmd}()"

exec 9>"${FLUX_CONSOLE_LOCK}"
if ! flock -w "${FLUX_CONSOLE_LOCK_WAIT:-15}" 9; then
  echo "the console is busy with another command; try again" >&2
  exit 75
fi

log="$(flux_shard_log "${shard}")"
before=0
[ -f "${log}" ] && before="$(wc -c <"${log}")"

if ! flux_console "${shard}" "${cmd}"; then
  echo "no server is running (${shard})" >&2
  exit 1
fi

waited=0
limit=$(( ${FLUX_CONSOLE_WAIT:-2} * 10 ))
while [ "${waited}" -lt "${limit}" ]; do
  sleep 0.1
  waited=$((waited + 1))
  if [ -f "${log}" ] && [ "$(wc -c <"${log}")" -gt "$((before + 0))" ]; then
    # The echo comes first; give the answer itself a moment.
    sleep 0.4
    [ "$(grep -c -v 'RemoteCommandInput' < <(tail -c +$((before + 1)) "${log}"))" -gt 0 ] && break
  fi
done
[ -f "${log}" ] && tail -c +$((before + 1)) "${log}" | grep -v 'RemoteCommandInput: '
exit 0
