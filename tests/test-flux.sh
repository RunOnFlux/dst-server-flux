#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh, and fluxdst.py (tests/test_fluxdst.py). No
# Docker, no Steam, no game. Run from anywhere.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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

# --- Inputs ------------------------------------------------------------------------------------
check "11000 is a port" "11000" "$(flux_valid_port 11000)"
check "a leading zero is not octal" "9999" "$(flux_valid_port 09999)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "caves default on" "0" "$(status flux_caves_enabled '')"
check "caves off" "1" "$(status flux_caves_enabled false)"
check "caves on" "0" "$(status flux_caves_enabled TRUE)"
check "a Klei token is a token" "0" "$(status flux_valid_token 'pds-g^KU_abc12345^1^AbCdEfGhIjKl0123=')"
check "a sentence is not a token" "1" "$(status flux_valid_token 'paste your token here please')"
check "a short word is not a token" "1" "$(status flux_valid_token abc)"
check "the fingerprint is not the token" "1" "$(status test "$(flux_token_fingerprint ABC)" = ABC)"

# --- The Klei token in the log -------------------------------------------------------------------
check "an invalid token is read off the log" "E_INVALID_TOKEN" "$(flux_token_error '[00:00:03]: [200] Account Failed (6): "E_INVALID_TOKEN"')"
check "other lines are not" "1" "$(status flux_token_error '[00:00:01]: Token retrieved from: /x/cluster_token.txt')"
check "an invalid token is a refusal" "0" "$(status flux_token_refused E_INVALID_TOKEN)"
check "an expired token is a refusal" "0" "$(status flux_token_refused E_EXPIRED_TOKEN)"
check "a server error is not a refusal" "1" "$(status flux_token_refused E_SERVER_ERROR)"

# --- Restarts ----------------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a planned restart is not counted" "1" "$(status flux_restart_counts 'planned: a game update (build 1 -> 2)')"
check "a crash is counted" "0" "$(status flux_restart_counts 'Caves ended on its own (exit 139)')"
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"

# --- Updates -----------------------------------------------------------------------------------
info=$'"343050"\n{\n\t"depots"\n\t{\n\t\t"branches"\n\t\t{\n\t\t\t"public"\n\t\t\t{\n\t\t\t\t"buildid"\t\t"25643504"\n\t\t\t\t"timeupdated"\t\t"1791641878"\n\t\t\t}\n\t\t\t"beta"\n\t\t\t{\n\t\t\t\t"buildid"\t\t"99"\n\t\t\t}\n\t\t}\n\t}\n}'
check "the public build id" "25643504" "$(flux_public_buildid <<<"${info}")"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
printf '"AppState"\n{\n\t"appid"\t\t"343050"\n\t"buildid"\t\t"25643504"\n}\n' >"${tmp}/m.acf"
check "the installed build id" "25643504" "$(flux_installed_buildid "${tmp}/m.acf")"
check "no manifest, no build" "" "$(flux_installed_buildid "${tmp}/none.acf")"

# --- The console -------------------------------------------------------------------------------
check "a line break becomes a space" "print(1) print(2)" "$(flux_console_line $'print(1)\nprint(2)')"
check "control characters go" "c_save()" "$(flux_console_line $'c_\x01save()')"
FLUX_DATA_DIR=/d FLUX_CLUSTER=Cluster_1
check "the shard log" "/d/Cluster_1/Caves/server_log.txt" "$(flux_shard_log Caves)"
check "the shard console" "/tmp/flux-console-caves" "$(flux_console_fifo Caves)"

printf 'lib: %s passed, %s failed\n' "${pass}" "${fail}"

# --- fluxdst.py --------------------------------------------------------------------------------
python3 -m unittest -q tests/test_fluxdst.py 2>&1 | tail -n 5
py=${PIPESTATUS[0]}

[ "${fail}" = "0" ] && [ "${py}" = "0" ]
