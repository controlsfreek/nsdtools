#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
expected_build=$("$ROOT_DIR/lib/bash/stamp_fhm_build.sh")
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
host octe003 { fixed-address 10.8.8.1; }
host A_UPS001 { hardware ethernet 22:33:44:55:66:77; fixed-address 192.0.2.10; }
host ups003 { fixed-address 10.8.8.20; }
host ups999 { fixed-address 10.9.9.1; }
EOF

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -i 10 -g "$TEMP_DIR/dhcp.conf" >"$TEMP_DIR/output" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF 'A_OCTE001' "$TEMP_DIR/output" && grep -qF 'octe002' "$TEMP_DIR/output" &&
        grep -qF 'A_UPS001' "$TEMP_DIR/output" && grep -qF 'ups999' "$TEMP_DIR/output"; then
        break
    fi
    sleep 0.1
done

if ! grep -qF 'A_OCTE001' "$TEMP_DIR/output" || ! grep -qF 'octe002' "$TEMP_DIR/output" ||
    ! grep -qF 'A_UPS001' "$TEMP_DIR/output" || ! grep -qF 'ups999' "$TEMP_DIR/output"; then
    cat "$TEMP_DIR/output" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

header_line=$(sed -n '1p' "$TEMP_DIR/output")
commit_count=$(git -C "$ROOT_DIR" rev-list --count HEAD)
[[ $expected_build -eq $((commit_count + 1)) ]]
[[ $header_line == 'Fluence Host Monitor'* ]]
[[ $header_line == *'build '"$expected_build"* ]]
printf 'fhm header title and build passed\n'

