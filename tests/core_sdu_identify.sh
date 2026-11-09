#!/usr/bin/env bash
# Identify CoreSDU devices and Core_hb heartbeat from metric names.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/demo.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok  $*" ; }

now=$(now_epoch)
load_demo "$now"
list_sdus

((${#SDUS[@]} == 3)) || fail "expected 3 CoreSDU devices, got ${#SDUS[@]}"
pass "demo lists 3 CoreSDU devices"

for key in "${SDUS[@]}"; do
  [[ "${DEV_IS_SDU[$key]}" -eq 1 ]] || fail "$key not marked SDU"
  identify_sdu "$key" || fail "$key missing CoreSDU metric"
  [[ -n "$(heartbeat_value "$key")" ]] || fail "$key missing Core_hb"
done
pass "listed devices have CoreSDU and Core_hb"

pcs="flnc1014/A_C001_N001_DAC01"
[[ "${DEV_IS_SDU[$pcs]:-0}" -eq 0 ]] || fail "DAC marked as CoreSDU"
for key in "${SDUS[@]}"; do
  [[ "$key" != "$pcs" ]] || fail "PCS appeared in CoreSDU list"
done
pass "non-CoreSDU device excluded"

ensure_device "g/n/late" "g" "n" "late"
upsert_metric "g/n/late" "noise" "1" "$now"
classify_device "g/n/late"
[[ "${DEV_IS_SDU[g/n/late]}" -eq 0 ]] || fail "late classified before CoreSDU"
upsert_metric "g/n/late" "path/coresdu/stat" "1" "$now"
upsert_metric "g/n/late" "foo/core_hb" "42" "$now"
classify_device "g/n/late"
identify_sdu "g/n/late" || fail "late CoreSDU not detected"
[[ "$(heartbeat_value "g/n/late")" == "42" ]] || fail "core_hb substring not found"
pass "CoreSDU and Core_hb matches are case-insensitive substrings"

echo "ALL PASS"
