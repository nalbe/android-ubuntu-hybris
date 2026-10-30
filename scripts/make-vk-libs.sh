#!/bin/bash
# make-vk-libs.sh - (re)create the curated lib dir for the hybris Vulkan WSI.
#
# Why not just point clients at prefix/lib/libvulkan.so.1?  Loading that libvulkan
# directly breaks libgtk-4.  Instead we ship a tiny lazy shim named libvulkan.so.1:
# scripts/gen-lazyvk.py generates one tail-call trampoline per entrypoint the real
# loader exports (lazyvk/lazyvk.c + lazyvk/lazyvk.S), and from a constructor
# (lazyvk/runtime.c) the shim dlopens the real hybris libvulkan
# (libvulkan-hybris.so.1 -> prefix/lib/libvulkan.so.1.2.183) and fills the slots.
# GTK therefore resolves the light shim, never the heavy lib.  The tables cover
# the FULL loader API (zink/mesa call core 1.1+ entrypoints that a hand-picked
# subset does not have), so keep them regenerated on every run.
#
# The shim finds the real driver via VK_REAL_SHIM, or - by default - via its
# compiled-in absolute path (vk-libs/libvulkan-hybris.so.1), so no env var is
# required.  The dir is registered in /etc/ld.so.conf.d/00-hybris-gl.conf, so
# keep the ld.so.cache fresh after re-running this script.
# Idempotent; safe to re-run after a libhybris rebuild.
set -euo pipefail

# --- workspace layout (single source of truth: <workspace>/workspace.env) ---
_agb_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
while [ ! -f "$_agb_here/workspace.env" ] && [ "$_agb_here" != / ]; do
    _agb_here="$(dirname "$_agb_here")"
done
[ -f "$_agb_here/workspace.env" ] || { echo "$(basename "$0"): workspace.env not found" >&2; return 1 2>/dev/null || exit 1; }
. "$_agb_here/workspace.env"

SRC="$AGB_HYBRIS_DIR/lazyvk"
DEST="$AGB_HYBRIS_DIR/vk-libs"
PREFIX="$AGB_HYBRIS_DIR/prefix/lib"

[ -e "$PREFIX/libvulkan.so.1.2.183" ] || {
    echo "make-vk-libs: $PREFIX/libvulkan.so.1.2.183 missing (rebuild libhybris)" >&2
    exit 1
}

mkdir -p "$DEST"

# The hybris libvulkan is linked by libtool with a RUNPATH that points into the
# build tree (.../hybris/common/.libs), so a later incremental rebuild of
# libhybris would silently change what the shim loads.  Normalize it to the
# installed prefix only.
if command -v patchelf >/dev/null 2>&1; then
    patchelf --set-rpath "$PREFIX" "$PREFIX/libvulkan.so.1.2.183"
fi

# Regenerate the trampoline tables from the loader's exports; without python3
# fall back to the checked-in generated files.
if command -v python3 >/dev/null 2>&1; then
    python3 "$AGB_HYBRIS_DIR/scripts/gen-lazyvk.py" \
        --real "$PREFIX/libvulkan.so.1.2.183" --out-dir "$SRC"
fi

# Build the shim; keep the old one if the compiler is unavailable.
if command -v gcc >/dev/null 2>&1; then
    gcc -O2 -fPIC -shared -Wl,-soname,libvulkan.so.1 \
        -DLAZYVK_DEFAULT_REAL="\"$DEST/libvulkan-hybris.so.1\"" \
        -o "$DEST/libvulkan.so.1.new" \
        "$SRC/runtime.c" "$SRC/lazyvk.c" "$SRC/lazyvk.S" -ldl
    mv "$DEST/libvulkan.so.1.new" "$DEST/libvulkan.so.1"
fi

ln -sfn libvulkan.so.1 "$DEST/libvulkan.so"
ln -sfn ../prefix/lib/libvulkan.so.1.2.183 "$DEST/libvulkan-hybris.so.1"

# gl-libs/vk-libs are in /etc/ld.so.conf.d/00-hybris-gl.conf: refresh the
# cache so the fresh shim wins over the system mesa libvulkan.
ldconfig 2>/dev/null || true

echo "vk-libs ready in $DEST:"
ls -1 "$DEST"
