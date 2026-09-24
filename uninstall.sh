#!/usr/bin/env bash
# uninstall.sh - full interactive uninstall for the Download Manager plugin.
#
# Complementary to `omarchy plugin remove omakid.download-manager` (which only
# removes the plugin folder + bar entry). This script additionally cleans up
# everything the plugin created at runtime:
#
#   - kills running aria2 downloads and the clipboard watcher
#   - removes the runtime dir  ($XDG_RUNTIME_DIR/omarchy-download-manager)
#   - removes the config dir    (~/.config/omarchy/omakid.download-manager)
#   - removes the CLI symlink   (~/.local/bin/omarchy-dl)
#   - then calls `omarchy plugin remove ... --yes` (interactive here)

set -uo pipefail

PLUGIN_ID="omakid.download-manager"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/omarchy-download-manager"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/$PLUGIN_ID"
CLI_BIN="$HOME/.local/bin/omarchy-dl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { printf '\033[1;36m*\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$1"; }
red()   { printf '\033[1;31m!\033[0m %s\n' "$1"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$1"; }

confirm() {
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false "$1" --affirmative="Hapus" --negative="Batal"
    return $?
  fi
  printf '\033[1;33m%s [y/N]\033[0m ' "$1"
  read -r answer </dev/tty
  [[ $answer == "y" || $answer == "Y" ]]
}

main() {
  info "Memulai uninstall lengkap $PLUGIN_ID"

  echo
  echo "Yang akan dilakukan:"
  echo "  1. Menghentikan semua download aria2 yang sedang berjalan"
  echo "  2. Menghapus runtime  : $RUNTIME"
  echo "  3. Menghapus konfigurasi: $CONFIG_DIR (riwayat antrean ikut terhapus)"
  echo "  4. Menghapus symlink CLI: $CLI_BIN"
  echo "  5. Mencopot plugin dari Omarchy (folder + entry bar)"
  echo

  confirm "Lanjut menghapus Download Manager?" || {
    red "Dibatalkan."
    exit 1
  }

  # 1. stop everything running
  info "Menghentikan download aktif & clipboard watcher..."
  bash "$SCRIPT_DIR/dm-dl.sh" cancel-all 2>/dev/null || true
  bash "$SCRIPT_DIR/clipwatch.sh" stop 2>/dev/null || true
  sleep 0.3

  # 2. remove runtime + config
  info "Menghapus runtime & konfigurasi..."
  rm -rf "$RUNTIME" 2>/dev/null || true
  rm -rf "$CONFIG_DIR" 2>/dev/null || true

  # 3. remove CLI symlink
  info "Menghapus symlink CLI..."
  rm -f "$CLI_BIN" 2>/dev/null || true

  # 4. plugin remove (this handles bar entry + plugin folder)
  info "Mencopot plugin dari Omarchy..."
  if omarchy plugin remove "$PLUGIN_ID" --yes 2>/dev/null; then
    ok "Plugin dicopot."
  else
    warn "Gagal mencopot via 'omarchy plugin remove'."
    warn "Jalankan manual: omarchy plugin remove $PLUGIN_ID"
  fi

  echo
  ok "Selesai \u2014 Download Manager telah dihapus sepenuhnya."
  info "Restart shell bila perlu: omarchy restart shell"
}

trap 'red "Dibatalkan."; exit 1' INT
main "$@"