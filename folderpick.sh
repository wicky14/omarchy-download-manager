#!/usr/bin/env bash
# folderpick.sh - folder picker for the Download Manager plugin.
#
# Opens the desktop's folder chooser through xdg-desktop-portal (via gdbus)
# and prints the chosen folder's absolute path to stdout. Prints nothing and
# exits 0 when the dialog is cancelled, exits 1 on failure.
#
# Usage: folderpick.sh [title]

set -uo pipefail

title="${1:-Pilih folder download}"

if ! command -v gdbus >/dev/null 2>&1; then
  echo "gdbus is required (glib2)" >&2
  exit 1
fi

handle_token="dm_folder_${RANDOM}_${RANDOM}"
portaldest="org.freedesktop.portal.Desktop"
portalobj="/org/freedesktop/portal/desktop"

opts="{'handle_token': <'$handle_token'>, 'accept_label': <'Pilih'>, 'directory': <true>, 'title': <'$title'>}"

req_line="$(
  timeout 10 gdbus call --session \
    --dest "$portaldest" \
    --object-path "$portalobj" \
    --method org.freedesktop.portal.FileChooser.OpenFile \
    "" "$title" "$opts" 2>/dev/null || true
)"

req_path="$(printf '%s' "$req_line" | sed -n "s/.*'\(\/org\/freedesktop\/portal\/desktop\/request\/[^']*\)'.*/\1/p")"
if [[ -z $req_path ]]; then
  echo "Gagal membuka folder picker" >&2
  exit 1
fi

resp="$(
  timeout 30 bash -c "gdbus monitor --session --dest '$portaldest' 2>/dev/null | grep -m1 'Request.Response'" || true
)"

code="$(printf '%s' "$resp" | sed -n "s/.*Request.Response (u \([0-9]*\),.*/\1/p")"
if [[ "$code" != "0" ]]; then
  exit 0
fi

uri="$(printf '%s' "$resp" | sed -n "s/.*'uris': <\[\([^]]*\)\]>.*/\1/p" | sed -n "s/^'file:\/\///p" | sed -n "s/'.*$//p")"
if [[ -z $uri ]]; then
  uri="$(printf '%s' "$resp" | sed -n "s/.*file:\/\/\([^']*\)'.*/\1/p")"
fi

if [[ -z $uri ]]; then
  exit 0
fi

printf '%b\n' "${uri//%/\\x}"
exit 0