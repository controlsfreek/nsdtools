#!/usr/bin/env bash
# Shared constants, ANSI palette, CLI parsing, device state helpers.

STALE_AFTER=60

RESET=$'\033[0m'
BOLD=$'\033[1m'
HIDE=$'\033[?25l'
SHOW=$'\033[?25h'
ALT_ON=$'\033[?1049h'
ALT_OFF=$'\033[?1049l'
HOME_C=$'\033[H'
CLEAR=$'\033[2J'
CLEAR_DOWN=$'\033[J'

C_FRAME=$'\033[38;5;24m'
C_TITLE=$'\033[38;5;159m'
C_LABEL=$'\033[38;5;109m'
C_VALUE=$'\033[38;5;230m'
C_UNIT=$'\033[38;5;66m'
C_OK=$'\033[38;5;84m'
C_WARN=$'\033[38;5;220m'
C_BAD=$'\033[38;5;203m'
C_MUTE=$'\033[38;5;59m'
C_AMBER=$'\033[38;5;178m'
C_HEAD=$'\033[38;5;81m'

# Device / metric state (associative)
declare -A DEV_GROUP DEV_NODE DEV_DEVICE DEV_ONLINE DEV_LAST DEV_SEQ DEV_IS_M10 DEV_IS_BMS DEV_IS_SDU DEV_BORN
declare -A METRIC_VAL METRIC_UNIT METRIC_SLOT METRIC_TS
declare -A ALIAS_MAP
declare -A EDGE_SEEN EDGE_LAST EDGE_MSGS EDGE_DEVICE
declare -a DEV_ORDER=()
declare -a EDGE_NODES=()
declare -a EDGE_ORDER=()
declare -a BROWSE_KEYS=()
declare -a INVERTERS=()
declare -a SDUS=()

ARGS_HOST="10.0.0.3"
ARGS_PORT=1883
ARGS_GROUP=""
ARGS_NODE=""
ARGS_DEVICE=""
ARGS_USERNAME=""
ARGS_PASSWORD=""
ARGS_CLIENT_ID="nsdtools-fos-tui"
ARGS_TOPIC="spBv1.0/#"
ARGS_DEMO=0

APP_CONNECTED=0
APP_ERROR=""
APP_STATUS=""
APP_RUNNING=1
APP_MODE="list"
APP_SELECTED=""
APP_SELECTED_EDGE=""
APP_VIEW=""
APP_KEY=""
APP_CURSOR=0

