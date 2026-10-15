#!/bin/bash
#
# Install the "no-replug" fix for a Samsung ML-1510 on modern macOS.
#
# It installs a small helper (ml1510reset) that re-enumerates the USB device
# (the software equivalent of unplugging/replugging the cable) and a CUPS
# filter wrapper that runs it before every job.  The wrapper delegates to the
# real SpliX filter, so printing itself is unchanged.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit here if your paths differ)
# ---------------------------------------------------------------------------
DEST_DIR="/Library/Printers/Samsung/ML-1510/driver"
REAL_FILTER="/Library/Printers/Samsung/UPD/Filters/rastertoqpdl"
ACTIVE_PPD="/etc/cups/ppd/Samsung_ML_1510.ppd"
RES_PPD="/Library/Printers/PPDs/Contents/Resources/Samsung ML-1510 Series.gz"
QUEUE="Samsung_ML_1510"
USB_VID="04e8"
USB_PID="3242"
WAIT_SECS="10"
SETTLE_SECS="2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESET_BIN="$DEST_DIR/ml1510reset"
WRAPPER="$DEST_DIR/rastertoqpdl"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
[ -x "$REAL_FILTER" ] || die "SpliX filter not found at $REAL_FILTER.
Install Samsung Printer Drivers v3.92 + SpliX 2.0.0 first (see README)."

command -v clang >/dev/null 2>&1 || die "clang not found. Install the Xcode Command Line Tools: xcode-select --install"

# ---------------------------------------------------------------------------
# 1. Work out the printer's USB serial number (used to pick the right device)
# ---------------------------------------------------------------------------
detect_serial() {
  local s
  s="$(lpstat -v 2>/dev/null | sed -n 's#.*'"$QUEUE"': *usb://[^ ]*[?&]serial=\([^ &]*\).*#\1#p' | head -1)"
  [ -n "$s" ] && { printf '%s' "$s"; return; }
  s="$(ioreg -p IOUSB -w0 -l 2>/dev/null \
        | awk '/"USB Product Name" *= *"Samsung ML-1510/{f=1} f && /"USB Serial Number" *=/{gsub(/.*= *"|"/,""); print; exit}')"
  printf '%s' "$s"
}
SERIAL="$(detect_serial || true)"

say "==> Installing ML-1510 no-replug driver"
say "    destination : $DEST_DIR"
say "    serial      : ${SERIAL:-<not detected>}"

# ---------------------------------------------------------------------------
# 2. Build and install the reset helper
# ---------------------------------------------------------------------------
mkdir -p "$DEST_DIR"
chown root:wheel "$DEST_DIR"
chmod 755 "$DEST_DIR"

say "==> Compiling ml1510reset"
clang -O2 -Wall -framework IOKit -framework CoreFoundation \
      -o "$RESET_BIN" "$SCRIPT_DIR/src/ml1510reset.c"
chown root:wheel "$RESET_BIN"
chmod 755 "$RESET_BIN"
xattr -c "$RESET_BIN" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Install the filter wrapper
# ---------------------------------------------------------------------------
SERIAL_ARG=""
[ -n "$SERIAL" ] && SERIAL_ARG="-s $SERIAL"

say "==> Installing filter wrapper $WRAPPER"
cat > "$WRAPPER" <<EOF
#!/bin/sh
#
# CUPS filter wrapper for the Samsung ML-1510 (SpliX/QPDL).
#
# Re-enumerates the USB device before each job (software equivalent of
# unplugging/replugging the cable) so the printer does not get stuck after a
# job.  Then it simply hands over to the real SpliX filter.
#
RESET="$RESET_BIN"
REAL="$REAL_FILTER"
if [ -x "\$RESET" ]; then
  "\$RESET" $SERIAL_ARG -w $WAIT_SECS -d $SETTLE_SECS -v 1>&2 || true
fi
exec "\$REAL" "\$@"
EOF
chown root:wheel "$WRAPPER"
chmod 755 "$WRAPPER"

# Make sure _lp can execute the filter and its directory chain.
chmod 755 "$DEST_DIR"

# ---------------------------------------------------------------------------
# 4. Point the PPD(s) at the wrapper
# ---------------------------------------------------------------------------
patch_ppd() {
  local f="$1"
  # only rewrite the exact filter target; idempotent
  sed -i '' \
    -e "s#^\(\*cupsFilter: \"application/vnd.cups-raster 0 \)${REAL_FILTER}\"#\1${WRAPPER}\"#" \
    "$f"
  if grep -qF "$WRAPPER" "$f"; then
    return 0
  fi
  return 1
}

if [ -f "$ACTIVE_PPD" ]; then
  say "==> Patching active PPD $ACTIVE_PPD"
  [ -f "$ACTIVE_PPD.orig" ] || cp -p "$ACTIVE_PPD" "$ACTIVE_PPD.orig"
  if patch_ppd "$ACTIVE_PPD"; then
    say "    ok"
  else
    warn "could not find the expected cupsFilter line in $ACTIVE_PPD (already patched?)"
  fi
else
  warn "active PPD $ACTIVE_PPD not found (printer not added yet?)"
fi

if [ -f "$RES_PPD" ]; then
  say "==> Patching resource PPD (used when adding a new queue)"
  [ -f "$RES_PPD.orig" ] || cp -p "$RES_PPD" "$RES_PPD.orig"
  tmp="$(mktemp /tmp/ml1510ppd.XXXXXX)"
  gunzip -c "$RES_PPD" > "$tmp"
  patch_ppd "$tmp" || warn "unexpected PPD contents"
  gzip -c "$tmp" > "$RES_PPD"
  chown root:admin "$RES_PPD"
  chmod 755 "$RES_PPD"
  rm -f "$tmp"
fi

# ---------------------------------------------------------------------------
# 5. Reload CUPS so it picks up the new PPD
# ---------------------------------------------------------------------------
say "==> Reloading CUPS"
if ! killall -HUP cupsd 2>/dev/null; then
  launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
fi
sleep 1

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
say ""
say "==> Verification"
if [ -n "$SERIAL" ]; then
  # CUPS runs filters as _lp, so test exactly that (no root).
  if sudo -u _lp "$RESET_BIN" -s "$SERIAL" -w "$WAIT_SECS" -d "$SETTLE_SECS" >/dev/null 2>&1; then
    say "    USB re-enumeration as _lp: OK"
  elif "$RESET_BIN" -s "$SERIAL" -w "$WAIT_SECS" -d "$SETTLE_SECS" >/dev/null 2>&1; then
    say "    USB re-enumeration as root: OK"
    warn "but it failed as _lp - filters may not be able to reset the device"
  else
    warn "USB re-enumeration failed (printer off/not connected?)"
  fi
else
  warn "skipped USB test (serial not detected)"
fi

say ""
say "Done.  Print a page, then print a second page WITHOUT touching the cable."
say "Both should come out."
say "Check the reset ran:  grep ml1510reset /var/log/cups/error_log | tail"
say "To revert:  sudo $SCRIPT_DIR/uninstall.sh"
