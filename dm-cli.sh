#!/usr/bin/env bash
# dm-cli.sh - command-line front end for the Download Manager plugin.
#
# Installed by the plugin service as `~/.local/bin/omarchy-dl`. It never mutates
# the queue itself: it appends JSON request lines to
#   $XDG_RUNTIME_DIR/omarchy-download-manager/cli.jsonl
# which the running DownloadManager service consumes, so there is no write race
# with the panel. `list` reads queue.json directly for offline output.
#
# Usage:
#   omarchy-dl <url> [--dir D] [--segments N] [--speed KB]   add a download
#   omarchy-dl list
#   omarchy-dl pause <id> | resume <id> | cancel <id> | retry <id>
#   omarchy-dl open <id>
#   omarchy-dl clear
#   omarchy-dl help

set -uo pipefail

PLUGIN_ID="omakid.download-manager"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/omarchy-download-manager"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/$PLUGIN_ID"
QUEUE="$CONFIG_DIR/queue.json"
CLI_JSONL="$RUNTIME/cli.jsonl"
LAST_REQ=""

now_ms() {
  date +%s%3N
}

encode() {
  printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'
}

request() {
  local op="$1"
  shift
  local payload="{\"op\":\"$op\",\"ts\":$(now_ms)"
  local key val
  while (( $# > 0 )); do
    key="${1#--}"; shift
    val="$1"; shift
    case "$key" in
      url|dir|id|filename) payload="$payload,$(encode "$key"):$(encode "$val")" ;;
      segments|speed) payload="$payload,$(encode "$key"):$((val))" ;;
    esac
  done
  payload="$payload}"
  mkdir -p "$RUNTIME"
  printf '%s\n' "$payload" >> "$CLI_JSONL"
  LAST_REQ="$payload"
}

print_state_label() {
  case "$1" in
    active) echo "active" ;;
    paused) echo "paused" ;;
    queued) echo "queued" ;;
    completed) echo "done" ;;
    error) echo "failed" ;;
    cancelled) echo "canceled" ;;
    *) echo "$1" ;;
  esac
}

cmd_list() {
  [[ -f "$QUEUE" ]] || { echo "No downloads yet."; exit 0; }
  python3 - "$QUEUE" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    print("No downloads yet.")
    sys.exit(0)
labels = {"active":"active","paused":"paused","queued":"queued","completed":"done","error":"failed","cancelled":"canceled"}
rows = data.get("downloads", [])
if not rows:
    print("No downloads yet.")
    sys.exit(0)
for r in rows:
    st = r.get("state","queued")
    print(f"{r.get('id','?'):<20} {labels.get(st,st):<10} {r.get('filename',''):<40} {r.get('url','')}")
PY
}

cmd_add() {
  local url="${1:-}"
  [[ -n "$url" ]] || { echo "Usage: omarchy-dl <url> [--dir D] [--segments N] [--speed KB]" >&2; exit 1; }
  shift
  request "add" url "$url" "$@"
  echo "Add request sent: $url"
}

cmd_action() {
  local op="$1" id="${2:-}"
  [[ -n "$id" ]] || { echo "omarchy-dl: $op requires <id>" >&2; exit 1; }
  request "$op" id "$id"
  echo "$op request sent for $id"
}

case "${1:-}" in
  ""|help|-h|--help)
    cat <<'EOF'
Download Manager CLI — omarchy-dl

  omarchy-dl <url> [--dir D] [--segments N] [--speed KB]   add a download
  omarchy-dl list
  omarchy-dl pause <id> | resume <id> | cancel <id> | retry <id>
  omarchy-dl open <id>
  omarchy-dl clear

Examples:
  omarchy-dl "https://example.com/file.iso"
  omarchy-dl "https://example.com/file.iso" --dir ~/Downloads --segments 8
EOF
    exit 0
    ;;
  list) cmd_list ;;
  clear) request "clear"; echo "Clear command sent." ;;
  open) cmd_action "open" "${2:-}" ;;
  pause) cmd_action "pause" "${2:-}" ;;
  resume) cmd_action "resume" "${2:-}" ;;
  cancel) cmd_action "cancel" "${2:-}" ;;
  retry) cmd_action "retry" "${2:-}" ;;
  *)
    if [[ "$1" == --* || "$1" == - ]]; then
      echo "Invalid URL: $1" >&2; exit 1
    fi
    cmd_add "$@"
    ;;
esac