now_epoch() { date +%s; }
now_epoch_ms() { date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

# Sparkplug node names encode site structure:
#   A_C001_N001_SDU    array A, core 1, node 1, Software Dispatch Unit
#   A_C001_N001_DAC01  array A, core 1, node 1, DAC (PCS / inverter)
#   A_C001_SDU         array A, core 1, SDU
#   A_SDU / A_MDU / A  array-level
# Globals: NN_ARRAY NN_CORE NN_NODE NN_ROLE NN_UNIT NN_KIND
parse_node_name() {
  local name="$1" t
  NN_ARRAY=""; NN_CORE=""; NN_NODE=""; NN_ROLE=""; NN_UNIT=""; NN_KIND="other"
  local IFS='_'
  local -a tok=()
  read -ra tok <<< "$name"
  for t in "${tok[@]}"; do
    if [[ "$t" =~ ^[A-Za-z]$ ]]; then
      NN_ARRAY="${t^^}"
    elif [[ "$t" =~ ^[Cc]0*([0-9]+)$ ]]; then
      NN_CORE="${BASH_REMATCH[1]}"
    elif [[ "$t" =~ ^[Nn]0*([0-9]+)$ ]]; then
      NN_NODE="${BASH_REMATCH[1]}"
    elif [[ "$t" =~ ^[Ss][Dd][Uu]$ ]]; then
      NN_ROLE="SDU"; NN_UNIT="SDU"; NN_KIND="sdu"
    elif [[ "$t" =~ ^[Dd][Aa][Cc]0*([0-9]+)$ ]]; then
      NN_ROLE="DAC"; NN_UNIT="DAC${BASH_REMATCH[1]}"; NN_KIND="dac"
    elif [[ "$t" =~ ^[Mm][Dd][Uu]$ ]]; then
      NN_ROLE="MDU"; NN_UNIT="MDU"; NN_KIND="mdu"
    elif [[ "$t" =~ ^[Oo][Cc][Tt][Ee]0*([0-9]+)$ ]]; then
      NN_ROLE="OCTE"; NN_UNIT="OCTE${BASH_REMATCH[1]}"; NN_KIND="octe"
    fi
  done
  if [[ -z "$NN_ROLE" && -n "$NN_ARRAY" && -z "$NN_CORE" && -z "$NN_NODE" ]]; then
    NN_ROLE="ARRAY"; NN_UNIT="$NN_ARRAY"; NN_KIND="array"
  fi
  if [[ "$NN_KIND" == "sdu" ]]; then
    if [[ -n "$NN_NODE" ]]; then
      NN_KIND="nodesdu"
    elif [[ -n "$NN_CORE" ]]; then
      NN_KIND="coresdu"
    else
      NN_KIND="arraysdu"
    fi
  fi
}

role_label() {
  case "${1:-}" in
    dac) printf 'DAC/PCS' ;;
    nodesdu) printf 'NODE SDU' ;;
    coresdu) printf 'CORE SDU' ;;
    arraysdu) printf 'ARRAY SDU' ;;
    sdu) printf 'SDU' ;;
    mdu) printf 'MDU' ;;
    octe) printf 'OCTE' ;;
    array) printf 'ARRAY' ;;
    *) printf '%s' "${1:-—}" ;;
  esac
}

norm_name() {
  local s="${1,,}"
  s="${s//[^a-z0-9]/ }"
  s="${s//  / }"
  s="${s## }"; s="${s%% }"
  printf '%s' "$s"
}

classify_slot() {
  local n; n="$(norm_name "$1")"
  [[ -z "$n" ]] && { printf ''; return; }
  local re
  re='(fault|trip|alarm|error|warn)'
  if [[ "$n" =~ $re ]]; then printf 'fault'; return; fi
  re='(^| )(state|status|mode|run|online|enabled)($| )'
  if [[ "$n" =~ $re ]]; then printf 'state'; return; fi
  re='(soc|state of charge)'
  if [[ "$n" =~ $re ]]; then printf 'soc'; return; fi
  re='(temp|temperature|heatsink|coolant|igbt)'
  if [[ "$n" =~ $re ]]; then printf 'temp'; return; fi
  re='(freq|frequency|hertz|(^| )hz($| ))'
  if [[ "$n" =~ $re ]]; then printf 'freq'; return; fi
  re='(dc).*(volt|vdc)|(^| )vdc($| )|dc voltage'
  if [[ "$n" =~ $re ]]; then printf 'vdc'; return; fi
  re='(dc).*(curr|amp|idc)|(^| )idc($| )|dc current'
  if [[ "$n" =~ $re ]]; then printf 'idc'; return; fi
  re='(dc).*(power|kw|watt)|(^| )pdc($| )|dc power'
  if [[ "$n" =~ $re ]]; then printf 'pdc'; return; fi
  re='(ac).*(volt|vac)|volt|vab|vbc|vca|van|vbn|vcn|(^| )vac($| )'
  if [[ "$n" =~ $re ]]; then printf 'vac'; return; fi
  re='(ac).*(curr|amp)|current|(^| )iac($| )|(^| )amps?($| )'
  if [[ "$n" =~ $re ]]; then printf 'iac'; return; fi
  re='(active|real|output|ac)? ?power|(^| )pac($| )|(^| )kw($| )|(^| )kwe($| )'
  if [[ "$n" =~ $re ]]; then printf 'pac'; return; fi
  printf ''
}

