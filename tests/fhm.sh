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
host_line=$(grep -nF 'c1n1r1e1' "$TEMP_DIR/output" | head -n 1 | cut -d: -f1)
[[ -n $core_line && -n $switch_line && -n $host_line ]]
((core_line < switch_line))
((switch_line < host_line))
if grep -qF 'aa:bb:cc:dd:ee:ff' "$TEMP_DIR/output"; then
    printf 'MAC shown without -m\n' >&2
    cat "$TEMP_DIR/output" >&2
    exit 1
fi
printf 'fhm core switch passed\n'

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