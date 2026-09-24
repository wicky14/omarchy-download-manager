#!/usr/bin/env bash
# clipwatch.sh - clipboard watcher for the Download Manager plugin.
#
# Watches the Wayland clipboard (via wl-paste --watch) and appends detected
# http/https URLs to:
#   $XDG_RUNTIME_DIR/omarchy-download-manager/clipboard.jsonl
# one JSON object per line. The QML service tails this file and shows a quick
# "add?" prompt in the panel (never auto-starts a download).
#
# Usage:
#   clipwatch.sh start      detach the watcher
#   clipwatch.sh stop
#   clipwatch.sh run        internal loop
#   clipwatch.sh is-running

set -u

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/omarchy-download-manager"

cmd_run() {
  command -v wl-paste >/dev/null 2>&1 || exit 1
  mkdir -p "$RUNTIME"

  export CW_RUNTIME="$RUNTIME"
  wl-paste --type text --watch bash -c '
    IFS= read -r line
    url=$(printf "%s" "$line" | grep -oE "https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%[\]-]+" | head -n1)
    [ -n "$url" ] || exit 0
    last=""
    [ -f "$CW_RUNTIME/clipwatch.last" ] && last=$(cat "$CW_RUNTIME/clipwatch.last" 2>/dev/null || true)
    [ "$url" = "$last" ] && exit 0
    printf "%s\n" "$url" > "$CW_RUNTIME/clipwatch.last"
    now=$(date +%s)
    {
      printf '"'"'{"url":"%s","time":%s}\n'"'"' "$url" "$now"
    } >> "$CW_RUNTIME/clipboard.jsonl"
  '
}

cmd_start() {
  command -v wl-paste >/dev/null 2>&1 || {
    echo "clipwatch.sh: wl-paste not found (install wl-clipboard)" >&2
    exit 1
  }
  mkdir -p "$RUNTIME"
  if cmd_is_running; then
    echo "clipwatch.sh: already running"
    exit 0
  fi
  setsid bash "$0" run >> "$RUNTIME/clipwatch.log" 2>&1 &
  echo "$!" > "$RUNTIME/clipwatch.pid"
  echo "clipwatch.sh: started"
  exit 0
}

cmd_stop() {
  local pid
  pid=$(cat "$RUNTIME/clipwatch.pid" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$RUNTIME/clipwatch.pid" "$RUNTIME/clipwatch.last"
  echo "clipwatch.sh: stopped"
  exit 0
}

cmd_is_running() {
  local pid
  pid=$(cat "$RUNTIME/clipwatch.pid" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  return 1
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  run) cmd_run ;;
  is-running) if cmd_is_running; then exit 0; else exit 1; fi ;;
  *) echo "usage: $0 {start|stop|run|is-running}" >&2; exit 1 ;;
esac