infer_unit() {
  local slot="$1" name="$2" value="$3"
  local n; n="$(norm_name "$name")"
  if [[ "$n" == *kw* && "$n" != *kvar* && "$n" != *kva* ]]; then printf 'kW'; return; fi
  if [[ "$n" == *kvar* ]]; then printf 'kVAr'; return; fi
  if [[ "$n" == *kva* ]]; then printf 'kVA'; return; fi
  if [[ "$slot" == "vac" || "$slot" == "vdc" || "$n" == *volt* ]]; then printf 'V'; return; fi
  if [[ "$slot" == "iac" || "$slot" == "idc" || "$n" == *curr* || "$n" == *amp* ]]; then printf 'A'; return; fi
  if [[ "$slot" == "freq" || "$n" == *hz* ]]; then printf 'Hz'; return; fi
  if [[ "$slot" == "temp" || "$n" == *temp* ]]; then printf '°C'; return; fi
  if [[ "$slot" == "soc" ]]; then printf '%%'; return; fi
  if [[ "$slot" == "pac" || "$slot" == "pdc" ]]; then printf 'kW'; return; fi
  if [[ "$value" == "true" || "$value" == "false" ]]; then printf ''; return; fi
  printf ''
}

fmt_value() {
  local value="$1"
  if [[ -z "$value" || "$value" == "null" ]]; then printf '—'; return; fi
  if [[ "$value" == "true" ]]; then printf 'ON'; return; fi
  if [[ "$value" == "false" ]]; then printf 'OFF'; return; fi
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$value"
    return
  fi
  if [[ "$value" =~ ^-?[0-9]*\.[0-9]+$ || "$value" =~ ^-?[0-9]+\.[0-9]*$ ]]; then
    awk -v v="$value" 'BEGIN{
      av = (v<0)?-v:v
      if (av >= 1000) printf "%.1f", v
      else if (av >= 100) printf "%.1f", v
      else if (av >= 10) printf "%.2f", v
      else printf "%.3f", v
    }'
    return
  fi
  printf '%s' "$value"
}

ensure_device() {
  local key="$1" group="$2" node="$3" device="${4:-}"
  if [[ -z "${DEV_GROUP[$key]+x}" ]]; then
    DEV_GROUP[$key]="$group"
    DEV_NODE[$key]="$node"
    DEV_DEVICE[$key]="$device"
    DEV_ONLINE[$key]=0
    DEV_LAST[$key]=0
    DEV_SEQ[$key]=""
    DEV_IS_M10[$key]=0
    DEV_IS_BMS[$key]=0
    DEV_IS_SDU[$key]=0
    DEV_BORN[$key]=0
    DEV_ORDER+=("$key")
  fi
}

metric_key() { printf '%s|%s' "$1" "$2"; }

upsert_metric() {
  local key="$1" name="$2" value="$3" ts="$4"
  local slot unit mk
  slot="$(classify_slot "$name")"
  unit="$(infer_unit "$slot" "$name" "$value")"
  mk="$(metric_key "$key" "$name")"
  METRIC_VAL[$mk]="$value"
  METRIC_UNIT[$mk]="$unit"
  METRIC_SLOT[$mk]="$slot"
  METRIC_TS[$mk]="$ts"
}

resolve_name() {
  local key="$1" alias="$2" name="$3"
  if [[ -n "$name" ]]; then
    if [[ -n "$alias" ]]; then
      ALIAS_MAP["$key|$alias"]="$name"
    fi
    printf '%s' "$name"
    return
  fi
  if [[ -n "$alias" ]]; then
    printf '%s' "${ALIAS_MAP[$key|$alias]:-}"
    return
  fi
  printf ''
}

