#!/usr/bin/env bash
set -e

DEST="${1:-/usr/local}"
ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing hybris prebuilt to $DEST"
mkdir -p "$DEST/lib" "$DEST/lib/pkgconfig" "$DEST/lib/libhybris/linker"

tar -xzf "$ASSET_DIR/hybris-prebuilt.tar.gz" -C "$DEST/lib"

if command -v ldconfig >/dev/null 2>&1; then
  ldconfig
fi

echo "Done."
