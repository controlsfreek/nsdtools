#!/usr/bin/env bash
# Subscribe-only MQTT 3.1.1 over bash /dev/tcp. Never PUBLISH or WILL.

MQTT_FD=""
MQTT_BUF_HEX=""
MQTT_KEEPALIVE=30
MQTT_LAST_PING=0
MQTT_PACKET_ID=1
MQTT_TCP_TIMEOUT=8
MQTT_PUBLISH_COUNT=0
MQTT_MAX_PACKETS_PER_DRAIN=12

mqtt_note() {
  APP_STATUS="$1"
  if declare -F screen_draw >/dev/null 2>&1 && (( ${SCREEN_STARTED:-0} )); then
    local now host
    now=$(now_epoch)
    host="${ARGS_HOST:-demo}"
    screen_draw "$host" "$ARGS_PORT" "$APP_CONNECTED" "$APP_ERROR" "$ARGS_DEMO" "$now" "$APP_MODE" "$APP_SELECTED" "$APP_CURSOR"
  fi
}

# Encode integer as MQTT remaining-length bytes (prints hex pairs)
mqtt_rl_hex() {
  local x="$1" enc
  while :; do
    enc=$((x % 128))
    x=$((x / 128))
    if (( x > 0 )); then enc=$((enc | 128)); fi
    printf '%02x' "$enc"
    (( x == 0 )) && break
  done
}