metric_name_contains() {
  local key="$1" needle="${2,,}" mk name
  for mk in "${!METRIC_VAL[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    name="${mk#*|}"
    [[ "${name,,}" == *"$needle"* ]] && return 0
  done
  return 1
}

identify_m10() {
  # Inverters publish a metric whose name contains inverter01.
  metric_name_contains "$1" "inverter01"
}

identify_bms() {
  # BMS publishes a metric whose name contains BankBMS.
  metric_name_contains "$1" "bankbms"
}
identify_sdu() {
  # CoreSDU devices publish a metric whose name contains CoreSDU.
  metric_name_contains "$1" "coresdu"
}

classify_device() {
  local key="$1"
  if identify_m10 "$key"; then
    DEV_IS_M10[$key]=1
  else
    DEV_IS_M10[$key]=0
  fi
  if identify_bms "$key"; then
    DEV_IS_BMS[$key]=1
  else
    DEV_IS_BMS[$key]=0
  fi
  if identify_sdu "$key"; then
    DEV_IS_SDU[$key]=1
  else
    DEV_IS_SDU[$key]=0
  fi
  if [[ "$APP_MODE" == "detail" && -z "$APP_SELECTED" && -n "$ARGS_DEVICE" ]]; then
    if [[ "${DEV_DEVICE[$key]}" == "$ARGS_DEVICE" || "${DEV_NODE[$key]}" == "$ARGS_DEVICE" ]]; then
      APP_SELECTED="$key"
    fi
  fi
}

heartbeat_name() {
  local key="$1" mk name
  for mk in "${!METRIC_VAL[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    name="${mk#*|}"
    if [[ "${name,,}" == *core_hb* ]]; then
      printf '%s' "$name"
      return 0
    fi
  done
  printf ''
  return 1
}

heartbeat_value() {
  local key="$1" name
  name="$(heartbeat_name "$key")" || true
  if [[ -z "$name" ]]; then
    printf ''
    return 1
  fi
  printf '%s' "${METRIC_VAL[$(metric_key "$key" "$name")]:-}"
}

record_edge_node() {
  local group="$1" node="$2" device="${3:-}" now="${4:-$(now_epoch)}"
  [[ -n "$node" ]] || return 0
  [[ "$group" == "STATE" ]] && return 0
  local key="${group}/${node}"
  if [[ -z "${EDGE_SEEN[$key]+x}" ]]; then
    EDGE_ORDER+=("$key")
  fi
  EDGE_SEEN[$key]=1
  EDGE_LAST[$key]="$now"
  EDGE_MSGS[$key]=$(( ${EDGE_MSGS[$key]:-0} + 1 ))
  if [[ -n "$device" && -z "${EDGE_DEVICE[$key]:-}" ]]; then
    EDGE_DEVICE[$key]="$device"
  fi
}

list_edge_nodes() {
  EDGE_NODES=()
  local key group node
  local -a pairs=()
  for key in "${!EDGE_SEEN[@]}"; do
    group="${key%%/*}"
    node="${key#*/}"
    parse_node_name "$node"
    pairs+=("$(printf '%s|%s|%05d|%05d|%s|%s' "${group,,}" "${NN_ARRAY:-}" "${NN_CORE:-0}" "${NN_NODE:-0}" "${NN_KIND}" "$key")")
  done
  if ((${#pairs[@]})); then
    local sorted line
    mapfile -t sorted < <(printf '%s\n' "${pairs[@]}" | sort)
    for line in "${sorted[@]}"; do
      EDGE_NODES+=("${line##*|}")
    done
  fi
}

dump_edge_nodes() {
  list_edge_nodes
  local key group node role
  printf 'EDGE_NODES %d\n' "${#EDGE_NODES[@]}"
  printf 'C=Core  N=Node  SDU=Software Dispatch Unit  DAC=PCS/inverter\n'
  printf '%-12s %-6s %-6s %-6s %-8s %-24s %-8s %s\n' GROUP ARRAY CORE NODE ROLE NODE_NAME MSGS LAST
  for key in "${EDGE_NODES[@]}"; do
    group="${key%%/*}"
    node="${key#*/}"
    parse_node_name "$node"
    role="$(role_label "$NN_KIND")"
    printf '%-12s %-6s %-6s %-6s %-8s %-24s %-8s %s\n' \
      "$group" "${NN_ARRAY:-—}" "${NN_CORE:-—}" "${NN_NODE:-—}" "$role" "$node" \
      "${EDGE_MSGS[$key]:-0}" "${EDGE_LAST[$key]:-0}"
  done
}

list_nodes() {
  BROWSE_KEYS=("${EDGE_ORDER[@]}")
}

select_device_for_edge() {
  local ekey="$1"
  local group="${ekey%%/*}" node="${ekey#*/}"
  local key best=""
  parse_node_name "$node"
  for key in "${DEV_ORDER[@]}"; do
    [[ "${DEV_GROUP[$key]}" == "$group" && "${DEV_NODE[$key]}" == "$node" ]] || continue
    if [[ "${DEV_IS_M10[$key]:-0}" -eq 1 ]]; then
      printf '%s' "$key"
      return 0
    fi
    if [[ "${DEV_IS_SDU[$key]:-0}" -eq 1 ]]; then
      best="$key"
      continue
    fi
    [[ -z "$best" ]] && best="$key"
  done
  printf '%s' "$best"
}

view_for_edge() {
  local ekey="$1" dkey="${2:-}"
  local node="${ekey#*/}"
  parse_node_name "$node"
  # Node-name tokens win for SDU/PCS routing (Enter from the list).
  case "$NN_KIND" in
    dac) printf 'm10'; return ;;
    nodesdu) printf 'nodesdu'; return ;;
    coresdu|arraysdu|sdu) printf 'coresdu'; return ;;
  esac
  if [[ -n "$dkey" && "${DEV_IS_M10[$dkey]:-0}" -eq 1 ]]; then printf 'm10'; return; fi
  if [[ -n "$dkey" && "${DEV_IS_SDU[$dkey]:-0}" -eq 1 ]]; then printf 'coresdu'; return; fi
  if [[ -n "$dkey" && "${DEV_IS_BMS[$dkey]:-0}" -eq 1 ]]; then printf 'generic'; return; fi
  printf 'generic'
}

# Populate INVERTERS array with M10 keys sorted by device/node (BMS excluded)
list_inverters() {
  INVERTERS=()
  local key name
  local -a pairs=()
  for key in "${DEV_ORDER[@]}"; do
    [[ "${DEV_IS_M10[$key]}" -eq 1 ]] || continue
    [[ "${DEV_IS_BMS[$key]:-0}" -eq 1 ]] && continue
    name="${DEV_DEVICE[$key]:-${DEV_NODE[$key]}}"
    pairs+=("${name,,}|$key")
  done
  if ((${#pairs[@]})); then
    local sorted
    mapfile -t sorted < <(printf '%s\n' "${pairs[@]}" | sort)
    for name in "${sorted[@]}"; do
      INVERTERS+=("${name#*|}")
    done
  fi
}

list_sdus() {
  SDUS=()
  local key name
  local -a pairs=()
  for key in "${DEV_ORDER[@]}"; do
    [[ "${DEV_IS_SDU[$key]:-0}" -eq 1 ]] || continue
    name="${DEV_DEVICE[$key]:-${DEV_NODE[$key]}}"
    parse_node_name "${DEV_NODE[$key]}"
    pairs+=("$(printf '%s|%05d|%05d|%s|%s' "${NN_ARRAY:-}" "${NN_CORE:-0}" "${NN_NODE:-0}" "${name,,}" "$key")")
  done
  if ((${#pairs[@]})); then
    local sorted line
    mapfile -t sorted < <(printf '%s\n' "${pairs[@]}" | sort)
    for line in "${sorted[@]}"; do
      SDUS+=("${line##*|}")
    done
  fi
}

parse_args() {
  ARGS_HOST="${FOS_TUI_MQTT_HOST:-${M10_MQTT_HOST:-${CORE_SDU_MQTT_HOST:-10.0.0.3}}}"
  ARGS_PORT="${FOS_TUI_MQTT_PORT:-${M10_MQTT_PORT:-${CORE_SDU_MQTT_PORT:-1883}}}"
  ARGS_GROUP="${FOS_TUI_SPARKPLUG_GROUP:-${M10_SPARKPLUG_GROUP:-${CORE_SDU_SPARKPLUG_GROUP:-}}}"
  ARGS_NODE="${FOS_TUI_SPARKPLUG_NODE:-${M10_SPARKPLUG_NODE:-${CORE_SDU_SPARKPLUG_NODE:-}}}"
  ARGS_DEVICE="${FOS_TUI_SPARKPLUG_DEVICE:-${M10_SPARKPLUG_DEVICE:-${CORE_SDU_SPARKPLUG_DEVICE:-}}}"
  ARGS_USERNAME="${FOS_TUI_MQTT_USERNAME:-${M10_MQTT_USERNAME:-${CORE_SDU_MQTT_USERNAME:-}}}"
  ARGS_PASSWORD="${FOS_TUI_MQTT_PASSWORD:-${M10_MQTT_PASSWORD:-${CORE_SDU_MQTT_PASSWORD:-}}}"
  ARGS_CLIENT_ID="${FOS_TUI_MQTT_CLIENT_ID:-${M10_MQTT_CLIENT_ID:-nsdtools-fos-tui}}"
  ARGS_TOPIC="spBv1.0/#"
  ARGS_DEMO=0

  while (($#)); do
    case "$1" in
      --host) ARGS_HOST="$2"; shift 2 ;;
      --port) ARGS_PORT="$2"; shift 2 ;;
      --group) ARGS_GROUP="$2"; shift 2 ;;
      --node) ARGS_NODE="$2"; shift 2 ;;
      --device) ARGS_DEVICE="$2"; shift 2 ;;
      --username) ARGS_USERNAME="$2"; shift 2 ;;
      --password) ARGS_PASSWORD="$2"; shift 2 ;;
      --client-id) ARGS_CLIENT_ID="$2"; shift 2 ;;
      --topic) ARGS_TOPIC="$2"; shift 2 ;;
      --demo) ARGS_DEMO=1; shift ;;
      -h|--help)
        cat <<'HELP'
