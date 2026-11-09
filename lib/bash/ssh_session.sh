#!/usr/bin/env bash
# Interactive SSH helpers for enclosure-mfr-report. Never persist secrets.
# Source this file; do not execute.

SSH_HOST=""
SSH_USER=""
SSH_PORT=22
SSH_TIMEOUT=30
SSH_INSECURE_HOST_KEY=0
SSH_PASSWORD=""

ssh_session_require_tty() {
  if [[ ! -t 0 || ! -t 2 ]]; then
    printf '%s: password prompt requires a TTY\n' "${PROG:-enclosure-mfr-report}" >&2
    return 1
  fi
  return 0
}

# Prompt for username (if empty) and password. Password is kept in SSH_PASSWORD
# only for the collect process; caller must ssh_session_clear.
ssh_session_prompt() {
  if [[ -z "${SSH_USER}" ]]; then
    ssh_session_require_tty || return 1
    printf 'SSH username: ' >&2
    IFS= read -r SSH_USER || return 1
    [[ -n "${SSH_USER}" ]] || { printf '%s: username is required\n' "${PROG:-enclosure-mfr-report}" >&2; return 1; }
  fi
  ssh_session_require_tty || return 1
  printf 'SSH password: ' >&2
  IFS= read -r -s SSH_PASSWORD || return 1
  printf '\n' >&2
  [[ -n "${SSH_PASSWORD}" ]] || { printf '%s: password is required\n' "${PROG:-enclosure-mfr-report}" >&2; return 1; }
  return 0
}

ssh_session_clear() {
  unset SSH_PASSWORD SSHPASS
  SSH_PASSWORD=""
}

ssh_session_opts() {
  local -a opts=(
    -o "ConnectTimeout=${SSH_TIMEOUT}"
    -o NumberOfPasswordPrompts=1
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o LogLevel=ERROR
    -o BatchMode=no
    -p "${SSH_PORT}"
  )
  if [[ "${SSH_INSECURE_HOST_KEY}" -eq 1 ]]; then
    opts+=(
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o GlobalKnownHostsFile=/dev/null
    )
  fi
  printf '%s\n' "${opts[@]}"
}

# Run a remote command. Uses sshpass -e with SSH_PASSWORD. Does not echo secrets.
ssh_session_run() {
  command -v ssh >/dev/null 2>&1 || { printf '%s: ssh is required\n' "${PROG:-enclosure-mfr-report}" >&2; return 1; }
  command -v sshpass >/dev/null 2>&1 || { printf '%s: sshpass is required for password authentication\n' "${PROG:-enclosure-mfr-report}" >&2; return 1; }
  local -a opts=()
  mapfile -t opts < <(ssh_session_opts)
  SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${opts[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

# Stream remote tar of *.log under remote_root to stdout (binary).
ssh_session_tar_logs() {
  local remote_root="$1"
  local remote
  remote=$(cat <<EOF
set -euo pipefail
test -d $(printf '%q' "$remote_root") || { echo "${PROG:-enclosure-mfr-report}: missing remote root" >&2; exit 2; }
cd $(printf '%q' "$remote_root")
find . -type f -name '*.log' | tar -czf - -T -
EOF
)
  ssh_session_run "$remote"
}
