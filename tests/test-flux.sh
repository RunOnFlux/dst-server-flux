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

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf 'lib: %s passed, %s failed\n' "${pass}" "${fail}"

# --- fluxdst.py --------------------------------------------------------------------------------
python3 -m unittest -q tests/test_fluxdst.py 2>&1 | tail -n 5
py=${PIPESTATUS[0]}

[ "${fail}" = "0" ] && [ "${py}" = "0" ]