# UTF-8 string field: 2-byte length + bytes → hex
mqtt_str_hex() {
  local s="$1"
  local len=${#s}
  printf '%04x' "$len"
  local i c
  for ((i=0; i<len; i++)); do
    c=$(printf '%d' "'${s:i:1}")
    printf '%02x' "$c"
  done
}

mqtt_write_hex() {
  local hex="$1"
  [[ -n "${MQTT_FD:-}" ]] || return 1
  local i
  local cmd="printf '"
  for ((i=0; i<${#hex}; i+=2)); do
    cmd+="\\x${hex:i:2}"
  done
  cmd+="'"
  # Broker/SSH may close the socket; EPIPE must not abort under set -e.
  eval "$cmd" >&"$MQTT_FD" 2>/dev/null || return 1
}

mqtt_connect() {
  local host="$1" port="$2" client_id="$3" username="$4" password="$5"
  MQTT_FD=""
  MQTT_BUF_HEX=""
  APP_CONNECTED=0
  APP_ERROR=""

  mqtt_note "1/4 probing TCP ${host}:${port} (${MQTT_TCP_TIMEOUT}s)"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "$MQTT_TCP_TIMEOUT" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
      APP_ERROR="TCP timeout ${host}:${port} (${MQTT_TCP_TIMEOUT}s)"
      mqtt_note "stuck: TCP ${host}:${port} did not accept"
      APP_CONNECTED=0
      return 1
    fi
  fi

  mqtt_note "2/4 opening /dev/tcp/${host}/${port}"
  if ! exec {MQTT_FD}<>"/dev/tcp/${host}/${port}"; then
    APP_ERROR="cannot open /dev/tcp/${host}/${port}"
    mqtt_note "stuck: /dev/tcp open failed"
    APP_CONNECTED=0
    return 1
  fi

  local flags=0x02  # clean session; no will
  local payload=""
  payload+=$(mqtt_str_hex "$client_id")
  if [[ -n "$username" ]]; then
    flags=$((flags | 0x80))
    payload+=$(mqtt_str_hex "$username")
    if [[ -n "$password" ]]; then
      flags=$((flags | 0x40))
      payload+=$(mqtt_str_hex "$password")
    fi
  fi

  local vh=""
  vh+=$(mqtt_str_hex "MQTT")
  vh+="04"  # protocol level 4 = MQTT 3.1.1
  vh+=$(printf '%02x' "$flags")
  vh+=$(printf '%04x' "$MQTT_KEEPALIVE")

  local body="${vh}${payload}"
  local blen=$((${#body} / 2))
  local packet="10$(mqtt_rl_hex "$blen")${body}"
  mqtt_note "3/4 sending MQTT CONNECT (client ${client_id})"
  mqtt_write_hex "$packet" || {
    APP_ERROR="MQTT CONNECT write failed"
    mqtt_note "stuck: CONNECT write failed"
    APP_CONNECTED=0
    return 1
  }

  local deadline=$(( $(now_epoch) + 5 )) left
  while (( $(now_epoch) < deadline )); do
    (( APP_RUNNING )) || return 1
    left=$(( deadline - $(now_epoch) ))
    mqtt_note "3/4 waiting CONNACK (${left}s left)"
    mqtt_drain 0.2
    if declare -F poll_keys >/dev/null 2>&1; then
      poll_keys 0 || true
    fi
    if [[ "$APP_CONNECTED" -eq 1 ]]; then
      mqtt_note "4/4 SUBSCRIBE ${ARGS_TOPIC}"
      mqtt_subscribe "$ARGS_TOPIC"
      MQTT_LAST_PING=$(now_epoch)
      mqtt_note "listening ${ARGS_TOPIC}"
      return 0
    fi
    if [[ -n "$APP_ERROR" && "$APP_ERROR" == MQTT* ]]; then
      mqtt_note "stuck: ${APP_ERROR}"
      return 1
    fi
  done
  APP_ERROR="MQTT CONNACK timeout"
  mqtt_note "stuck: no CONNACK from ${host}:${port}"
  return 1
}

mqtt_subscribe() {
  local topic="$1"
  local pid=$MQTT_PACKET_ID
  MQTT_PACKET_ID=$(( (MQTT_PACKET_ID % 65535) + 1 ))
  local body
  body=$(printf '%04x' "$pid")
  body+=$(mqtt_str_hex "$topic")
  body+="00"  # QoS 0
  local blen=$((${#body} / 2))
  local packet="82$(mqtt_rl_hex "$blen")${body}"
  mqtt_write_hex "$packet" || return 1
}

mqtt_ping() {
  mqtt_write_hex "c000" || return 1
  MQTT_LAST_PING=$(now_epoch)
}

mqtt_disconnect() {
  if [[ -n "${MQTT_FD:-}" ]]; then
    mqtt_write_hex "e000" || true
    exec {MQTT_FD}>&- 2>/dev/null || true
    MQTT_FD=""
  fi
  APP_CONNECTED=0
}

# Read available bytes into MQTT_BUF_HEX. Prefer non-blocking dd so the
# UI loop is not stalled by timeout(1) + dd every frame.
mqtt_read_some() {
  local timeout="${1:-0}"
  [[ -n "${MQTT_FD:-}" ]] || return 1
  local data
  if [[ -z "${MQTT_HAS_NONBLOCK:-}" ]]; then
    if dd iflag=nonblock count=0 status=none </dev/null >/dev/null 2>&1; then
      MQTT_HAS_NONBLOCK=1
    else
      MQTT_HAS_NONBLOCK=0
    fi
  fi
  if [[ "$timeout" == "0" || "$timeout" == "0.0" ]]; then
    if (( MQTT_HAS_NONBLOCK )); then
      data=$(dd bs=8192 count=1 iflag=nonblock status=none <&"$MQTT_FD" 2>/dev/null | bin_to_hex)
    else
      data=$(timeout 0.01 dd bs=8192 count=1 status=none <&"$MQTT_FD" 2>/dev/null | bin_to_hex)
    fi
  elif command -v timeout >/dev/null 2>&1; then
    data=$(timeout "$timeout" dd bs=8192 count=1 status=none <&"$MQTT_FD" 2>/dev/null | bin_to_hex)
  else
    data=$(dd bs=8192 count=1 iflag=nonblock status=none <&"$MQTT_FD" 2>/dev/null | bin_to_hex)
  fi
  if [[ -n "$data" ]]; then
    MQTT_BUF_HEX+="$data"
    return 0
  fi
  return 1
}

# Decode remaining length starting at byte index; sets RL_VALUE RL_SIZE
mqtt_parse_rl() {
  local start="$1"
  local multiplier=1 value=0 encoded=0 pos=$start
  while :; do
    if (( pos >= ${#MQTT_BUF_HEX}/2 )); then
      return 1  # need more
    fi
    local off=$((pos * 2))
    encoded=$((16#${MQTT_BUF_HEX:off:2}))
    value=$(( value + (encoded & 127) * multiplier ))
    pos=$(( pos + 1 ))
    if (( (encoded & 128) == 0 )); then
      RL_VALUE=$value
      RL_SIZE=$((pos - start))
      return 0
    fi
    multiplier=$((multiplier * 128))
    if (( multiplier > 128*128*128 )); then
      return 2
    fi
  done
}

# Process complete packets in buffer; invoke mqtt_on_publish for PUBLISH.
# Cap work so retained Sparkplug floods cannot starve key handling.
mqtt_process_buffer() {
  local n=0
  while (( ${#MQTT_BUF_HEX} >= 4 )); do  # at least type + 1 rl byte
    (( APP_RUNNING )) || return 0
    local b0=$((16#${MQTT_BUF_HEX:0:2}))
    local ptype=$(( b0 >> 4 ))
    mqtt_parse_rl 1 || return 0
    local total=$((1 + RL_SIZE + RL_VALUE))
    if (( ${#MQTT_BUF_HEX}/2 < total )); then
      return 0  # incomplete
    fi
    local packet="${MQTT_BUF_HEX:0:$((total*2))}"
    MQTT_BUF_HEX="${MQTT_BUF_HEX:$((total*2))}"

    case "$ptype" in
      2)  # CONNACK
        local rc_off=$(( (1 + RL_SIZE + 1) * 2 ))
        local rc=$((16#${packet:rc_off:2}))
        if (( rc == 0 )); then
          APP_CONNECTED=1
          APP_ERROR=""
        else
          APP_CONNECTED=0
          APP_ERROR="MQTT connect failed (rc=$rc)"
        fi
        ;;
      3)  # PUBLISH
        mqtt_handle_publish "$packet" "$b0" "$RL_SIZE" "$RL_VALUE"
        ;;
      9)  # SUBACK — ignore
        ;;
      13) # PINGRESP — ignore
        ;;
      *)  # ignore others (never send PUBLISH ourselves)
        ;;
    esac
    n=$((n + 1))
    if (( n >= MQTT_MAX_PACKETS_PER_DRAIN )); then
      return 0
    fi
  done
}

mqtt_handle_publish() {
  local packet="$1" b0="$2" rl_size="$3" rl_value="$4"
  local qos=$(( (b0 >> 1) & 3 ))
  local pos=$((1 + rl_size))
  local off=$((pos * 2))
  local tlen=$((16#${packet:off:4}))
  pos=$((pos + 2))
  off=$((pos * 2))
  local topic_hex="${packet:off:$((tlen*2))}"
  pos=$((pos + tlen))
  # topic ascii
  local topic
  topic=$(printf '%s' "$topic_hex" | sed 's/\(..\)/\\x\1/g' | xargs -0 printf '%b' 2>/dev/null)
  if [[ -z "$topic" ]]; then
    topic=$(printf '%s' "$topic_hex" | awk '{
      s=""
      for(i=1;i<=length($0);i+=2){
        c=strtonum("0x" substr($0,i,2))
        if (c>=32 && c<127) s=s sprintf("%c",c)
      }
      printf "%s", s
    }')
  fi
  if (( qos > 0 )); then
    pos=$((pos + 2))  # packet id — we never respond (QoS0 subscribe)
  fi
  off=$((pos * 2))
  local payload_hex="${packet:off}"
  MQTT_PUBLISH_COUNT=$((MQTT_PUBLISH_COUNT + 1))
  mqtt_on_publish "$topic" "$payload_hex"
}

mqtt_drain() {
  local t="${1:-0}"
  [[ -n "${MQTT_FD:-}" ]] || return 0
  (( APP_RUNNING )) || return 0
  mqtt_process_buffer
  (( APP_RUNNING )) || return 0
  mqtt_read_some "$t" || true
  mqtt_process_buffer
  local now
  now=$(now_epoch)
  if (( APP_CONNECTED && now - MQTT_LAST_PING >= MQTT_KEEPALIVE - 5 )); then
    mqtt_ping || true
  fi
}

# Default handler — overridden by app.sh
mqtt_on_publish() {
  local topic="$1" payload_hex="$2"
  :
}
