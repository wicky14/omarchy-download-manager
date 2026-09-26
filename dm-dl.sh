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
# Pids are kept in `$RUNTIME/<id>.aria2.pid` / `$RUNTIME/<id>.wrapper.pid`, one
# `<pid> <starttime>` record per line. Every signal re-checks that the pid still
# has that start time and the expected process identity before it is sent, so a
# record left behind by a crash or a pid reuse can never reach an unrelated
# process.
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
SCRIPT_NAME="${0##*/}"
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

# ---- process records -------------------------------------------------------
# Every download keeps two records, one line each, written when its process is
# spawned: "<pid> <starttime>". starttime is field 22 of /proc/<pid>/stat (ticks
# since boot); together with the pid it names exactly one process, so a record
# left behind by a crash or a reboot can never match the process that inherited
# the number. No signal is ever sent to a pid whose record does not verify.

proc_starttime() {
  local p="$1" st
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  st=$(cat "/proc/$p/stat" 2>/dev/null) || return 1
  [[ -n "$st" ]] || return 1
  st=${st##*') '}
  # shellcheck disable=SC2086
  set -- $st # fields 3.. of stat, so starttime is the 20th of these
  [[ $# -ge 20 ]] || return 1
  printf '%s' "${20}"
}

write_pid_rec() {
  local f="$1" p="$2" st=""
  local t="$f.tmp"
  st=$(proc_starttime "$p" 2>/dev/null) || st=""
  printf '%s %s\n' "$p" "$st" > "$t" 2>/dev/null && mv -f "$t" "$f"
}

# Checks a record against the live process table.
#   exit 0  verified, stdout is "<pid> <starttime>"
#   exit 1  no record, or the process it names is gone
#   exit 2  record present but not trustworthy: the pid belongs to a different
#           process, or the record carries no start time to compare
pid_rec_live() {
  local f="$1" kind="$2" id="$3" rec="" p st
  local -a argv=()
  local i
  [[ -f "$f" ]] || return 1
  IFS= read -r rec < "$f" 2>/dev/null || return 1
  read -r p st <<< "$rec"
  case "$p" in
    ''|*[!0-9]*)
      echo "dm-dl.sh: $id: refusing to signal: malformed record $f" >&2
      return 2
      ;;
  esac
  [[ -d "/proc/$p" ]] || return 1
  if [[ "$kind" == "aria2" ]]; then
    if [[ "$(cat "/proc/$p/comm" 2>/dev/null)" != "aria2c" ]]; then
      echo "dm-dl.sh: $id: refusing to signal pid $p: not aria2c" >&2
      return 2
    fi
  else
    # The wrapper is always "<bash> <path>/dm-dl.sh run <id> <url> ...". Match
    # whole argv words so any spelling of the path still identifies it, and the
    # id proves which download it belongs to.
    mapfile -d '' -t argv < "/proc/$p/cmdline" 2>/dev/null || true
    for ((i = 0; i + 2 < ${#argv[@]}; i++)); do
      [[ "${argv[i]##*/}" == "$SCRIPT_NAME" ]] || continue
      [[ "${argv[i + 1]}" == "run" && "${argv[i + 2]}" == "$id" ]] && break
    done
    if ((i + 2 >= ${#argv[@]})); then
      echo "dm-dl.sh: $id: refusing to signal pid $p: not this download's wrapper" >&2
      return 2
    fi
  fi
  if [[ -z "$st" ]]; then
    echo "dm-dl.sh: $id: refusing to signal pid $p: record has no start time" >&2
    return 2
  fi
  if [[ "$(proc_starttime "$p" 2>/dev/null)" != "$st" ]]; then
    echo "dm-dl.sh: $id: refusing to signal pid $p: pid was reused by another process" >&2
    return 2
  fi
  printf '%s %s' "$p" "$st"
}

# signal_pid_rec <file> <aria2|wrapper> <id> <signal>...
# Signals only while the record verifies. A record that does not is dropped
# instead, so a stale one can never be used again, and the reason is reported on
# stderr by pid_rec_live.
signal_pid_rec() {
  local f="$1" kind="$2" id="$3"
  shift 3
  local live="" p st rc=0
  live=$(pid_rec_live "$f" "$kind" "$id") || rc=$?
  if (( rc != 0 )); then
    rm -f "$f"
    return "$rc"
  fi
  read -r p st <<< "$live"
  kill "$@" -- "$p" 2>/dev/null || true
  return 0
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
  write_pid_rec "$RUNTIME/$id.wrapper.pid" "$$"

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
    write_pid_rec "$RUNTIME/$id.aria2.pid" "$apid"

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
  local id="$1"
  signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -STOP
}

cmd_resume() {
  local id="$1"
  signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -CONT
}

cmd_cancel() {
  local id="$1"
  touch "$RUNTIME/$id.cancelled" 2>/dev/null || true
  signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -TERM
  signal_pid_rec "$RUNTIME/$id.wrapper.pid" wrapper "$id" -TERM
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
  local id="$1"
  pid_rec_live "$RUNTIME/$id.wrapper.pid" wrapper "$id" >/dev/null || exit 1
  exit 0
}

cmd_cleanup() {
  # Known ids are entries still tracked in the queue; everything else found in
  # the runtime dir is an orphan from a removed entry: stop + kill its aria2/
  # wrapper processes and remove their state files. Files downloaded to disk
  # are never touched. A pid is only signalled while its record still verifies,
  # so an orphan left by a crash can never hit an unrelated process.
  local known=""
  local a
  for a in "$@"; do known="$known $a "; done
  local seen="$known"
  local id="" f=""
  for f in "$RUNTIME"/*.aria2.pid "$RUNTIME"/*.wrapper.pid; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    id="${id%.aria2.pid}"
    id="${id%.wrapper.pid}"
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    # CONT first so a stopped download can act on the KILL that follows. Each
    # record is dropped as soon as it fails to verify, which also makes the
    # second call for the same record a no-op.
    signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -CONT
    signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -KILL
    signal_pid_rec "$RUNTIME/$id.wrapper.pid" wrapper "$id" -CONT
    signal_pid_rec "$RUNTIME/$id.wrapper.pid" wrapper "$id" -KILL
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
  signal_pid_rec "$RUNTIME/$id.aria2.pid" aria2 "$id" -TERM
  signal_pid_rec "$RUNTIME/$id.wrapper.pid" wrapper "$id" -TERM
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