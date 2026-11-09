#!/usr/bin/env bash
# Subscribe-only dump of Sparkplug edge nodes seen on a broker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-1883}"
SECS="${3:-20}"

# shellcheck source=/dev/null
source "${ROOT}/lib/bash/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/sparkplug.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/mqtt.sh"

ARGS_TOPIC="spBv1.0/#"
ARGS_CLIENT_ID="nsdtools-edge-nodes-$$"
APP_CONNECTED=0
APP_ERROR=""

mqtt_on_publish() {
  local topic="$1" payload_hex="$2"
  parse_topic "$topic" || return 0
  [[ "$SP_KIND" == "cmd" ]] && return 0
  [[ "$SP_KIND" == "state" ]] && return 0
  local now
  now=$(now_epoch)
  record_edge_node "$SP_GROUP" "$SP_NODE" "$SP_DEVICE" "$now"
}

echo "listening ${HOST}:${PORT} for ${SECS}s (subscribe-only)"
mqtt_connect "$HOST" "$PORT" "$ARGS_CLIENT_ID" "" "" || {
  echo "CONNECT_FAIL APP_ERROR:${APP_ERROR:-} APP_CONNECTED:${APP_CONNECTED:-0}" >&2
  exit 1
}
echo "APP_CONNECTED:${APP_CONNECTED}"

deadline=$(( $(now_epoch) + SECS ))
while (( $(now_epoch) < deadline )); do
  mqtt_drain 0.2 || true
done
mqtt_disconnect || true
dump_edge_nodes
