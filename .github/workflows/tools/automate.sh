#!/usr/bin/env bash
# tools/automate.sh - high level automation wrapper for SH1MMER Reworked
# Place in tools/ and make executable (git will preserve mode when pushed via local tooling)

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WAX="$REPO_ROOT/wax/wax.sh"

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  build-bw    - Build a "Beautiful World" shim image from a raw shim file
  build-legacy - shim legacy payload build
  build-all   - Run build-bw and build-legacy sequentially
  wax4web     - Bundle the wax4web web emulator assets
  help        - Show this message

Examples:
  sudo $0 build-bw --image /path/to/shim.bin --out /tmp/out.bin
  sudo $0 build-legacy --image /path/to/shim.bin

Note: Many operations modify disk images and require root privileges.
EOF
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "This command must be run as root (or with sudo)." >&2
    exit 1
  fi
}

_build_bw() {
  # required args: --image
  local image=""
  local chromebrew=""
  local sh1mmer_part_size=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      --chromebrew) chromebrew="$2"; shift 2 ;;
      --part-size) sh1mmer_part_size="$2"; shift 2 ;;
      *) echo "Unknown arg: $1"; return 1 ;;
    esac
  done

  if [ -z "$image" ]; then
    echo "--image is required"; return 1
  fi

  cmd=("bash" "$WAX" -i "$image" -p bw)
  [ -n "$chromebrew" ] && cmd+=(--chromebrew "$chromebrew")
  [ -n "$sh1mmer_part_size" ] && cmd+=(--sh1mmer_part_size "$sh1mmer_part_size")

  echo ">> Running: ${cmd[*]}"
  "${cmd[@]}"
}

_build_legacy() {
  local image=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image) image="$2"; shift 2 ;;
      *) echo "Unknown arg: $1"; return 1 ;;
    esac
  done

  if [ -z "$image" ]; then
    echo "--image is required"; return 1
  fi

  echo ">> Building legacy payload"
  bash "$WAX" -i "$image" -p legacy
}

_wax4web() {
  echo ">> Bundling wax4web assets"
  if [ -x "$REPO_ROOT/wax/wax4web_bundler.sh" ]; then
    bash "$REPO_ROOT/wax/wax4web_bundler.sh"
  else
    echo "wax4web_bundler.sh not found or not executable"; return 1
  fi
}

main() {
  if [ $# -lt 1 ]; then usage; exit 1; fi
  cmd="$1"; shift
  case "$cmd" in
    build-bw) require_root; _build_bw "$@" ;;
    build-legacy) require_root; _build_legacy "$@" ;;
    build-all) require_root; _build_bw "$@"; _build_legacy "$@" ;;
    wax4web) _wax4web ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
