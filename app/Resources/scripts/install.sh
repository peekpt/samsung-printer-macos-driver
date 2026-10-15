#!/bin/bash
#
# Samsung SpliX driver installer - privileged part.
#
# Installs the (bundled) SpliX filters, the bundled PPDs and the USB
# re-enumeration helper, then adds a print queue for every supported Samsung
# printer currently connected over USB.
#
# Usage:
#   install.sh --detect <payload-dir>   report what would be done (no root)
#   install.sh <payload-dir>            do it (needs root)
#
set -euo pipefail

DEST="/Library/Printers/Splix"
PPD_DEST="/Library/Printers/PPDs/Contents/Resources"
REALFILTER="$DEST/rastertoqpdl"
STATE="$DEST/installed-queues"
LOGFILE="/var/log/splixinstaller.log"
PPD_SUFFIX="SpliX"

say() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

MODE="install"
if [ "${1:-}" = "--detect" ]; then
  MODE="detect"
  shift
fi

PAYLOAD="${1:-}"
if [ -z "$PAYLOAD" ] || [ ! -d "$PAYLOAD" ]; then
  err "payload directory missing"
  exit 2
fi
BIN="$PAYLOAD/bin"
PPDS="$PAYLOAD/ppd"

[ -x "$BIN/rastertoqpdl" ] || { err "missing $BIN/rastertoqpdl"; exit 2; }
[ -d "$PPDS" ]            || { err "missing $PPDS"; exit 2; }

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
norm() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd '[:alnum:]'; }

ppd_product() {
  # *Product: "(ML-1510)"  ->  ML-1510
  grep -a -m1 '^\*Product:' "$1" 2>/dev/null \
    | sed -e 's/^\*Product:[[:space:]]*//' -e 's/^"//' -e 's/"$//' -e 's/^(//' -e 's/)$//'
}

model_name() {
  grep -a -m1 '^\*ModelName:' "$1" 2>/dev/null \
    | sed -e 's/^\*ModelName:[[:space:]]*//' -e 's/^"//' -e 's/"$//'
}

# preferred UI language (pt / fr / ...), '' if English
sys_lang() {
  local l
  l=$(defaults read -g AppleLanguages 2>/dev/null | grep -oE '"[a-z]{2}' | head -1 | tr -d '"')
  case "$l" in pt|fr) printf '%s' "$l" ;; *) printf '' ;; esac
}

# longest-model match of a USB MDL against the bundled PPDs; echoes a ppd path
find_ppd() {
  local mdl="$1" want="${2:-}" best="" bestlen=0 ppd prod pnorm
  want=$(norm "$mdl")
  for ppd in "$PPDS"/*.ppd; do
    local b; b=$(basename "$ppd")
    case "$b" in *fr.ppd|*pt.ppd) continue ;; esac   # language variants handled below
    prod=$(ppd_product "$ppd")
    [ -n "$prod" ] || continue
    pnorm=$(norm "$prod")
    [ -n "$pnorm" ] || continue
    case "$want" in
      *"$pnorm"*)
        if [ "${#pnorm}" -gt "$bestlen" ]; then best="$ppd"; bestlen=${#pnorm}; fi
        ;;
    esac
  done
  [ -n "$best" ] || return 0
  # apply language variant when available
  if [ -n "$LANG_CODE" ]; then
    local v="${best%.ppd}${LANG_CODE}.ppd"
    [ -f "$v" ] && best="$v"
  fi
  printf '%s' "$best"
}

# --------------------------------------------------------------------------
# Detection
# --------------------------------------------------------------------------
LANG_CODE="$(sys_lang)"

list_printers() {
  /usr/libexec/cups/backend/usb 2>/dev/null || true
}

detect() {
  local line uri mfg mdl ppd qname
  while IFS= read -r line; do
    case "$line" in
      "direct usb://"*) ;;
      *) continue ;;
    esac
    uri=$(printf '%s' "$line" | sed -n 's/^direct \([^ ]*\).*/\1/p')
    mfg=$(printf '%s' "$line" | grep -o 'MFG:[^;"]*' | head -1 | cut -d: -f2- || true)
    mdl=$(printf '%s' "$line" | grep -o 'MDL:[^;"]*' | head -1 | cut -d: -f2- || true)
    [ -n "$mdl" ] || mdl=$(printf '%s' "$uri" | sed -n 's#^usb://[^/]*/##; s#?.*##')
    ppd=$(find_ppd "$mdl")
    if [ -n "$ppd" ]; then
      qname="$(model_name "$ppd" | tr ' ' '_' | tr -cd '[:alnum:]_-')"
      [ -n "$qname" ] || qname="Samsung_$mdl"
      printf 'FOUND|%s|%s|%s|%s|%s\n' "$uri" "${mfg:-Samsung}" "$mdl" "$(basename "$ppd")" "$qname"
    else
      printf 'UNSUPPORTED|%s|%s|%s\n' "$uri" "${mfg:-?}" "$mdl"
    fi
  done < <(list_printers)
}

