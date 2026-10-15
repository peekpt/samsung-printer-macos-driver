#!/bin/bash
#
# Samsung SpliX driver uninstaller (privileged part).
#
# Removes the runtime, the installed PPDs and the print queues that were added
# by the installer.
#
set -euo pipefail

DEST="/Library/Printers/Splix"
PPD_DEST="/Library/Printers/PPDs/Contents/Resources"
STATE="$DEST/installed-queues"

say() { printf '%s\n' "$*"; }

if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@"
fi

echo "=== splix uninstall $(date) ==="

# 1. remove queues we added
if [ -f "$STATE" ]; then
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    say "-> removing queue $q"
    /usr/sbin/lpadmin -x "$q" >/dev/null 2>&1 || true
  done < "$STATE"
fi

# 2. remove installed PPDs
say "-> removing PPDs"
rm -f "$PPD_DEST"/"(SpliX)".gz 2>/dev/null || true
find "$PPD_DEST" -maxdepth 1 -name "* (SpliX).gz" -delete 2>/dev/null || true

# 3. remove the CUPS backend link
say "-> removing backend /usr/libexec/cups/backend/splixusb"
rm -f /usr/libexec/cups/backend/splixusb

# 4. remove runtime
say "-> removing $DEST"
rm -rf "$DEST"

# 5. reload CUPS
say "-> reload cupsd"
killall -HUP cupsd 2>/dev/null || true

say "=== done ==="
printf 'OK\n'
