#!/usr/bin/env bash
# dm-dl.sh - per-download wrapper for the Omarchy Download Manager plugin.
#
# One detached process per download. `start` re-executes itself as a session
# leader (survives `omarchy restart shell`), spawns aria2c `setsid`-free in a
# fifo pipeline, parses aria2's summary via dm-status.awk and writes a small
# JSON status file into $XDG_RUNTIME_DIR/omarchy-download-manager.
#
# Pause/resume are SIGSTOP/SIGCONT on the aria2c pid (simple, per-file);
# cancel marks a flag and kills both the downloader and this wrapper. Resume
# after interruption is handled by aria2's --continue + .aria2 control file.
#
# Usage:
#   dm-dl.sh start  <id> <url> <dir> <filename> <segments> <speedBps>
#   dm-dl.sh run    <id> <url> <dir> <filename> <segments> <speedBps>   (internal)
#   dm-dl.sh pause  <id>
#   dm-dl.sh resume <id>
#   dm-dl.sh cancel <id>
#   dm-dl.sh cancel-all
#   dm-dl.sh remove <id> <dir> <filename>   (terminates and deletes the file + history)
#   dm-dl.sh is-running <id>
#   dm-dl.sh cleanup <id...>   (known ids; kill + drop everything else in runtime)

set -u

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$PLUGIN_DIR/dm-status.awk"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/omarchy-download-manager"

die() {
  echo "dm-dl.sh: $*" >&2
  exit 1
}

write_status() {
  local id="$1" state="$2" done="$3" total="$4" pct="$5" spd="$6" eta="$7" err="$8"
  local f="$RUNTIME/$id.status.json"
  local t="$f.tmp"
  printf '{"id":"%s","state":"%s","completed":%s,"total":%s,"percent":%s,"speed":%s,"eta":%s,"error":"%s"}' \
    "$id" "$state" "$done" "$total" "$pct" "$spd" "$eta" "$err" > "$t"
  mv -f "$t" "$f"
}

read_int() {
  local f="$1" name="$2"
  sed -n "s/.*\"$name\":\s*\([0-9-]*\).*/\1/p" "$f" | head -n1
}

aria2_rc_msg() {
  local rc="$1"
  case "$rc" in
    1) echo "unknown error" ;;
    2) echo "timeout" ;;
    3) echo "resource not found (404)" ;;
    4) echo "file size exceeds the set limit" ;;
    5) echo "transfer speed too slow" ;;
    6) echo "network problem" ;;
    7) echo "canceled" ;;
    8) echo "server file changed too quickly / logic conflict" ;;
    11) echo "disk full / cannot write" ;;
    12) echo "checksum mismatch" ;;
    *) echo "aria2 exit code $rc" ;;
  esac
}

