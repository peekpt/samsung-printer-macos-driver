#!/bin/bash
# Build AppIcon.icns from the drawn 1024x1024 base image.
set -euo pipefail

OUT="${1:-AppIcon.icns}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O -o "$TMP/draw" "$HERE/draw.swift" -framework AppKit
"$TMP/draw" "$TMP/base.png"

ISET="$TMP/AppIcon.iconset"
mkdir -p "$ISET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/base.png" --out "$ISET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$TMP/base.png" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ISET" -o "$OUT"
echo "wrote $OUT"
