#!/usr/bin/env bash
# ANSI terminal HMI — list selector + detail panels.

SCREEN_STARTED=0
TERM_COLS=100
TERM_ROWS=32

screen_enter() {
  if (( ! SCREEN_STARTED )); then
    # Home + per-line clear only. Avoid CSI 2J / 1049h: VS Code/plink
    # often shows a blank buffer after a full clear or alt screen.
    [[ -z "${TERM:-}" ]] && export TERM=xterm
    printf '%s' "$HIDE" 2>/dev/null || true
    SCREEN_STARTED=1
  fi
}

screen_leave() {
  if (( SCREEN_STARTED )); then
    SCREEN_STARTED=0
    # stdout may already be gone (Ctrl-C, plink, SSH hangup)
    printf '\n%s%s' "$SHOW" "$RESET" 2>/dev/null || true
  fi
}

screen_size() {
  local c r sz
  c="${COLUMNS:-}"
  r="${LINES:-}"
  if [[ -z "$c" || -z "$r" ]]; then
    sz=$(stty size 2>/dev/null || true)
    [[ -z "$r" ]] && r="${sz%% *}"
    [[ -z "$c" ]] && c="${sz##* }"
  fi
  c="${c:-80}"
  r="${r:-24}"
  [[ "$c" =~ ^[0-9]+$ ]] || c=80
  [[ "$r" =~ ^[0-9]+$ ]] || r=24
  (( c < 40 )) && c=40
  (( r < 8 )) && r=8
  TERM_COLS=$c
  TERM_ROWS=$r
}

# Redraw a fixed TERM_ROWS x TERM_COLS frame in place (no scroll).
screen_emit() {
  local -a body=("$@")
  local cols=$TERM_COLS rows=$TERM_ROWS
  local i ln
  printf '%s' "$HOME_C$HIDE" 2>/dev/null || return 0
  for ((i=0; i<rows; i++)); do
    ln="${body[i]:-}"
    printf '\r%s\033[K' "$(fit_text "$ln" "$cols")" 2>/dev/null || return 0
    if (( i < rows - 1 )); then
      printf '\n' 2>/dev/null || return 0
    fi
  done
}