cmd_start() {
  [[ $# -ge 6 ]] || die "start requires <id> <url> <dir> <filename> <segments> <speedBps>"
  local id="$1"
  mkdir -p "$RUNTIME"
  rm -f "$RUNTIME/$id.cancelled"
  setsid bash "$0" run "$@" >> "$RUNTIME/$id.wrapper.log" 2>&1 &
  exit 0
}

cmd_run() {
  [[ $# -ge 6 ]] || die "run requires <id> <url> <dir> <filename> <segments> <speedBps>"
  local id="$1" url="$2" dir="$3" file="$4" segments="$5" speed="$6"
  mkdir -p "$RUNTIME" 2>/dev/null
  mkdir -p "$dir" 2>/dev/null
  echo "$$" > "$RUNTIME/$id.wrapper.pid"

  write_status "$id" active 0 0 -1 0 -1 ""

  if ! command -v aria2c >/dev/null 2>&1; then
    write_status "$id" error 0 0 -1 0 -1 "aria2c is not installed (omarchy pkg add aria2)"
    echo "aria2c is not installed" >&2
    exit 1
  fi

  [[ $segments =~ ^[0-9]+$ ]] || segments=8
  [[ $speed =~ ^[0-9]+$ ]] || speed=0
  local speed_arg="0"
  if (( speed > 0 )); then speed_arg="$(( speed / 1024 ))K"; fi

  local opts=(
    --dir="$dir"
    --out="$file"
    --continue=true
    --allow-overwrite=false
    --auto-file-renaming=false
    --file-allocation=none
    --summary-interval=1
    --console-log-level=warn
    -x "$( [ "$segments" -lt 16 ] && echo "$segments" || echo 16 )"
    -s "$segments"
    --max-download-limit="$speed_arg"
    --max-overall-download-limit=0
    --max-concurrent-downloads=1
    --connect-timeout=30
    --timeout=120
  )

  # If the target already exists on disk without a resume control file, never
  # overwrite it: report a collision so the panel can renumber and re-queue.
  # A partial download (control file present) resumes as usual.
  local collided=0
  if [[ -f "$dir/$file" && ! -e "$dir/$file.aria2" ]]; then
    collided=1
  fi

  local fifo="$RUNTIME/$id.out"
  local apid="" parser_pid="" rc=0
  if (( collided == 0 )); then
    rm -f "$fifo"
    mkfifo "$fifo"

    aria2c "${opts[@]}" "$url" > "$fifo" 2>&1 &
    apid=$!
    echo "$apid" > "$RUNTIME/$id.aria2.pid"

    gawk -v id="$id" -v out="$RUNTIME/$id.status.json" -v dir="$dir" -v file="$file" \
      -f "$PARSER" < "$fifo" &
    parser_pid=$!

    wait "$apid"
    rc=$?

    kill "$parser_pid" 2>/dev/null
    wait "$parser_pid" 2>/dev/null
    rm -f "$fifo"
  else
    rc=3
  fi

  local state="error"
  local msg=""
  case "$rc" in
    0) state="completed" ;;
    *) state="error"; msg=$(aria2_rc_msg "$rc") ;;
  esac
  if (( collided == 1 )); then
    state="error"
    msg="file already exists"
  fi
  if [[ -f "$RUNTIME/$id.cancelled" ]]; then
    state="cancelled"
    msg=""
  fi

  local done="" total="" pct=""
  local sf="$RUNTIME/$id.status.json"
  if [[ $state == "completed" ]]; then
    done=$(stat -c %s "$dir/$file" 2>/dev/null || echo 0)
    total=$done
    pct=100
  else
    [[ -f "$sf" ]] && {
      done=$(read_int "$sf" completed); total=$(read_int "$sf" total); pct=$(read_int "$sf" percent)
    }
  fi
  done=${done:-0}; total=${total:-0}; pct=${pct:--1}
  if [[ $state != "completed" && $total -le 0 ]]; then total=$done; fi

  write_status "$id" "$state" "$done" "$total" "$pct" 0 -1 "$msg"

  if command -v notify-send >/dev/null 2>&1; then
    if [[ $state == "completed" ]]; then
      notify-send -a "Download Manager" -i "emblem-downloads" "Download complete" "$file" 2>/dev/null || true
    elif [[ $state == "error" ]]; then
      notify-send -a "Download Manager" -i "dialog-error" "Download failed" "$file — $msg" 2>/dev/null || true
    fi
  fi

  rm -f "$RUNTIME/$id.wrapper.pid" "$RUNTIME/$id.aria2.pid" "$RUNTIME/$id.out"
  exit 0
}

cmd_pause() {
  local id="$1" p
  p=$(cat "$RUNTIME/$id.aria2.pid" 2>/dev/null || true)
  [[ -n "$p" ]] && kill -STOP "$p" 2>/dev/null || true
}

cmd_resume() {
  local id="$1" p
  p=$(cat "$RUNTIME/$id.aria2.pid" 2>/dev/null || true)
  [[ -n "$p" ]] && kill -CONT "$p" 2>/dev/null || true
}

cmd_cancel() {
  local id="$1" ap wp
  touch "$RUNTIME/$id.cancelled" 2>/dev/null || true
  ap=$(cat "$RUNTIME/$id.aria2.pid" 2>/dev/null || true)
  wp=$(cat "$RUNTIME/$id.wrapper.pid" 2>/dev/null || true)
  [[ -n "$ap" ]] && kill "$ap" 2>/dev/null || true
  [[ -n "$wp" ]] && kill "$wp" 2>/dev/null || true
}

cmd_cancel_all() {
  for f in "$RUNTIME"/*.aria2.pid; do
    [[ -f "$f" ]] || continue
    local id
    id=$(basename "$f" .aria2.pid)
    cmd_cancel "$id"
  done
}

cmd_is_running() {
  local id="$1" wp
  wp=$(cat "$RUNTIME/$id.wrapper.pid" 2>/dev/null || true)
  if [[ -n "$wp" ]] && kill -0 "$wp" 2>/dev/null; then exit 0; fi
  exit 1
}

cmd_cleanup() {
  # Known ids are entries still tracked in the queue; everything else found in
  # the runtime dir is an orphan from a removed entry: stop + kill its aria2/
  # wrapper processes and remove their state files. Files downloaded to disk
  # are never touched.
  local known=""
  local a
  for a in "$@"; do known="$known $a "; done
  local id="" p=""
  for f in "$RUNTIME"/*.aria2.pid "$RUNTIME"/*.wrapper.pid; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    id="${id%.aria2.pid}"
    id="${id%.wrapper.pid}"
    case "$known" in *" $id "*) continue ;; esac
    p=$(cat "$f" 2>/dev/null || true)
    [[ -n "$p" ]] && { kill -CONT "$p" 2>/dev/null || true; kill -9 "$p" 2>/dev/null || true; }
    rm -f "$RUNTIME/$id.aria2.pid" "$RUNTIME/$id.wrapper.pid"
  done
  for f in "$RUNTIME"/*.status.json "$RUNTIME"/*.cancelled "$RUNTIME"/*.out "$RUNTIME"/*.wrapper.log; do
    [ -e "$f" ] || continue
    id="${f##*/}"
    id="${id%.status.json}"
    id="${id%.cancelled}"
    id="${id%.out}"
    id="${id%.wrapper.log}"
    case "$known" in *" $id "*) continue ;; esac
    rm -f "$f"
  done
}

cmd_remove() {
  [[ $# -ge 3 ]] || die "remove requires <id> <dir> <file>"
  local id="$1" dir="$2" file="$3"
  local ap wp
  ap=$(cat "$RUNTIME/$id.aria2.pid" 2>/dev/null || true)
  wp=$(cat "$RUNTIME/$id.wrapper.pid" 2>/dev/null || true)
  [[ -n "$ap" ]] && kill "$ap" 2>/dev/null || true
  [[ -n "$wp" ]] && kill "$wp" 2>/dev/null || true
  [[ -n "$dir" && "$dir" != "/" && -n "$file" && "$file" != */* ]] || return 1
  rm -f -- "$dir/$file" "$dir/$file.aria2"
  rm -f "$RUNTIME/$id.status.json" "$RUNTIME/$id.cancelled" \
        "$RUNTIME/$id.wrapper.pid" "$RUNTIME/$id.aria2.pid" "$RUNTIME/$id.out" 2>/dev/null || true
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  run) shift; cmd_run "$@" ;;
  pause) shift; cmd_pause "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  cancel-all) cmd_cancel_all ;;
  remove) shift; cmd_remove "$@" ;;
  is-running) shift; cmd_is_running "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  *) die "usage: $0 {start|run|pause|resume|cancel|cancel-all|is-running|cleanup}" ;;
esac