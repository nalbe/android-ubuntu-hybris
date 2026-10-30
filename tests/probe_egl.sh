#!/bin/bash
# Build (if needed) and run the headless EGL/GLES probe on the Mali GPU.
set -euo pipefail

# --- workspace layout (single source of truth: <workspace>/workspace.env) ---
_agb_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
while [ ! -f "$_agb_here/workspace.env" ] && [ "$_agb_here" != / ]; do
    _agb_here="$(dirname "$_agb_here")"
done
[ -f "$_agb_here/workspace.env" ] || { echo "$(basename "$0"): workspace.env not found" >&2; return 1 2>/dev/null || exit 1; }
. "$_agb_here/workspace.env"

PREFIX="$AGB_HYBRIS_DIR/prefix"
ASSETS_DIR="$AGB_HYBRIS_DIR/assets"

if [ ! -r "$PREFIX/lib/libEGL.so" ]; then
  echo "nothing built yet, running build.sh ..."
  "$AGB_HYBRIS_DIR/scripts/build.sh"
fi

. "$AGB_HYBRIS_DIR/env/hybris_env.sh"
# Headless probe: pbuffer rendering, not a Wayland client.  The compiled-in
# EGL platform default is "wayland" now, so opt into the null platform.
export HYBRIS_EGLPLATFORM=null

mkdir -p "$AGB_LOG_DIR" "$AGB_HYBRIS_DIR/bin"
gcc -O2 -o "$AGB_HYBRIS_DIR/bin/probe_egl" "$ASSETS_DIR/probe_egl.c" \
  -I"$PREFIX/include" -L"$PREFIX/lib" -lEGL -lGLESv2 -Wl,-rpath,"$PREFIX/lib"

echo "--- probe_egl ---"
"$AGB_HYBRIS_DIR/bin/probe_egl"