screen_finish() {
  local cols="$1"
  local footer_help="$2"
  shift 2
  local -a lines=("$@")
  local rows=$TERM_ROWS
  local bar="${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}"
  local limit=$((rows - 2))
  (( limit < 1 )) && limit=1
  local -a body=("${lines[@]:0:$limit}")
  while ((${#body[@]} < limit)); do body+=(""); done
  body+=("$bar")
  body+=("$footer_help")
  screen_emit "${body[@]}"
}

box_top() { printf '%s┌%s┐%s' "$C_FRAME" "$(printf '─%.0s' $(seq 1 $(($1-2))))" "$RESET"; }
box_bot() { printf '%s└%s┘%s' "$C_FRAME" "$(printf '─%.0s' $(seq 1 $(($1-2))))" "$RESET"; }
box_line() {
  local width="$1" inner="$2"
  printf '%s│%s%s│%s' "$C_FRAME" "$(fit_text "$inner" $((width-2)))" "$C_FRAME" "$RESET"
}

screen_header() {
  local cols="$1" host="$2" port="$3" connected="$4" error="$5" demo="$6"
  local clock badge title broker right
  clock=$(date +'%I:%M:%S %p')
  if (( demo )); then
    badge="${C_AMBER}${BOLD} DEMO ${RESET}"
  elif [[ -n "$error" ]]; then
    badge="${C_BAD}${BOLD} FAULT ${RESET}"
  elif (( connected )); then
    badge="${C_OK}${BOLD} LIVE ${RESET}"
  else
    badge="${C_WARN}${BOLD} WAIT ${RESET}"
  fi
  title="${C_TITLE}${BOLD}  FOS  ${RESET}${C_HEAD}TUI${RESET}  ${C_MUTE}READ ONLY${RESET}"
  broker="${C_MUTE}mqtt://${host}:${port}${RESET}"
  pubs="${C_VALUE}${MQTT_PUBLISH_COUNT:-0}${RESET}${C_MUTE} pub${RESET}"
  right="${broker}   ${pubs}   ${badge}  ${C_VALUE}${clock}${RESET}"
  spread_text "$title" "$right" "$cols"
}

device_health() {
  local key="$1" now="$2"
  local last="${DEV_LAST[$key]:-0}"
  local age=$(( now - last ))
  if [[ "${DEV_ONLINE[$key]}" -ne 1 ]]; then
    printf '%s' "${C_BAD}OFFLINE${RESET}"
  elif (( last > 0 && age > STALE_AFTER )); then
    printf '%s' "${C_WARN}STALE ${age}s${RESET}"
  else
    printf '%s' "${C_OK}ONLINE${RESET}"
  fi
}

count_metrics() {
  local key="$1" n=0 mk
  for mk in "${!METRIC_VAL[@]}"; do
    [[ "$mk" == "$key|"* ]] && n=$((n + 1))
  done
  printf '%d' "$n"
}

pick_metric() {
  # sets PICK_NAME PICK_VAL PICK_UNIT PICK_TS or empties them
  local key="$1" slot="$2"
  PICK_NAME=""; PICK_VAL=""; PICK_UNIT=""; PICK_TS=""
  [[ -n "$key" ]] || return 1
  local mk name best_score=9999 best_name="" best_mk=""
  local n score
  for mk in "${!METRIC_SLOT[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    [[ "${METRIC_SLOT[$mk]}" == "$slot" ]] || continue
    name="${mk#*|}"
    n="$(norm_name "$name")"
    score=0
    [[ "$n" == *total* || "$n" == *sum* ]] && score=$((score-2))
    [[ "$n" == *avg* || "$n" == *average* ]] && score=$((score-1))
    local vre='(^| )(ab|bc|l1|a)($| )'
    if [[ "$slot" == v* ]] && [[ "$n" =~ $vre ]]; then
      score=$((score-1))
    fi
    if (( score < best_score )) || { (( score == best_score )) && [[ "$name" < "$best_name" ]]; }; then
      best_score=$score
      best_name="$name"
      best_mk="$mk"
    fi
  done
  if [[ -n "$best_mk" ]]; then
    PICK_NAME="$best_name"
    PICK_VAL="${METRIC_VAL[$best_mk]}"
    PICK_UNIT="${METRIC_UNIT[$best_mk]}"
    PICK_TS="${METRIC_TS[$best_mk]}"
    return 0
  fi
  return 1
}

metrics_in_slots() {
  # fills MET_LIST as name|val|unit|ts|slot sorted
  local key="$1"; shift
  MET_LIST=()
  [[ -n "$key" ]] || return 0
  local -A want=()
  local s mk name
  for s in "$@"; do want[$s]=1; done
  local -a rows=()
  for mk in "${!METRIC_SLOT[@]}"; do
    [[ "$mk" == "$key|"* ]] || continue
    s="${METRIC_SLOT[$mk]}"
    [[ -n "$s" && -n "${want[$s]+x}" ]] || continue
    name="${mk#*|}"
    rows+=("${s}|${name,,}|${name}|${METRIC_VAL[$mk]}|${METRIC_UNIT[$mk]}|${METRIC_TS[$mk]}")
  done
  if ((${#rows[@]})); then
    local line
    while IFS= read -r line; do
      # drop first two sort keys
      local rest="${line#*|}"
      rest="${rest#*|}"
      MET_LIST+=("$rest")
    done < <(printf '%s\n' "${rows[@]}" | sort)
  fi
}

kpi_tile() {
  # prints 4 lines for one tile into TILE_LINES
  local width="$1" label="$2" unit="$3" now="$4"
  local w=$width
  local top bot mid1 mid2 val shown u color
  top="${C_FRAME}┌$(printf '─%.0s' $(seq 1 $((w-2))))┐${RESET}"
  bot="${C_FRAME}└$(printf '─%.0s' $(seq 1 $((w-2))))┘${RESET}"
  mid1="${C_FRAME}│${RESET}$(fit_text "${C_LABEL}${label}${RESET}" $((w-2)))${C_FRAME}│${RESET}"
  if [[ -z "$PICK_NAME" ]]; then
    val="${C_MUTE}$(printf '%*s' $((w-8)) '—')${RESET} ${C_UNIT}${unit}${RESET}"
  else
    if (( now - ${PICK_TS:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
    shown=$(fmt_value "$PICK_VAL")
    u="${PICK_UNIT:-$unit}"
    val="${color}${BOLD}${shown}${RESET} ${C_UNIT}${u}${RESET}"
  fi
  mid2="${C_FRAME}│${RESET}$(fit_text "$val" $((w-2)))${C_FRAME}│${RESET}"
  TILE_LINES=("$top" "$mid1" "$mid2" "$bot")
}

draw_kpi_row() {
  local cols="$1" key="$2" now="$3"
  local slots=("AC POWER:pac:kW" "AC VOLTAGE:vac:V" "AC CURRENT:iac:A" "FREQUENCY:freq:Hz" "DC VOLTAGE:vdc:V")
  local n=${#slots[@]} gap=1
  local width=$(( (cols - gap*(n-1)) / n ))
  (( width < 14 )) && width=14
  local -a t0=() t1=() t2=() t3=()
  local item label slot unit gsp
  gsp=$(printf '%*s' "$gap" '')
  for item in "${slots[@]}"; do
    IFS=':' read -r label slot unit <<< "$item"
    pick_metric "$key" "$slot" || { PICK_NAME=""; }
    kpi_tile "$width" "$label" "$unit" "$now"
    t0+=("${TILE_LINES[0]}")
    t1+=("${TILE_LINES[1]}")
    t2+=("${TILE_LINES[2]}")
    t3+=("${TILE_LINES[3]}")
  done
  local out r
  for r in 0 1 2 3; do
    local -n arr="t$r"
    out="${arr[0]}"
    local k
    for ((k=1; k<${#arr[@]}; k++)); do
      out+="${gsp}${arr[$k]}"
    done
    KPI_LINES+=("$out")
  done
}

draw_list_panel() {
  local width="$1" title="$2" now="$3"
  # uses MET_LIST
  PANEL_LINES=()
  PANEL_LINES+=("$(box_top "$width")")
  PANEL_LINES+=("$(box_line "$width" " ${C_HEAD}${BOLD}${title}${RESET}")")
  PANEL_LINES+=("$(box_line "$width" " ${C_FRAME}$(printf '─%.0s' $(seq 1 $((width-4))))${RESET}")")
  local value_w=10 unit_w=4
  local name_w=$(( width - 2 - value_w - unit_w - 2 ))
  (( name_w < 8 )) && name_w=8
  local rows=("${MET_LIST[@]:0:8}")
  if ((${#rows[@]} == 0)); then rows=(""); fi
  local row name val unit ts color inner
  for row in "${rows[@]}"; do
    if [[ -z "$row" ]]; then
      inner=" ${C_MUTE}no tags yet${RESET}"
    else
      IFS='|' read -r name val unit ts <<< "$row"
      if (( now - ${ts:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
      inner=" $(fit_text "${C_LABEL}${name}${RESET}" "$name_w") $(fit_text "${color}$(fmt_value "$val")${RESET}" "$value_w") $(fit_text "${C_UNIT}${unit}${RESET}" "$unit_w")"
    fi
    PANEL_LINES+=("$(box_line "$width" "$inner")")
  done
}

screen_draw() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" mode="$7" selected="$8" cursor="$9"
  screen_size
  local cols=$TERM_COLS rows=$TERM_ROWS
  local -a lines=()

  if [[ "$mode" == "list" ]]; then
    screen_draw_list "$host" "$port" "$connected" "$error" "$demo" "$now" "$cursor" "$cols" "$rows"
    return
  fi
  case "${APP_VIEW:-}" in
    coresdu|sdu)
      screen_draw_coresdu "$host" "$port" "$connected" "$error" "$demo" "$now" "$selected" "$cols" "$rows"
      return
      ;;
    nodesdu)
      screen_draw_nodesdu "$host" "$port" "$connected" "$error" "$demo" "$now" "$selected" "$cols" "$rows"
      return
      ;;
    generic)
      screen_draw_generic "$host" "$port" "$connected" "$error" "$demo" "$now" "$selected" "$cols" "$rows"
      return
      ;;
  esac

  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  local bar="${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}"
  if [[ -z "$selected" || -z "${DEV_GROUP[$selected]+x}" ]]; then
    lines+=("$bar")
    lines+=("${C_MUTE}  Waiting for Sparkplug NBIRTH / DBIRTH …${RESET}")
  else
    local path health seq ntags
    path="${DEV_GROUP[$selected]} / ${DEV_NODE[$selected]}"
    [[ -n "${DEV_DEVICE[$selected]}" ]] && path+=" / ${DEV_DEVICE[$selected]}"
    health=$(device_health "$selected" "$now")
    if [[ -n "${DEV_SEQ[$selected]}" ]]; then seq="seq ${DEV_SEQ[$selected]}"; else seq="seq —"; fi
    ntags=$(count_metrics "$selected")
    lines+=("$bar")
    lines+=("$(spread_text "${C_LABEL}  DEVICE  ${RESET}${C_VALUE}${path}${RESET}   ${health}" "${C_MUTE}${seq}   ${ntags} tags${RESET}" "$cols")")
  fi
  lines+=("")

  KPI_LINES=()
  draw_kpi_row "$cols" "$selected" "$now"
  lines+=("${KPI_LINES[@]}")
  lines+=("")

  local gap=1 left_w right_w
  left_w=$(( (cols - gap) / 2 ))
  (( left_w < 28 )) && left_w=28
  right_w=$(( cols - left_w - gap ))
  metrics_in_slots "$selected" pdc vdc idc soc
  draw_list_panel "$left_w" "DC / BATTERY" "$now"
  local -a dc_lines=("${PANEL_LINES[@]}")
  metrics_in_slots "$selected" temp state
  draw_list_panel "$right_w" "THERMAL / STATE" "$now"
  local -a th_lines=("${PANEL_LINES[@]}")
  local h=${#dc_lines[@]}
  (( ${#th_lines[@]} > h )) && h=${#th_lines[@]}
  while ((${#dc_lines[@]} < h)); do dc_lines+=("$(box_line "$left_w" "")"); done
  while ((${#th_lines[@]} < h)); do th_lines+=("$(box_line "$right_w" "")"); done
  dc_lines[-1]="$(box_bot "$left_w")"
  th_lines[-1]="$(box_bot "$right_w")"
  local gsp i
  gsp=$(printf '%*s' "$gap" '')
  for ((i=0; i<h; i++)); do
    lines+=("${dc_lines[$i]}${gsp}${th_lines[$i]}")
  done
  lines+=("")

  # alarms
  metrics_in_slots "$selected" fault
  local alarm_txt color
  if ((${#MET_LIST[@]} == 0)); then
    alarm_txt="no active fault tags"
    color="$C_OK"
  else
    color="$C_BAD"
    alarm_txt=""
    local j=0 row name val
    for row in "${MET_LIST[@]}"; do
      j=$((j + 1)); (( j > 4 )) && break
      IFS='|' read -r name val _ <<< "$row"
      [[ -n "$alarm_txt" ]] && alarm_txt+=", "
      alarm_txt+="${name}=$(fmt_value "$val")"
    done
  fi
  lines+=("${C_LABEL}  ALARMS  ${RESET}${color}${alarm_txt}${RESET}")
  local seen=""
  local k
  for k in "${DEV_ORDER[@]}"; do
    [[ -n "$seen" ]] && seen+=", "
    seen+="$k"
  done
  [[ -z "$seen" ]] && seen="—"
  lines+=("${C_MUTE}  nodes seen: ${seen}${RESET}")
  lines+=("")

  # other tags
  local -a others=()
  if [[ -n "$selected" ]]; then
    local mk name
    for mk in "${!METRIC_SLOT[@]}"; do
      [[ "$mk" == "$selected|"* ]] || continue
      [[ -z "${METRIC_SLOT[$mk]}" ]] || continue
      name="${mk#*|}"
      others+=("${name,,}|${name}|${METRIC_VAL[$mk]}|${METRIC_UNIT[$mk]}|${METRIC_TS[$mk]}")
    done
  fi
  if ((${#others[@]})); then
    lines+=("${C_LABEL}  OTHER TAGS${RESET}")
    local sorted_o line name val unit ts
    mapfile -t sorted_o < <(printf '%s\n' "${others[@]}" | sort | head -6)
    for line in "${sorted_o[@]}"; do
      IFS='|' read -r _ name val unit ts <<< "$line"
      if (( now - ${ts:-0} > STALE_AFTER )); then color="$C_MUTE"; else color="$C_VALUE"; fi
      lines+=("    ${C_LABEL}$(printf '%-28s' "$name")${RESET} ${color}$(printf '%10s' "$(fmt_value "$val")")${RESET} ${C_UNIT}${unit}${RESET}")
    done
  fi

  screen_finish "$cols" "${C_MUTE}  Esc list · q quit · EPC M10 · tags from DBIRTH/DDATA · READ ONLY${RESET}" "${lines[@]}"
}

edge_health() {
  local ekey="$1" now="$2"
  local last="${EDGE_LAST[$ekey]:-0}"
  local age=$(( now - last ))
  if (( last <= 0 )); then
    printf '%s' "${C_MUTE}WAIT${RESET}"
  elif (( age > STALE_AFTER )); then
    printf '%s' "${C_WARN}STALE ${age}s${RESET}"
  else
    printf '%s' "${C_OK}LIVE${RESET}"
  fi
}

list_node_cell() {
  local key="$1" now="$2" cursor="$3" idx="$4" width="$5"
  local last age state sc mark name
  last="${EDGE_LAST[$key]:-0}"
  age=$(( now - last ))
  if (( last <= 0 )); then
    state="WAIT"; sc="$C_MUTE"
  elif (( age > STALE_AFTER )); then
    state="STALE"; sc="$C_WARN"
  else
    state="LIVE"; sc="$C_OK"
  fi
  if (( idx == cursor )); then mark="${C_AMBER}${BOLD}▶${RESET}"; else mark=" "; fi
  name="${key#*/}"
  parse_node_name "$name"
  fit_text " ${mark} ${C_VALUE}${name}${RESET} ${C_LABEL}$(role_label "$NN_KIND")${RESET} ${sc}${state}${RESET}" "$width"
}

screen_draw_list() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" cursor="$7" cols="$8" rows="$9"
  list_nodes
  local -a lines=()
  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  lines+=("${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}")

  local live=0 stale=0
  local key age last
  for key in "${BROWSE_KEYS[@]}"; do
    last="${EDGE_LAST[$key]:-0}"
    age=$(( now - last ))
    if (( last > 0 && age > STALE_AFTER )); then
      stale=$((stale + 1))
    else
      live=$((live + 1))
    fi
  done
  lines+=("$(spread_text "${C_LABEL}  MQTT NODES${RESET}  ${C_MUTE}detection order · static${RESET}" "${C_OK}${live} live${RESET}  ${C_WARN}${stale} stale${RESET}  ${C_VALUE}${#BROWSE_KEYS[@]} total${RESET}" "$cols")")

  local header=3 footer=2 gap=2 min_cell=22
  local inner=$(( rows - header - footer ))
  (( inner < 1 )) && inner=1
  local total=${#BROWSE_KEYS[@]}
  local ncols=1 nrows=$inner
  if (( total > 0 )); then
    ncols=$(( (total + inner - 1) / inner ))
    (( ncols < 1 )) && ncols=1
    local max_cols=$(( (cols + gap) / (min_cell + gap) ))
    (( max_cols < 1 )) && max_cols=1
    (( ncols > max_cols )) && ncols=$max_cols
    nrows=$(( (total + ncols - 1) / ncols ))
    (( nrows > inner )) && nrows=$inner
  fi
  local cell_w=$cols
  if (( ncols > 1 )); then
    cell_w=$(( (cols - gap * (ncols - 1)) / ncols ))
  fi
  (( cell_w < 8 )) && cell_w=8
  local gsp=""
  (( gap > 0 )) && gsp=$(printf '%*s' "$gap" '')

  if (( total == 0 )); then
    local wait=""
    if [[ -n "$error" ]]; then
      wait="  ${error}"
    elif [[ -n "${APP_STATUS:-}" ]]; then
      wait="  ${APP_STATUS}"
    elif (( ! connected && ! demo )); then
      wait="  connecting to broker …"
    else
      wait="  waiting for Sparkplug publishes …"
    fi
    if [[ -n "$error" ]]; then
      lines+=("${C_BAD}${wait}${RESET}")
    else
      lines+=("${C_MUTE}${wait}${RESET}")
    fi
  else
    local r c idx out
    for ((r=0; r<nrows; r++)); do
      out=""
      for ((c=0; c<ncols; c++)); do
        idx=$(( c * nrows + r ))
        if (( c > 0 )); then out+="$gsp"; fi
        if (( idx < total )); then
          out+="$(list_node_cell "${BROWSE_KEYS[$idx]}" "$now" "$cursor" "$idx" "$cell_w")"
        else
          out+="$(fit_text "" "$cell_w")"
        fi
      done
      lines+=("$out")
    done
    if (( total > nrows * ncols )); then
      lines[-1]="$(fit_text "${lines[-1]} ${C_MUTE}+$(( total - nrows * ncols )) more${RESET}" "$cols")"
    fi
  fi

  screen_finish "$cols" "${C_MUTE}  ↑↓ / j k move · Enter open HMI · Esc back · q quit · READ ONLY${RESET}" "${lines[@]}"
}

print_simple_frame() {
  local cols="$1"
  shift
  screen_finish "$cols" "${C_MUTE}  Esc list · q quit · READ ONLY${RESET}" "$@"
}

screen_draw_coresdu() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" selected="$7" cols="$8" rows="$9"
  local -a lines=()
  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  lines+=("${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}")
  local ekey="${APP_SELECTED_EDGE:-}"
  local node="${ekey#*/}"
  parse_node_name "$node"
  local structure="array ${NN_ARRAY:-—} · core ${NN_CORE:-—} · $(role_label "$NN_KIND")"
  if [[ -z "$selected" || -z "${DEV_GROUP[$selected]+x}" ]]; then
    lines+=("${C_LABEL}  CORE SDU  ${RESET}${C_VALUE}${node:-—}${RESET}   ${C_MUTE}CoreSDU HMI${RESET}")
    lines+=("${C_MUTE}  ${structure}${RESET}")
    lines+=("${C_MUTE}  waiting for CoreSDU metrics …${RESET}")
  else
    local path health hb
    path="${DEV_GROUP[$selected]} / ${DEV_NODE[$selected]}"
    [[ -n "${DEV_DEVICE[$selected]}" ]] && path+=" / ${DEV_DEVICE[$selected]}"
    health=$(device_health "$selected" "$now")
    hb="$(heartbeat_value "$selected" || true)"
    [[ -z "$hb" ]] && hb="—"
    lines+=("$(spread_text "${C_LABEL}  CORE SDU  ${RESET}${C_VALUE}${path}${RESET}   ${health}" "${C_MUTE}Core_hb${RESET}" "$cols")")
    lines+=("${C_MUTE}  ${structure}${RESET}")
    lines+=("")
    lines+=("$(box_top "$cols")")
    lines+=("$(box_line "$cols" "  ${C_LABEL}heartbeat (Core_hb)${RESET}")")
    lines+=("$(box_line "$cols" "  ${C_VALUE}$(fmt_value "$hb")${RESET}")")
    lines+=("$(box_bot "$cols")")
  fi
  print_simple_frame "$cols" "${lines[@]}"
}

screen_draw_nodesdu() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" selected="$7" cols="$8" rows="$9"
  local -a lines=()
  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  lines+=("${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}")
  local ekey="${APP_SELECTED_EDGE:-}"
  local node="${ekey#*/}"
  parse_node_name "$node"
  local structure="array ${NN_ARRAY:-—} · core ${NN_CORE:-—} · node ${NN_NODE:-—} · $(role_label "$NN_KIND")"
  if [[ -z "$selected" || -z "${DEV_GROUP[$selected]+x}" ]]; then
    lines+=("${C_LABEL}  NODE SDU  ${RESET}${C_VALUE}${node:-—}${RESET}   ${C_MUTE}NodeSDU HMI${RESET}")
    lines+=("${C_MUTE}  ${structure}${RESET}")
    lines+=("${C_MUTE}  waiting for NodeSDU metrics …${RESET}")
  else
    local path health ntags
    path="${DEV_GROUP[$selected]} / ${DEV_NODE[$selected]}"
    [[ -n "${DEV_DEVICE[$selected]}" ]] && path+=" / ${DEV_DEVICE[$selected]}"
    health=$(device_health "$selected" "$now")
    ntags=$(count_metrics "$selected")
    lines+=("$(spread_text "${C_LABEL}  NODE SDU  ${RESET}${C_VALUE}${path}${RESET}   ${health}" "${C_MUTE}${ntags} tags${RESET}" "$cols")")
    lines+=("${C_MUTE}  ${structure}${RESET}")
    lines+=("")
    lines+=("$(box_top "$cols")")
    lines+=("$(box_line "$cols" "  ${C_LABEL}node${RESET}  ${C_VALUE}${NN_NODE:-—}${RESET}   ${C_LABEL}core${RESET}  ${C_VALUE}${NN_CORE:-—}${RESET}")")
    lines+=("$(box_line "$cols" "  ${C_MUTE}NodeSDU panel · Esc returns to list${RESET}")")
    lines+=("$(box_bot "$cols")")
  fi
  print_simple_frame "$cols" "${lines[@]}"
}

screen_draw_generic() {
  local host="$1" port="$2" connected="$3" error="$4" demo="$5" now="$6" selected="$7" cols="$8" rows="$9"
  local -a lines=()
  lines+=("$(screen_header "$cols" "$host" "$port" "$connected" "$error" "$demo")")
  lines+=("${C_FRAME}$(printf '─%.0s' $(seq 1 "$cols"))${RESET}")
  local ekey="${APP_SELECTED_EDGE:-}"
  local node="${ekey#*/}"
  parse_node_name "$node"
  local structure="array ${NN_ARRAY:-—} · core ${NN_CORE:-—} · node ${NN_NODE:-—} · $(role_label "$NN_KIND")"
  lines+=("${C_LABEL}  NODE  ${RESET}${C_VALUE}${node:-—}${RESET}   ${C_MUTE}no type-specific HMI${RESET}")
  lines+=("${C_MUTE}  ${structure}${RESET}")
  if [[ -n "$selected" && -n "${DEV_GROUP[$selected]+x}" ]]; then
    lines+=("$(spread_text "${C_LABEL}  DEVICE  ${RESET}${C_VALUE}${DEV_GROUP[$selected]} / ${DEV_NODE[$selected]} / ${DEV_DEVICE[$selected]:-}${RESET}" "$(device_health "$selected" "$now")" "$cols")")
    lines+=("${C_MUTE}  tags $(count_metrics "$selected") · msgs ${EDGE_MSGS[$ekey]:-0}${RESET}")
  else
    lines+=("${C_MUTE}  msgs ${EDGE_MSGS[$ekey]:-0} · waiting for birth/data …${RESET}")
  fi
  print_simple_frame "$cols" "${lines[@]}"
}
