#!/usr/bin/env bash
# Identify inverters (inverter01) vs BMS (BankBMS) from metric names.
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
list_inverters

((${#INVERTERS[@]} == 3)) || fail "expected 3 inverters, got ${#INVERTERS[@]}"
pass "demo lists 3 inverters"

for key in "${INVERTERS[@]}"; do
  [[ "${DEV_IS_M10[$key]}" -eq 1 ]] || fail "$key not marked M10"
  [[ "${DEV_IS_BMS[$key]:-0}" -eq 0 ]] || fail "$key marked BMS"
  identify_m10 "$key" || fail "$key missing inverter01 metric"
done
pass "listed devices have inverter01 metrics"

bms="Fluence/BMS-1"
[[ "${DEV_IS_BMS[$bms]}" -eq 1 ]] || fail "BMS-1 not marked BMS"
[[ "${DEV_IS_M10[$bms]}" -eq 0 ]] || fail "BMS-1 marked as inverter"
identify_bms "$bms" || fail "BMS-1 missing BankBMS metric"
for key in "${INVERTERS[@]}"; do
  [[ "$key" != "$bms" ]] || fail "BMS appeared in inverter list"
done
pass "BankBMS device excluded from inverter list"

ensure_device "g/n/other" "g" "n" "other"
upsert_metric "g/n/other" "Status/State" "OK" "$now"
classify_device "g/n/other"
list_inverters
((${#INVERTERS[@]} == 3)) || fail "unidentified device leaked into list"
[[ "${DEV_IS_M10[g/n/other]}" -eq 0 ]] || fail "other marked M10"
[[ "${DEV_IS_BMS[g/n/other]}" -eq 0 ]] || fail "other marked BMS"
pass "unidentified device ignored"

ensure_device "g/n/late" "g" "n" "late"
upsert_metric "g/n/late" "noise" "1" "$now"
classify_device "g/n/late"
[[ "${DEV_IS_M10[g/n/late]}" -eq 0 ]] || fail "late classified before inverter01"
upsert_metric "g/n/late" "path/inverter01/kw" "1" "$now"
classify_device "g/n/late"
identify_m10 "g/n/late" || fail "late inverter01 not detected"
[[ "${DEV_IS_M10[g/n/late]}" -eq 1 ]] || fail "late not marked M10"
pass "inverter01 match is case-insensitive substring"

ensure_device "g/n/bank" "g" "n" "bank"
upsert_metric "g/n/bank" "foo/bankbms/bar" "1" "$now"
classify_device "g/n/bank"
identify_bms "g/n/bank" || fail "bankbms lowercase not detected"
[[ "${DEV_IS_BMS[g/n/bank]}" -eq 1 ]] || fail "bank not marked BMS"
list_inverters
for key in "${INVERTERS[@]}"; do
  [[ "$key" != "g/n/bank" ]] || fail "BankBMS device listed as inverter"
done
pass "BankBMS match is case-insensitive substring"

echo "ALL PASS"
