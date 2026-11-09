#!/usr/bin/env bash
# Main loop: draw, keys, MQTT drain / demo refresh.

wanted_topic() {
  if [[ -n "$ARGS_GROUP" && "$SP_GROUP" != "$ARGS_GROUP" ]]; then return 1; fi
  if [[ -n "$ARGS_NODE" && "$SP_NODE" != "$ARGS_NODE" ]]; then return 1; fi
  return 0
}

mqtt_on_publish() {
  local topic="$1" payload_hex="$2"
  parse_topic "$topic" || return 0
  wanted_topic || return 0
  case "$SP_MSGTYPE" in
    NBIRTH|DBIRTH|NDATA|DDATA|NDEATH|DDEATH|STATE) ;;
    *) return 0 ;;
  esac
  [[ "$SP_KIND" == "cmd" ]] && return 0
  [[ "$SP_KIND" == "state" ]] && return 0

  local now
  now=$(now_epoch)
  record_edge_node "$SP_GROUP" "$SP_NODE" "$SP_DEVICE" "$now"
  ensure_device "$SP_KEY" "$SP_GROUP" "$SP_NODE" "$SP_DEVICE"

  if [[ "$SP_KIND" == "death" ]]; then
    DEV_ONLINE[$SP_KEY]=0
    DEV_LAST[$SP_KEY]="$now"
    return 0
  fi

  # List view only needs the topic. Protobuf decode of retained NBIRTH
  # floods is too slow in bash and blocks q / Ctrl-C.
  if [[ "$APP_MODE" == "list" ]]; then
    return 0
  fi
  if [[ -n "${APP_SELECTED_EDGE:-}" ]]; then
    local ekey="${SP_GROUP}/${SP_NODE}"
    if [[ "$ekey" != "$APP_SELECTED_EDGE" && "$SP_KEY" != "${APP_SELECTED:-}" ]]; then
      return 0
    fi
  fi

  decode_payload_hex "$payload_hex" || {
    APP_ERROR="decode failed"
    return 0
  }

  if [[ "$SP_KIND" == "birth" ]]; then
    DEV_ONLINE[$SP_KEY]=1
    DEV_BORN[$SP_KEY]=1
    if [[ "$SP_MSGTYPE" == "DBIRTH" || -n "$SP_DEVICE" ]]; then
      # clear aliases and metrics for this device
      local mk a
      for mk in "${!METRIC_VAL[@]}"; do
        if [[ "$mk" == "$SP_KEY|"* ]]; then
          unset "METRIC_VAL[$mk]" "METRIC_UNIT[$mk]" "METRIC_SLOT[$mk]" "METRIC_TS[$mk]"
        fi
      done
      for a in "${!ALIAS_MAP[@]}"; do
        if [[ "$a" == "$SP_KEY|"* ]]; then
          unset "ALIAS_MAP[$a]"
        fi
      done
    fi
  elif [[ "$SP_KIND" == "data" ]]; then
    DEV_ONLINE[$SP_KEY]=1
  fi
  DEV_LAST[$SP_KEY]="$now"
  [[ -n "$PL_SEQ" ]] && DEV_SEQ[$SP_KEY]="$PL_SEQ"

  local i name alias ts value ts_use
  for ((i=0; i<${#MD_NAME[@]}; i++)); do
    name=$(resolve_name "$SP_KEY" "${MD_ALIAS[$i]}" "${MD_NAME[$i]}")
    [[ -z "$name" ]] && continue
    [[ "${MD_NULL[$i]}" == "1" ]] && continue
    value="${MD_VALUE[$i]}"
    ts="${MD_TS[$i]:-${PL_TIMESTAMP:-}}"
    ts_use="$now"
    if [[ -n "$ts" ]]; then
      # sparkplug timestamps are usually ms
      if (( ts > 1000000000000 )); then
        ts_use=$(( ts / 1000 ))
      elif (( ts > 1000000000 )); then
        ts_use=$ts
      fi
    fi
    upsert_metric "$SP_KEY" "$name" "$value" "$ts_use"
  done

  if [[ "$SP_KIND" == "birth" || "${DEV_IS_M10[$SP_KEY]:-0}" -eq 0 \
        || "${DEV_IS_BMS[$SP_KEY]:-0}" -eq 0 || "${DEV_IS_SDU[$SP_KEY]:-0}" -eq 0 ]]; then
    classify_device "$SP_KEY"
  fi
}

open_cursor() {
  list_nodes
  ((${#BROWSE_KEYS[@]})) || return 0
  if (( APP_CURSOR < 0 )); then APP_CURSOR=0; fi
  if (( APP_CURSOR >= ${#BROWSE_KEYS[@]} )); then APP_CURSOR=$((${#BROWSE_KEYS[@]} - 1)); fi
  APP_SELECTED_EDGE="${BROWSE_KEYS[$APP_CURSOR]}"
  APP_SELECTED="$(select_device_for_edge "$APP_SELECTED_EDGE")"
  APP_VIEW="$(view_for_edge "$APP_SELECTED_EDGE" "$APP_SELECTED")"
  APP_MODE="detail"
}

# Read one key into APP_KEY (not stdout: $(…) strips Enter / trailing NL).
# Maps arrows to j/k, CR/LF to enter, bare Esc → esc. Drains CSI.
read_key() {
  local timeout="${1:-0.2}"
  local ch="" more="" seq=""
  APP_KEY=""
  if ! IFS= read -rsn1 -t "$timeout" ch; then
    return 1
  fi
  ch="${ch:-}"
  if [[ "$ch" == $'\r' || "$ch" == $'\n' ]]; then
    APP_KEY="enter"
    return 0
  fi
  if [[ "$ch" != $'\033' ]]; then
    APP_KEY="$ch"
    return 0
  fi
  # drain CSI / SS3 (short wait: arrows arrive immediately)
  seq="$ch"
  while IFS= read -rsn1 -t 0.01 more; do
    seq+="${more:-}"
    # end of typical CSI
    [[ "${more:-}" =~ [A-Za-z~] ]] && break
  done
  if [[ "$seq" == $'\033' ]]; then
    APP_KEY="esc"
    return 0
  fi
  # [[ ]] not case: '[' in CSI would be a glob class in case patterns.
  if [[ "$seq" == $'\033[A' || "$seq" == $'\033OA' ]]; then
    APP_KEY="k"
    return 0
  fi
  if [[ "$seq" == $'\033[B' || "$seq" == $'\033OB' ]]; then
    APP_KEY="j"
    return 0
  fi
  return 0
}

handle_key() {
  local ch="${1:-}"
  [[ -z "$ch" ]] && return 0
  case "$ch" in
    esc)
      if [[ "$APP_MODE" == "detail" ]]; then
        APP_MODE="list"
        APP_VIEW=""
        APP_SELECTED=""
        APP_SELECTED_EDGE=""
      fi
      return 0
      ;;
    q|Q|$'\003')
      APP_RUNNING=0
      return 0
      ;;
  esac
  if [[ "$APP_MODE" == "list" ]]; then
    list_nodes
    case "$ch" in
      j|J)
        if ((${#BROWSE_KEYS[@]})); then
          APP_CURSOR=$((APP_CURSOR + 1))
          if (( APP_CURSOR >= ${#BROWSE_KEYS[@]} )); then
            APP_CURSOR=$((${#BROWSE_KEYS[@]} - 1))
          fi
        fi
        ;;
      k|K)
        APP_CURSOR=$((APP_CURSOR - 1))
        if (( APP_CURSOR < 0 )); then
          APP_CURSOR=0
        fi
        ;;
      enter|$'\r'|$'\n'|' ')
        open_cursor
        ;;
    esac
  fi
  return 0
}

poll_keys() {
  local timeout="${1:-0}"
  APP_KEY=""
  read_key "$timeout" || true
  handle_key "${APP_KEY:-}"
}

app_run() {

  screen_enter
  OLD_STTY=""
  if [[ -t 0 ]]; then
    OLD_STTY=$(stty -g)
    stty cbreak -echo 2>/dev/null || stty -echo -icanon
  fi

  trap '' PIPE
  trap 'APP_RUNNING=0; exit 130' INT
  trap 'APP_RUNNING=0' TERM
  trap 'mqtt_disconnect 2>/dev/null || true; [[ -n "${OLD_STTY:-}" ]] && stty "$OLD_STTY" 2>/dev/null || true; screen_leave || true' EXIT

  local now host
  host="${ARGS_HOST:-demo}"
  now=$(now_epoch)
  screen_draw "$host" "$ARGS_PORT" "$APP_CONNECTED" "$APP_ERROR" "$ARGS_DEMO" "$now" "$APP_MODE" "$APP_SELECTED" "$APP_CURSOR"

  if (( ! ARGS_DEMO )); then
    mqtt_connect "$ARGS_HOST" "$ARGS_PORT" "$ARGS_CLIENT_ID" "$ARGS_USERNAME" "$ARGS_PASSWORD" || true
  fi

  local prev_draw=""
  while (( APP_RUNNING )); do
    now=$(now_epoch)
    if (( ARGS_DEMO )); then
      load_demo "$now"
      APP_CONNECTED=1
    else
      mqtt_drain 0 || true
    fi
    (( APP_RUNNING )) || break
    list_nodes
    if [[ -n "$ARGS_DEVICE" && -z "$APP_SELECTED_EDGE" ]]; then
      local k ekey
      for ekey in "${BROWSE_KEYS[@]}"; do
        if [[ "${ekey#*/}" == "$ARGS_DEVICE" ]]; then
          APP_SELECTED_EDGE="$ekey"
          APP_SELECTED="$(select_device_for_edge "$ekey")"
          APP_VIEW="$(view_for_edge "$ekey" "$APP_SELECTED")"
          APP_MODE="detail"
          break
        fi
      done
      if [[ -z "$APP_SELECTED_EDGE" ]]; then
        for k in "${DEV_ORDER[@]}"; do
          if [[ "${DEV_DEVICE[$k]}" == "$ARGS_DEVICE" || "${DEV_NODE[$k]}" == "$ARGS_DEVICE" ]]; then
            APP_SELECTED="$k"
            APP_SELECTED_EDGE="${DEV_GROUP[$k]}/${DEV_NODE[$k]}"
            APP_VIEW="$(view_for_edge "$APP_SELECTED_EDGE" "$APP_SELECTED")"
            APP_MODE="detail"
            break
          fi
        done
      fi
    fi
    if [[ "$APP_MODE" == "detail" && -n "$APP_SELECTED_EDGE" ]]; then
      APP_SELECTED="$(select_device_for_edge "$APP_SELECTED_EDGE")"
      APP_VIEW="$(view_for_edge "$APP_SELECTED_EDGE" "$APP_SELECTED")"
    fi
    if ((${#BROWSE_KEYS[@]})); then
      if (( APP_CURSOR < 0 )); then APP_CURSOR=0; fi
      if (( APP_CURSOR >= ${#BROWSE_KEYS[@]} )); then APP_CURSOR=$((${#BROWSE_KEYS[@]} - 1)); fi
    else
      APP_CURSOR=0
    fi
    local err=""
    (( ARGS_DEMO )) || err="$APP_ERROR"
    local draw_key="${APP_MODE}|${APP_CURSOR}|${APP_SELECTED_EDGE}|${#BROWSE_KEYS[@]}|${MQTT_PUBLISH_COUNT:-0}|${APP_STATUS}|${err}|${now}"
    if [[ "$draw_key" != "$prev_draw" ]]; then
      screen_draw "$host" "$ARGS_PORT" "$APP_CONNECTED" "$err" "$ARGS_DEMO" "$now" "$APP_MODE" "$APP_SELECTED" "$APP_CURSOR"
      prev_draw="$draw_key"
    fi
    # Idle wait is key input, not MQTT timeout(1).
    poll_keys 0.05 || true
  done

  if (( ! ARGS_DEMO )); then
    mqtt_disconnect
  fi
  if [[ -n "$OLD_STTY" ]]; then
    stty "$OLD_STTY" 2>/dev/null || true
    OLD_STTY=""
  fi
  screen_leave
  return 0
}
