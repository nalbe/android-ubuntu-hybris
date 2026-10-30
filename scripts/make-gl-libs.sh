#!/bin/bash
# make-gl-libs.sh - (re)create a curated lib dir of the freshly-built libhybris
# EGL/GLES libs for Wayland clients.
#
# Why not just use prefix/lib on LD_LIBRARY_PATH?  prefix/lib also contains the
# Android libvulkan.so.1, whose Vulkan probe breaks libgtk-4 (and segfaults
# gnome-control-center).  We only need libEGL/libGLESv*/libhybris-common; their
# DT_RUNPATH points back into prefix/lib, so libhybris-platformcommon and the
# eglplatform_*.so plugins resolve from there.
#
# Idempotent; safe to re-run after a libhybris rebuild.
set -euo pipefail

# --- workspace layout (single source of truth: <workspace>/workspace.env) ---
_agb_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
while [ ! -f "$_agb_here/workspace.env" ] && [ "$_agb_here" != / ]; do
    _agb_here="$(dirname "$_agb_here")"
done
[ -f "$_agb_here/workspace.env" ] || { echo "$(basename "$0"): workspace.env not found" >&2; return 1 2>/dev/null || exit 1; }
. "$_agb_here/workspace.env"

PREFIX="$AGB_HYBRIS_DIR/prefix/lib"
DEST="$AGB_HYBRIS_DIR/gl-libs"
LIBS=(libEGL.so libEGL.so.1 libGLESv1_CM.so.1 libGLESv2.so libGLESv2.so.2
      libhybris-common.so libhybris-common.so.1 libhybris-common.so.1.0.0)

mkdir -p "$DEST"
for l in "${LIBS[@]}"; do
    [ -e "$PREFIX/$l" ] || continue
    # Relative link: gl-libs/ and prefix/ are siblings inside the part, so the
    # whole part stays relocatable.
    ln -sfn "../prefix/lib/$l" "$DEST/$l"
done

# gl-libs/vk-libs are in /etc/ld.so.conf.d/00-hybris-gl.conf: refresh the
# cache so the fresh libs win over the distro glvnd libEGL.
ldconfig 2>/dev/null || true

echo "gl-libs ready in $DEST:"
ls -1 "$DEST"
