#!/usr/bin/env bash
# One-shot installer for btx-miner.
#   curl -fsSL https://raw.githubusercontent.com/codyvolckmar/btx-miner/main/install.sh | sudo BTX_WALLET=btx1ADDRESS.WORKER bash
# Installs the control panel as /usr/local/bin/btx-miner, downloads + verifies
# nekominer into /opt/btx, and starts mining if a wallet was given and the GPU checks pass.
set -euo pipefail

main() {   # wrapped so a truncated download never runs half a script
  local repo="https://raw.githubusercontent.com/codyvolckmar/btx-miner/main"
  local dest="/usr/local/bin/btx-miner"

  [ "$(id -u)" -eq 0 ] || { echo "Run as root: curl -fsSL $repo/install.sh | sudo bash" >&2; exit 1; }
  [ "$(uname -m)" = x86_64 ] || { echo "nekominer needs x86_64 Linux (got $(uname -m))." >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }

  echo "==> Installing control panel to $dest"
  local tmp; tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$repo/miner-btx.sh"
  bash -n "$tmp"
  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"

  echo "==> Downloading nekominer (SHA-256 verified)"
  "$dest" --install

  if [ -n "${BTX_WALLET:-}" ] && "$dest" --preflight >/dev/null 2>&1; then
    echo "==> Starting miner"
    "$dest" --start
    "$dest" --status 4
  else
    echo
    "$dest" --preflight || true
  fi

  cat <<EOF

Done. Next:
  sudo btx-miner              interactive menu (set wallet, start, watch stats)
  sudo btx-miner --status     one-shot status
  sudo btx-miner --help       all commands
EOF
}

main "$@"
