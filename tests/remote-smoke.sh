#!/usr/bin/env bash
# Headless MQTT connect smoke for the array broker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/sparkplug.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bash/mqtt.sh"

mqtt_connect 127.0.0.1 1883 nsdtools-m10-hmi-test "" "" || true
echo "APP_CONNECTED:${APP_CONNECTED:-0}"
echo "APP_ERROR:${APP_ERROR:-}"
mqtt_disconnect || true
if [[ "${APP_CONNECTED:-0}" -eq 1 ]]; then
  echo MQTT_OK
  exit 0
fi
echo MQTT_FAIL
exit 1
