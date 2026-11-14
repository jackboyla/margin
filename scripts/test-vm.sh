#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TART_BIN="${TART_BIN:-tart}"
export TART_HOME="$PWD/.tools/vm/tart-home"
export TART_NO_AUTO_PRUNE=1

case "${1:-}" in
  create)
    available_kib=$(df -Pk . | awk 'NR == 2 { print $4 }')
    if [ "$available_kib" -lt 36700160 ]; then
      echo "Creating the test VM requires at least 35 GiB free on this volume." >&2
      exit 1
    fi
    "$TART_BIN" clone ghcr.io/cirruslabs/macos-sonoma-vanilla:14.6.1 margin-test
    "$TART_BIN" set margin-test --cpu 2 --memory 4096 --display 1280x800 --no-display-refit
    ;;
  run)
    exec "$TART_BIN" run margin-test --no-graphics --vnc-experimental \
      --no-audio --no-clipboard --no-usb-accessories
    ;;
  stop|ip)
    exec "$TART_BIN" "$1" margin-test
    ;;
  *)
    echo "Usage: $0 {create|run|stop|ip}" >&2
    exit 2
    ;;
esac
