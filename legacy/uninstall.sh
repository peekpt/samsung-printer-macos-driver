#!/bin/bash
#
# Remove the ML-1510 "no-replug" fix and restore the original PPD filter.
#
set -euo pipefail

DEST_DIR="/Library/Printers/Samsung/ML-1510/driver"
ACTIVE_PPD="/etc/cups/ppd/Samsung_ML_1510.ppd"
RES_PPD="/Library/Printers/PPDs/Contents/Resources/Samsung ML-1510 Series.gz"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@"
fi

say "==> Restoring PPDs"
if [ -f "$ACTIVE_PPD.orig" ]; then
  cp -p "$ACTIVE_PPD.orig" "$ACTIVE_PPD"
  rm -f "$ACTIVE_PPD.orig"
  say "    restored $ACTIVE_PPD"
fi
if [ -f "$RES_PPD.orig" ]; then
  cp -p "$RES_PPD.orig" "$RES_PPD"
  rm -f "$RES_PPD.orig"
  say "    restored $RES_PPD"
fi

say "==> Removing $DEST_DIR"
rm -rf "$DEST_DIR"

say "==> Reloading CUPS"
killall -HUP cupsd 2>/dev/null || true
sleep 1

say "Done.  The printer is back to the stock SpliX driver (with the replug bug)."