if [ "$MODE" = "detect" ]; then
  detect
  exit 0
fi

# --------------------------------------------------------------------------
# Install (root)
# --------------------------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
  exec sudo "$0" "$@"
fi

mkdir -p "$DEST"
exec > >(tee -a "$LOGFILE") 2>&1
say "=== splix install $(date) ==="

# 1. runtime
say "-> install runtime into $DEST"
install -m 0755 -o root -g wheel "$BIN/rastertoqpdl" "$DEST/rastertoqpdl"
install -m 0755 -o root -g wheel "$BIN/pstoqpdl"   "$DEST/pstoqpdl" 2>/dev/null || true
install -m 0755 -o root -g wheel "$BIN/splixreset" "$DEST/splixreset"

# 2. backend wrapper (resets the USB device *before* opening it, no race)
BACKEND_SRC="$PAYLOAD/backend/splixusb"
BACKEND_LINK="/usr/libexec/cups/backend/splixusb"
say "-> install CUPS backend $DEST/splixusb"
install -m 0755 -o root -g wheel "$BACKEND_SRC" "$DEST/splixusb"
ln -sf "$DEST/splixusb" "$BACKEND_LINK"

# 3. PPDs (one per model, language variant when available)
say "-> install PPDs into $PPD_DEST"
SEEN_FILE="$(mktemp)"
for ppd in "$PPDS"/*.ppd; do
  b=$(basename "$ppd")
  case "$b" in *fr.ppd|*pt.ppd) continue ;; esac
  mname=$(model_name "$ppd")
  [ -n "$mname" ] || continue
  if grep -Fxq "$mname" "$SEEN_FILE"; then continue; fi
  printf '%s\n' "$mname" >> "$SEEN_FILE"
  use="$ppd"
  if [ -n "$LANG_CODE" ]; then
    v="${ppd%.ppd}${LANG_CODE}.ppd"
    [ -f "$v" ] && use="$v"
  fi
  # rewrite the filter target so the PPD calls our installed filter
  out="$PPD_DEST/${mname} (${PPD_SUFFIX})"
  TMP="$(mktemp)"
  sed -e "s#^\(\*cupsFilter:[^\"]*\"application/vnd.cups-raster 0 \)[^\"]*\"#\1${REALFILTER}\"#" \
      -e "s#^\(\*cupsFilter2:[^\"]*\"application/vnd.cups-raster 0 \)[^\"]*\"#\1${REALFILTER}\"#" \
      "$use" > "$TMP"
  gzip -9 -c "$TMP" > "$out.gz"
  rm -f "$TMP"
  chown root:admin "$out.gz"
  chmod 0755 "$out.gz"
  printf '   %s\n' "$(basename "$out.gz")"
done

# 4. queues for the printers currently connected
say "-> add print queues"
: > "$STATE"

# find an existing queue that already points at this device
# (locale-independent: "<label> <name>: <uri>", queue names have no spaces;
#  compare the part after the scheme so usb:// and splixusb:// match)
queue_for_uri() {
  local want="${1#*://}"
  lpstat -v 2>/dev/null | awk -v u="$want" '
    {
      i=index($0,": "); if (i==0) next
      uri=substr($0,i+2); sub(/^[a-z]+:\/\//,"",uri)
      if (uri != u) next
      before=substr($0,1,i-1)
      n=split(before,a," "); print a[n]
    }' | head -1
}

while IFS='|' read -r tag uri mfg mdl ppdfile qname; do
  [ "$tag" = "FOUND" ] || continue
  # locate the installed PPD for this model
  mname=$(model_name "$PPDS/$ppdfile")
  target="$PPD_DEST/${mname} (${PPD_SUFFIX}).gz"
  [ -f "$target" ] || { say "   ! PPD not installed for $mdl"; continue; }

  # route the queue through our backend so the device is reset before each job
  suri="splixusb://${uri#usb://}"

  existing="$(queue_for_uri "$uri")"
  if [ -n "$existing" ]; then
    qname="$existing"
    say "   ~ updating existing queue $qname"
  else
    say "   + adding queue $qname ($mdl)"
  fi
  /usr/sbin/lpadmin -p "$qname" -E -v "$suri" -P "$target" \
    -D "$mname" -o printer-is-shared=false || true
  printf '%s\n' "$qname" >> "$STATE"
done < <(detect)

# 5. reload CUPS so the new PPDs appear
say "-> reload cupsd"
killall -HUP cupsd 2>/dev/null || launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true

say "=== done ==="
printf 'OK\n'
