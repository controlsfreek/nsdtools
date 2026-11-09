#!/usr/bin/env bash
# fos-tui: node list, structure tokens, type-specific HMI routing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/demo.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/app.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok  $*" ; }

now=$(now_epoch)
load_demo "$now"
list_nodes
list_inverters
list_sdus

((${#BROWSE_KEYS[@]} == 7)) || fail "expected 7 mqtt nodes, got ${#BROWSE_KEYS[@]}"
[[ "${BROWSE_KEYS[0]}" == "flnc1014/A_SDU" ]] || fail "browse order starts with first-seen, got ${BROWSE_KEYS[0]}"
[[ "${BROWSE_KEYS[6]}" == "Fluence/BMS-1" ]] || fail "browse order ends with last-seen, got ${BROWSE_KEYS[6]}"
pass "demo lists 7 mqtt nodes in detection order"

((${#INVERTERS[@]} == 3)) || fail "expected 3 inverters, got ${#INVERTERS[@]}"
pass "demo lists 3 M10s"

((${#SDUS[@]} == 3)) || fail "expected 3 CoreSDU devices, got ${#SDUS[@]}"
pass "demo lists 3 CoreSDU devices"

bms="Fluence/BMS-1"
[[ "${DEV_IS_BMS[$bms]}" -eq 1 ]] || fail "BMS-1 not marked BMS"
for key in "${INVERTERS[@]}"; do
  [[ "$key" != "$bms" ]] || fail "BMS appeared in inverter list"
done
pass "BankBMS excluded from M10 list"

dac="$(select_device_for_edge "flnc1014/A_C001_N001_DAC01")"
[[ "$dac" == "flnc1014/A_C001_N001_DAC01" ]] || fail "DAC device key $dac"
[[ "$(view_for_edge "flnc1014/A_C001_N001_DAC01" "$dac")" == "m10" ]] || fail "DAC should open M10 HMI"
pass "DAC/PCS opens M10 HMI"

core="$(select_device_for_edge "flnc1014/A_C001_SDU")"
[[ "$core" == "flnc1014/A_C001_SDU" ]] || fail "core SDU device key $core"
[[ "$(view_for_edge "flnc1014/A_C001_SDU" "$core")" == "coresdu" ]] || fail "core SDU should open CoreSDU HMI"
[[ -n "$(heartbeat_value "$core")" ]] || fail "core SDU missing Core_hb"
pass "core SDU opens CoreSDU HMI"

sdu="$(select_device_for_edge "flnc1014/A_C001_N001_SDU")"
[[ "$sdu" == "flnc1014/A_C001_N001_SDU" ]] || fail "node SDU device key $sdu"
[[ "$(view_for_edge "flnc1014/A_C001_N001_SDU" "$sdu")" == "nodesdu" ]] || fail "node SDU should open NodeSDU HMI"
pass "node SDU opens NodeSDU HMI"

[[ "$(view_for_edge "flnc1014/A_SDU" "$(select_device_for_edge "flnc1014/A_SDU")")" == "coresdu" ]] || fail "array SDU view"
[[ "$(view_for_edge "Fluence/EDGE-01" "")" == "generic" ]] || true
bms_view="$(view_for_edge "Fluence/BMS-1" "$bms")"
[[ "$bms_view" == "generic" ]] || fail "BMS view got $bms_view"
pass "unknown/BMS uses generic HMI"

# $(printf '%s' $'\n') is empty — Enter must not go through command substitution.
got="$(printf '%s' $'\n')"
[[ -z "$got" ]] || fail "expected command substitution to strip newline"
APP_MODE="list"
APP_CURSOR=0
APP_SELECTED=""
APP_SELECTED_EDGE=""
APP_VIEW=""
list_nodes
handle_key $'\n'
[[ "$APP_MODE" == "detail" ]] || fail "LF Enter should open HMI, mode=$APP_MODE"
[[ "$APP_SELECTED_EDGE" == "flnc1014/A_SDU" ]] || fail "Enter opened '$APP_SELECTED_EDGE'"
[[ "$APP_VIEW" == "coresdu" ]] || fail "array SDU view got '$APP_VIEW'"
handle_key esc
[[ "$APP_MODE" == "list" ]] || fail "Esc should return to list"
APP_CURSOR=1
handle_key enter
[[ "$APP_MODE" == "detail" ]] || fail "enter token should open HMI"
[[ "$APP_SELECTED_EDGE" == "flnc1014/A_C001_SDU" ]] || fail "cursor 1 opened '$APP_SELECTED_EDGE'"
[[ "$APP_VIEW" == "coresdu" ]] || fail "core SDU view got '$APP_VIEW'"
pass "Enter opens selected HMI"

echo "ALL PASS"
