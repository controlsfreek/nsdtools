#!/usr/bin/env bash
# enclosure-mfr-report collect/rename tests (no SSH).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/collect_enclosure_logs.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok  $*" ; }

detect_python() {
  local cand
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return
    fi
  done
  fail "python3 is required"
}

assert_tokens() {
  local path="$1" exp_c="$2" exp_n="$3" exp_r="$4" exp_e="$5"
  parse_path_c_n_r_e "$path" || true
  [[ "${PATH_C}" == "$exp_c" ]] || fail "c for $path: got '${PATH_C}' want $exp_c"
  [[ "${PATH_N}" == "$exp_n" ]] || fail "n for $path: got '${PATH_N}' want $exp_n"
  [[ "${PATH_R}" == "$exp_r" ]] || fail "r for $path: got '${PATH_R}' want $exp_r"
  [[ "${PATH_E}" == "$exp_e" ]] || fail "e for $path: got '${PATH_E}' want $exp_e"
}

# Table from the plan
assert_tokens "/opt/fos_deployment/logs/enclosure/c1n2r3e4/run.log" 1 2 3 4
assert_tokens "/opt/fos_deployment/logs/enclosure/c001/n002/r01/e03/mfg.log" 1 2 1 3
assert_tokens "/opt/fos_deployment/logs/enclosure/C12_N3_R1_E8/x.log" 12 3 1 8
pass "bash c/n/r/e table"

PY="$(detect_python)"
cmp_py() {
  local path="$1"
  parse_path_c_n_r_e "$path" || true
  local got py
  got="${PATH_C:-None} ${PATH_N:-None} ${PATH_R:-None} ${PATH_E:-None}"
  got="${got// / }"
  py="$(PYTHONPATH="${ROOT}/lib/python" "$PY" -c "
from enclosure_mfr.c_n_r_e import parse
p = parse(r'''$path''')
def v(x):
    return 'None' if x is None else str(x)
print(v(p['c']), v(p['n']), v(p['r']), v(p['e']))
")"
  local bash_s="$got"
  # empty bash fields -> None
  bash_s="${PATH_C:-None} ${PATH_N:-None} ${PATH_R:-None} ${PATH_E:-None}"
  [[ "$bash_s" == "$py" ]] || fail "bash/python mismatch for $path bash='$bash_s' py='$py'"
}
cmp_py "/opt/fos_deployment/logs/enclosure/c1n2r3e4/run.log"
cmp_py "/opt/fos_deployment/logs/enclosure/c001/n002/r01/e03/mfg.log"
cmp_py "/opt/fos_deployment/logs/enclosure/C12_N3_R1_E8/x.log"
cmp_py "/opt/fos_deployment/logs/enclosure/untagged/orphan.log"
pass "bash and python c/n/r/e match"

[[ "$(format_renamed_log 1 2 1 3 mfg.log)" == "c001_n002_r01_e03_mfg.log" ]] \
  || fail "rename example"
pass "rename padding"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/tree"
mkdir -p "$TREE/c1n2r3e4" "$TREE/c001/n002/r01/e03" "$TREE/C12_N3_R1_E8" "$TREE/untagged" "$TREE/c9n9r9e9"
printf 'x\n' >"$TREE/c1n2r3e4/run.log"
printf 'x\n' >"$TREE/c001/n002/r01/e03/mfg.log"
printf 'x\n' >"$TREE/C12_N3_R1_E8/x.log"
printf 'x\n' >"$TREE/untagged/orphan.log"
printf 'a\n' >"$TREE/c9n9r9e9/dup.log"
mkdir -p "$TREE/other/c9n9r9e9"
printf 'b\n' >"$TREE/other/c9n9r9e9/dup.log"

DEST="$TMP/package"
MAN="$TMP/manifest.txt"
collect_from_dir "$TREE" "$DEST" "$MAN"

[[ -f "$DEST/c001_n002_r03_e04_run.log" ]] || fail "missing renamed run.log"
[[ -f "$DEST/c001_n002_r01_e03_mfg.log" ]] || fail "missing renamed mfg.log"
[[ -f "$DEST/c012_n003_r01_e08_x.log" ]] || fail "missing renamed x.log"
[[ ! -f "$DEST/orphan.log" ]] || fail "untagged orphan was copied"
grep -q 'skipped:no-e' "$MAN" || fail "manifest missing skipped:no-e"
pass "collect rename and skip"

[[ -f "$DEST/c009_n009_r09_e09_dup.log" ]] || fail "missing first dup"
[[ -f "$DEST/c009_n009_r09_e09_dup__2.log" ]] || fail "missing collision __2"
pass "collision rename"

CLI="${ROOT}/bin/enclosure-mfr-report"
chmod +x "$CLI" 2>/dev/null || true
"$CLI" --help >/dev/null || fail "--help failed"
pass "CLI --help"

if "$CLI" --password secret --from-dir "$TREE" >/dev/null 2>"$TMP/err"; then
  fail "--password should be rejected"
fi
grep -qi 'password' "$TMP/err" || fail "--password error should mention password"
if grep -qiE -- '--password[^\n]*accepted' "$TMP/err"; then
  fail "unexpected"
fi
pass "CLI rejects --password"

OUT="$TMP/out"
"$CLI" --from-dir "${ROOT}/tests/fixtures/enclosure_logs" --out-dir "$OUT" >/dev/null
[[ -f "$OUT/stats-report.md" ]] || fail "missing stats-report.md"
[[ -f "$OUT/corrective-action-report.md" ]] || fail "missing corrective-action-report.md"
[[ -f "$OUT/unparsed.txt" ]] || fail "missing unparsed.txt"
[[ -f "$OUT/deviations.csv" ]] || fail "missing deviations.csv"
[[ -f "$OUT/package/c001_n002_r03_e04_run.log" ]] || fail "package missing run.log"
grep -q 'something weird' "$OUT/unparsed.txt" || fail "unparsed.txt missing junk FAIL"
grep -q 'c1/n2/r3/e4' "$OUT/stats-report.md" || fail "stats missing enclosure id"
grep -q 'Needs human review' "$OUT/corrective-action-report.md" || fail "corrective missing review section"
pass "CLI --from-dir writes reports"

echo "ALL OK"