octe_header_line=$(grep -nF '[OCTE]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
octe_host_line=$(grep -nF 'octe002' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
mixed_case_octe_line=$(grep -nF 'A_OCTE001' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)

[[ -n $octe_header_line && -n $octe_host_line && -n $mixed_case_octe_line ]]
((octe_header_line < octe_host_line))
((octe_header_line < mixed_case_octe_line))
printf 'fhm OCTE ordering passed\n'

octe001_line=$(grep -nE 'A_OCTE001[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
ups001_line=$(grep -nE 'A_UPS001[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
octe003_line=$(grep -nE 'octe003[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
ups003_line=$(grep -nE 'ups003[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
ups999_line=$(grep -nE 'ups999[[:space:]]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
[[ -n $octe001_line && -n $ups001_line && -n $octe003_line && -n $ups003_line && -n $ups999_line ]]
((octe001_line + 1 == ups001_line))
((octe003_line + 1 == ups003_line))
((ups001_line < octe_host_line))
((ups003_line < ups999_line))
if grep -qF '[UPS]' "$TEMP_DIR/output"; then
    printf 'UPS section should be inside [OCTE]\n' >&2
    cat "$TEMP_DIR/output" >&2
    exit 1
fi
octe001_row=$(sed -n "${octe001_line}p" "$TEMP_DIR/output")
ups001_row=$(sed -n "${ups001_line}p" "$TEMP_DIR/output")
octe001_indent=${octe001_row%%[! ]*}
ups001_indent=${ups001_row%%[! ]*}
((${#ups001_indent} == ${#octe001_indent} + 1))
core_after_ups=$(grep -nF '[c1]' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
[[ -n $core_after_ups ]]
((octe_header_line < ups999_line))
((ups999_line < core_after_ups))
printf 'fhm UPS under matching OCTE passed\n'

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

assert_first_grid_line_has_no_hosts() {
    local output=$1
    local label=$2
    local grid_start first_grid_line
    grid_start=$(awk 'NR > 2 && $0 ~ /[^[:space:]]/ { print NR; exit }' "$output")
    [[ -n $grid_start ]]
    first_grid_line=$(sed -n "${grid_start}p" "$output")
    if [[ $first_grid_line =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s first grid line included a host address: %s\n' "$label" "$first_grid_line" >&2
        cat "$output" >&2
        exit 1
    fi
    if [[ $first_grid_line == *octe002* || $first_grid_line == *A_OCTE* || $first_grid_line == *c[0-9]n* || $first_grid_line == *-core-switch* ]]; then
        printf '%s first grid line included a host name: %s\n' "$label" "$first_grid_line" >&2
        cat "$output" >&2
        exit 1
    fi
}

PATH="$TEMP_DIR/bin:$PATH" \
    FHM_TEST_ROWS=12 FHM_TEST_COLS=120 \
    "$ROOT_DIR/bin/fhm" -i 10 -g "$TEMP_DIR/dhcp.conf" >"$TEMP_DIR/wide.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF '[OCTE]' "$TEMP_DIR/wide.out"; then
        break
    fi
    sleep 0.1
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

if ! grep -qF '[OCTE]' "$TEMP_DIR/wide.out"; then
    cat "$TEMP_DIR/wide.out" >&2
    exit 1
fi
assert_first_grid_line_has_no_hosts "$TEMP_DIR/wide.out" 'wide page 1'

PATH="$TEMP_DIR/bin:$PATH" \
    FHM_TEST_ROWS=12 FHM_TEST_COLS=120 FHM_TEST_PAGE=2 \
    "$ROOT_DIR/bin/fhm" -i 10 -g "$TEMP_DIR/pages.conf" >"$TEMP_DIR/wide-page2.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qE '\[c[0-9]+\]' "$TEMP_DIR/wide-page2.out"; then
        break
    fi
    sleep 0.1
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

if ! grep -qE '\[c[0-9]+\]' "$TEMP_DIR/wide-page2.out"; then
    cat "$TEMP_DIR/wide-page2.out" >&2
    exit 1
fi
assert_first_grid_line_has_no_hosts "$TEMP_DIR/wide-page2.out" 'wide page 2'
printf 'fhm first grid line has no hosts passed\n'

PATH="$TEMP_DIR/bin:$PATH" \
    FHM_TEST_ROWS=12 FHM_TEST_COLS=140 \
    "$ROOT_DIR/bin/fhm" -i 10 -g "$TEMP_DIR/pages.conf" >"$TEMP_DIR/span.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF '[c1]' "$TEMP_DIR/span.out"; then
        break
    fi
    sleep 0.1
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

if ! grep -qF '[c1]' "$TEMP_DIR/span.out" || ! grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/span.out"; then
    cat "$TEMP_DIR/span.out" >&2
    exit 1
fi
if grep -qF '[c2]' "$TEMP_DIR/span.out" || grep -qF 'c2-core-switch' "$TEMP_DIR/span.out" ||
    grep -qE 'c2n1r1e1[[:space:]]' "$TEMP_DIR/span.out"; then
    printf 'page 1 leaked the next core onto the bottom of the columns\n' >&2
    cat "$TEMP_DIR/span.out" >&2
    exit 1
fi
printf 'fhm page does not leak next core passed\n'

PATH="$TEMP_DIR/bin:$PATH" \
    FHM_TEST_ROWS=12 FHM_TEST_COLS=140 FHM_TEST_PAGE=2 \
    "$ROOT_DIR/bin/fhm" -i 10 -g "$TEMP_DIR/pages.conf" >"$TEMP_DIR/span2.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF '[c2]' "$TEMP_DIR/span2.out"; then
        break
    fi
    sleep 0.1
done

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''

if ! grep -qF '[c2]' "$TEMP_DIR/span2.out" || ! grep -qF 'c2-core-switch' "$TEMP_DIR/span2.out"; then
    cat "$TEMP_DIR/span2.out" >&2
    exit 1
fi
if grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/span2.out"; then
    printf 'page 2 included the previous core\n' >&2
    cat "$TEMP_DIR/span2.out" >&2
    exit 1
fi
printf 'fhm next page starts at snapped core passed\n'

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -c -i 10 -g "$TEMP_DIR/dhcp.conf" >"$TEMP_DIR/collapse-up.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/collapse-up.out"; then
        break
    fi
    sleep 0.1
done

if ! grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/collapse-up.out"; then
    cat "$TEMP_DIR/collapse-up.out" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''
printf 'fhm collapse keeps pingable cores passed\n'

cat >"$TEMP_DIR/bin/ping" <<'EOF'
#!/usr/bin/env bash
addr=${!#}
if [[ $addr == 10.204.7.134 ]]; then
    printf '100%% packet loss\n'
    exit 1
fi
printf '64 bytes time=1.0 ms\n'
EOF
chmod +x "$TEMP_DIR/bin/ping"

cat >"$TEMP_DIR/collapse.conf" <<'EOF'
host c1n1r1e1 { hardware ethernet aa:bb:cc:dd:ee:ff; fixed-address 192.0.2.2; }
host c1n1r1e1sw { hardware ethernet 11:22:33:44:55:66; fixed-address 192.0.2.4; }
host c2n1r1e1 { fixed-address 192.0.2.20; }
host A_OCTE001 { hardware ethernet 00:11:22:33:44:55; fixed-address 192.0.2.1; }
EOF

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -i 10 -g "$TEMP_DIR/collapse.conf" >"$TEMP_DIR/collapse-off.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/collapse-off.out" &&
        grep -qE 'c2n1r1e1[[:space:]]' "$TEMP_DIR/collapse-off.out"; then
        break
    fi
    sleep 0.1
done

if ! grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/collapse-off.out" ||
    ! grep -qE 'c2n1r1e1[[:space:]]' "$TEMP_DIR/collapse-off.out"; then
    cat "$TEMP_DIR/collapse-off.out" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''
printf 'fhm down core switch still shows hosts without -c passed\n'

PATH="$TEMP_DIR/bin:$PATH" "$ROOT_DIR/bin/fhm" \
    -c -i 10 -g "$TEMP_DIR/collapse.conf" >"$TEMP_DIR/collapse-down.out" 2>&1 &
MONITOR_PID=$!

for _ in {1..50}; do
    if grep -qF '[c1]' "$TEMP_DIR/collapse-down.out" &&
        grep -qF '10.204.7.134' "$TEMP_DIR/collapse-down.out" &&
        grep -qE 'c2n1r1e1[[:space:]]' "$TEMP_DIR/collapse-down.out" &&
        grep -qF 'A_OCTE001' "$TEMP_DIR/collapse-down.out"; then
        break
    fi
    sleep 0.1
done

if ! grep -qF '[c1]' "$TEMP_DIR/collapse-down.out" ||
    ! grep -qF '10.204.7.134' "$TEMP_DIR/collapse-down.out" ||
    ! grep -qE 'c2n1r1e1[[:space:]]' "$TEMP_DIR/collapse-down.out" ||
    ! grep -qF 'A_OCTE001' "$TEMP_DIR/collapse-down.out"; then
    cat "$TEMP_DIR/collapse-down.out" >&2
    exit 1
fi
if grep -qE 'c1n1r1e1[[:space:]]' "$TEMP_DIR/collapse-down.out" ||
    grep -qE 'c1n1r1e1sw[[:space:]]' "$TEMP_DIR/collapse-down.out"; then
    printf 'collapsed core still listed enclosure hosts\n' >&2
    cat "$TEMP_DIR/collapse-down.out" >&2
    exit 1
fi

kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=''
printf 'fhm collapse hides unpingable cores passed\n'