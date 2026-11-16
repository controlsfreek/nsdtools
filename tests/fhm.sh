#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
MONITOR_PID=''
cleanup() {
    if [[ -n $MONITOR_PID ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

mkdir "$TEMP_DIR/bin"
cat >"$TEMP_DIR/bin/ping" <<'EOF'
#!/usr/bin/env bash
printf '64 bytes time=1.0 ms\n'
EOF
chmod +x "$TEMP_DIR/bin/ping"
cat >"$TEMP_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '1: lo    inet 127.0.0.1/8 scope host lo\n'
printf '2: eth0    inet 10.204.7.20/24 brd 10.204.7.255 scope global eth0\n'
EOF
chmod +x "$TEMP_DIR/bin/ip"

missing_status=0
PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -g "$TEMP_DIR/missing.conf" >"$TEMP_DIR/missing.out" 2>"$TEMP_DIR/missing.err" || missing_status=$?
[[ $missing_status -eq 1 ]]
[[ ! -s $TEMP_DIR/missing.out ]]
grep -qF "No configuration files found at /etc/dhcp/dhcpd.conf or matching $TEMP_DIR/missing.conf" \
    "$TEMP_DIR/missing.err"
printf 'fhm missing dhcp config passed\n'

cat >"$TEMP_DIR/dhcp.conf" <<'EOF'
host c1n1r1e1 { hardware ethernet aa:bb:cc:dd:ee:ff; fixed-address 192.0.2.2; }
host c1n1r1e1sw { hardware ethernet 11:22:33:44:55:66; fixed-address 192.0.2.4; }
host c1n1r1e2 { fixed-address 192.0.2.5; }
host c1n1r1e2sw { fixed-address 192.0.2.6; }
host A_OCTE001 { hardware ethernet 00:11:22:33:44:55; fixed-address 192.0.2.1; }
host octe002 { fixed-address 192.0.2.3; }
EOF

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -i 10 -g "$TEMP_DIR/dhcp.conf" >"$TEMP_DIR/output" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF 'A_OCTE001' "$TEMP_DIR/output" && grep -qF 'octe002' "$TEMP_DIR/output"; then
        break
    fi
    sleep 0.1
done

if ! grep -qF 'A_OCTE001' "$TEMP_DIR/output" || ! grep -qF 'octe002' "$TEMP_DIR/output"; then
    cat "$TEMP_DIR/output" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

octe_header_line=$(grep -nF '[OCTE]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
octe_host_line=$(grep -nF 'octe002' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
mixed_case_octe_line=$(grep -nF 'A_OCTE001' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)

[[ -n $octe_header_line && -n $octe_host_line && -n $mixed_case_octe_line ]]
((octe_header_line < octe_host_line))
((octe_header_line < mixed_case_octe_line))
printf 'fhm OCTE ordering passed\n'

core_line=$(grep -nF '[c1]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
switch_line=$(grep -nF '10.204.7.134' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
host_line=$(grep -nE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
[[ -n $core_line && -n $switch_line && -n $host_line ]]
((core_line < switch_line))
((switch_line < host_line))
if grep -qF 'aa:bb:cc:dd:ee:ff' "$TEMP_DIR/output"; then
    printf 'MAC shown without -m\n' >&2
    cat "$TEMP_DIR/output" >&2
    exit 1
fi
printf 'fhm core switch passed\n'

e1sw_line=$(grep -nE 'c1n1r1e1sw[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
e1_line=$(grep -nE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
e2sw_line=$(grep -nE 'c1n1r1e2sw[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
e2_line=$(grep -nE 'c1n1r1e2[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
[[ -n $e1sw_line && -n $e1_line && -n $e2sw_line && -n $e2_line ]]
((e1sw_line + 1 == e1_line))
((e2sw_line + 1 == e2_line))
((e1_line < e2sw_line))
e1sw_row=$(sed -n "${e1sw_line}p" "$TEMP_DIR/output")
e1_row=$(sed -n "${e1_line}p" "$TEMP_DIR/output")
e1sw_indent=${e1sw_row%%[! ]*}
e1_indent=${e1_row%%[! ]*}
((${#e1_indent} == ${#e1sw_indent} + 1))
printf 'fhm enclosure switch order passed\n'

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -m -i 10 -g "$TEMP_DIR/dhcp.conf" >"$TEMP_DIR/mac.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF 'aa:bb:cc:dd:ee:ff' "$TEMP_DIR/mac.out" && grep -qF '192.0.2.2' "$TEMP_DIR/mac.out"; then
        break
    fi
    sleep 0.1
done

if ! grep -qF 'aa:bb:cc:dd:ee:ff' "$TEMP_DIR/mac.out" || ! grep -qF '192.0.2.2' "$TEMP_DIR/mac.out"; then
    cat "$TEMP_DIR/mac.out" >&2
    exit 1
fi
if ! grep -qF '00:11:22:33:44:55' "$TEMP_DIR/mac.out"; then
    cat "$TEMP_DIR/mac.out" >&2
    exit 1
fi
if ! grep -qE 'octe002[[:space:]].*192\.0\.2\.3[[:space:]]+-[[:space:]]' "$TEMP_DIR/mac.out"; then
    cat "$TEMP_DIR/mac.out" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''
printf 'fhm MAC display passed\n'

{
    printf 'host A_OCTE001 { fixed-address 192.0.2.1; }\n'
    for core in 1 2 3 4 5 6; do
        for node in 1 2; do
            for enclosure in 1 2 3 4; do
                printf 'host c%sn%sr1e%s { fixed-address 10.0.%s.%s%s; }\n' \
                    "$core" "$node" "$enclosure" "$core" "$node" "$enclosure"
            done
        done
    done
} >"$TEMP_DIR/pages.conf"

PATH="$TEMP_DIR/bin:$PATH" \
    FHM_TEST_ROWS=12 FHM_TEST_COLS=80 FHM_TEST_PAGE=2 \
    "$ROOT_DIR/bin/fhm" -i 10 -g "$TEMP_DIR/pages.conf" >"$TEMP_DIR/page2.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qE '\[c[0-9]+\]' "$TEMP_DIR/page2.out"; then
        break
    fi
    sleep 0.1
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

if ! grep -qE '\[c[0-9]+\]' "$TEMP_DIR/page2.out"; then
    cat "$TEMP_DIR/page2.out" >&2
    exit 1
fi

grid_start=$(awk 'NR > 2 && $0 ~ /[^[:space:]]/ { print NR; exit }' "$TEMP_DIR/page2.out")
[[ -n $grid_start ]]
first_grid_line=$(sed -n "${grid_start}p" "$TEMP_DIR/page2.out")
if [[ $first_grid_line != *\[c[0-9]*\]* ]]; then
    printf 'page 2 did not start at a core header: %s\n' "$first_grid_line" >&2
    cat "$TEMP_DIR/page2.out" >&2
    exit 1
fi
if [[ $first_grid_line == *\[n[0-9]*\]* ]]; then
    printf 'page 2 started with a node header: %s\n' "$first_grid_line" >&2
    cat "$TEMP_DIR/page2.out" >&2
    exit 1
fi
printf 'fhm page starts at core top passed\n'