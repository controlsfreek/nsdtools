#!/usr/bin/env bash
# Collect enclosure *.log files, rename by c/n/r/e from the path, write a manifest.
# Source this file; do not execute.

# Parse c/n/r/e integers from a path. Rightmost token of each letter wins.
# Sets PATH_C PATH_N PATH_R PATH_E (empty if missing). Returns 0 if e is set.
parse_path_c_n_r_e() {
  local path="$1"
  PATH_C=""; PATH_N=""; PATH_R=""; PATH_E=""
  local token letter digits
  local matches
  matches="$(printf '%s' "$path" | grep -oE '[Cc][0-9]+|[Nn][0-9]+|[Rr][0-9]+|[Ee][0-9]+' || true)"
  while IFS= read -r token || [[ -n "$token" ]]; do
    [[ -z "$token" ]] && continue
    letter="${token:0:1}"
    digits="${token:1}"
    digits=$((10#$digits))
    case "${letter,,}" in
      c) PATH_C="$digits" ;;
      n) PATH_N="$digits" ;;
      r) PATH_R="$digits" ;;
      e) PATH_E="$digits" ;;
    esac
  done <<<"$matches"
  [[ -n "$PATH_E" ]]
}

# Zero-pad rename: cCCC_nNNN_rRR_eEE_<basename>
format_renamed_log() {
  local c="${1:-0}" n="${2:-0}" r="${3:-0}" e="${4:-0}" base="$5"
  printf 'c%03d_n%03d_r%02d_e%02d_%s' "$((10#$c))" "$((10#$n))" "$((10#$r))" "$((10#$e))" "$base"
}

already_renamed_log() {
  local base
  base="$(basename "$1")"
  [[ "$base" =~ ^c[0-9]+_n[0-9]+_r[0-9]+_e[0-9]+_ ]]
}

unique_dest_name() {
  local dir="$1" name="$2"
  local base="${name%.log}"
  local candidate="$name" i=2
  while [[ -e "${dir}/${candidate}" ]]; do
    candidate="${base}__${i}.log"
    i=$((i + 1))
  done
  printf '%s' "$candidate"
}

file_mtime_iso() {
  local f="$1"
  if date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ
    return
  fi
  if stat -c %Y "$f" >/dev/null 2>&1; then
    date -u -d "@$(stat -c %Y "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf ''
    return
  fi
  printf ''
}

# Copy/rename *.log from src tree into dest. Append manifest lines.
# Manifest columns (tab): source dest status c n r e size mtime
collect_from_dir() {
  local src="$1" dest="$2" manifest="$3"
  mkdir -p "$dest"
  if [[ ! -f "$manifest" ]]; then
    printf 'source\tdest\tstatus\tc\tn\tr\te\tsize\tmtime\n' >"$manifest"
  fi
  local f base destname size mtime status
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    size="$(wc -c <"$f" | tr -d ' ')"
    mtime="$(file_mtime_iso "$f")"
    if already_renamed_log "$f"; then
      destname="$(unique_dest_name "$dest" "$base")"
      cp "$f" "${dest}/${destname}"
      parse_path_c_n_r_e "$base" || true
      printf '%s\t%s\tok\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$f" "$destname" "${PATH_C:-}" "${PATH_N:-}" "${PATH_R:-}" "${PATH_E:-}" "$size" "$mtime" >>"$manifest"
      continue
    fi
    if ! parse_path_c_n_r_e "$f"; then
      printf '%s\t-\tskipped:no-e\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$f" "${PATH_C:-}" "${PATH_N:-}" "${PATH_R:-}" "${PATH_E:-}" "$size" "$mtime" >>"$manifest"
      continue
    fi
    destname="$(format_renamed_log "${PATH_C:-0}" "${PATH_N:-0}" "${PATH_R:-0}" "${PATH_E}" "$base")"
    destname="$(unique_dest_name "$dest" "$destname")"
    cp "$f" "${dest}/${destname}"
    printf '%s\t%s\tok\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$f" "$destname" "${PATH_C}" "${PATH_N:-}" "${PATH_R:-}" "${PATH_E}" "$size" "$mtime" >>"$manifest"
  done < <(find "$src" -type f -name '*.log' -print0)
}

unpack_package() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  tar -xzf "$archive" -C "$dest"
}

pack_package() {
  local src="$1" archive="$2"
  tar -czf "$archive" -C "$src" .
}