Usage: fos-tui [--demo] [--host HOST] [--port PORT] [options]

Read-only Fluence OS terminal HMI (Sparkplug B over MQTT).
Lists MQTT edge nodes as they publish. Enter opens the HMI for that
device type (DAC/PCS → EPC M10, SDU → CoreSDU heartbeat).

Subscribes only; never publishes.

  --demo                 Simulate mixed SDU / DAC / BMS fleet
  --host HOST            MQTT broker (default 10.0.0.3, or FOS_TUI_MQTT_HOST)
  --port PORT            MQTT port (default 1883)
  --group/--node/--device Sparkplug filters
  --username/--password  MQTT auth
  --client-id ID         MQTT client id
  --topic TOPIC          Subscribe topic (default spBv1.0/#)
HELP
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -n "$ARGS_DEVICE" ]]; then
    APP_MODE="detail"
  else
    APP_MODE="list"
  fi
}

vis_len() {
  # visible length ignoring ANSI CSI ... m
  local s="$1" n=0 i=0
  local len=${#s}
  while ((i < len)); do
    if [[ "${s:i:1}" == $'\033' ]]; then
      local rest="${s:i}"
      local j="${rest%%m*}"
      if [[ "$j" == "$rest" ]]; then
        i=$(( i + 1 ))
      else
        i=$((i + ${#j} + 1))
      fi
      continue
    fi
    n=$((n + 1)); i=$((i + 1))
  done
  printf '%d' "$n"
}

fit_text() {
  local text="$1" width="$2"
  local out="" visible=0 i=0
  local len=${#text}
  while ((i < len && visible < width)); do
    if [[ "${text:i:1}" == $'\033' ]]; then
      local rest="${text:i}"
      local j="${rest%%m*}"
      if [[ "$j" == "$rest" ]]; then
        break
      fi
      out+="${text:i:$((${#j}+1))}"
      i=$((i + ${#j} + 1))
      continue
    fi
    out+="${text:i:1}"
    visible=$((visible + 1)); i=$((i + 1))
  done
  while ((visible < width)); do
    out+=" "
    visible=$(( visible + 1 ))
  done
  printf '%s%s' "$out" "$RESET"
}

spread_text() {
  local left="$1" right="$2" cols="$3"
  local lv rv pad
  lv=$(vis_len "$left")
  rv=$(vis_len "$right")
  pad=$((cols - lv - rv))
  ((pad < 1)) && pad=1
  fit_text "${left}$(printf '%*s' "$pad" '')${right}" "$cols"
}
