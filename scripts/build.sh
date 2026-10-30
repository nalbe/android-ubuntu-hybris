#!/bin/bash
# android-ubuntu-gl: repeatable build of libhybris + headless Mali-GL probe
#
# Verified target:
#   Blackview SHARK 8, MT6789 (Helio G99), Mali-G57 (kbase r32p1),
#   Android 14 (SDK 34) GSI, kernel 5.10.223 GKI + KernelSU,
#   Ubuntu 24.04 (arm64) chroot sharing the device via /proc/1/root.
#
# What it does:
#   1. installs build deps (apt)
#   2. unpacks bundled android-headers (SDK 34)
#   3. stages the hybris-patched bionic libc.so
#   4. clones & builds Linux-on-droid/libhybris (branch lindroid-21)
#   5. applies gralloc-headless.patch (EGL/gralloc init must not abort in
#      headless mode; pbuffer rendering does not need gralloc)
#   5b. applies tls-patcher.patch (libhybris TLS-slot redirection; fixes the
#       tpidr_el0+32 collision where glibc errno clobbers the Android
#       TLS_SLOT_OPENGL pointer -> SIGSEGV in the Mali userspace driver)
#   5c. applies tls-default-on.patch (TLS patcher enabled unless
#       HYBRIS_PATCH_TLS=0) and reconfigures with the wayland EGL platform
#       default, so a process needs no HYBRIS_* env to use the Mali driver
#   6. installs into ./prefix
#   7. writes ./env/hybris_env.sh and builds ./bin/probe_egl
#   8. refreshes gl-libs/vk-libs and the ld.so cache (00-hybris-gl.conf)
#
# Re-run any number of times; each step is idempotent.
set -euo pipefail

# --- workspace layout (single source of truth: <workspace>/workspace.env) ---
_agb_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
while [ ! -f "$_agb_here/workspace.env" ] && [ "$_agb_here" != / ]; do
    _agb_here="$(dirname "$_agb_here")"
done
[ -f "$_agb_here/workspace.env" ] || { echo "$(basename "$0"): workspace.env not found" >&2; return 1 2>/dev/null || exit 1; }
. "$_agb_here/workspace.env"

ASSETS_DIR="$AGB_HYBRIS_DIR/assets"
PREFIX="$AGB_HYBRIS_DIR/prefix"
ANDROID_HEADERS="$AGB_HYBRIS_DIR/android-headers"
STAGING_LIBS="$AGB_HYBRIS_DIR/android-libs"
SRC_DIR="$AGB_HYBRIS_DIR/libhybris"
BUILD_DIR="$SRC_DIR/hybris"

HYBRIS_REF="lindroid-21"

# Device lib dirs, reachable through the Android chroot:
DEV_SYSTEM_LIBS="/proc/1/root/system/lib64"
DEV_VENDOR_LIBS="/proc/1/root/vendor/lib64"
DEV_ODM_LIBS="/proc/1/root/odm/lib64"
DEV_BIONIC_LIBS="/proc/1/root/apex/com.android.runtime/lib64/bionic"

log() { printf '\n=== %s ===\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

log "apt build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool autopoint pkg-config gettext \
  git cmake meson ninja-build \
  libx11-dev libx11-xcb-dev libxcb-present-dev \
  libegl1-mesa-dev libgles2-mesa-dev libglvnd-dev

log "android-headers (bundled, SDK 34)"
if [ ! -d "$ANDROID_HEADERS" ]; then
  tar -xzf "$ASSETS_DIR/android-headers.tar.gz" -C "$AGB_HYBRIS_DIR"
fi

log "stage hybris-patched bionic libc (must be found before the device's)"
mkdir -p "$STAGING_LIBS"
cp "$ASSETS_DIR/libc-patched.so" "$STAGING_LIBS/libc.so"

log "clone libhybris ($HYBRIS_REF)"
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "$HYBRIS_REF" \
    https://github.com/Linux-on-droid/libhybris "$SRC_DIR"
fi

log "apply gralloc-headless patch"
if git -C "$SRC_DIR" apply --check "$ASSETS_DIR/gralloc-headless.patch" 2>/dev/null; then
  git -C "$SRC_DIR" apply "$ASSETS_DIR/gralloc-headless.patch"
elif git -C "$SRC_DIR" apply --reverse --check "$ASSETS_DIR/gralloc-headless.patch" 2>/dev/null; then
  echo "gralloc patch already applied, skipping"
else
  echo "ERROR: gralloc patch does not apply to $HYBRIS_REF" >&2
  exit 1
fi

log "apply tls-patcher patch (upstream PR #575 + MALI_QUIRKS wiring)"
if git -C "$SRC_DIR" apply --check "$ASSETS_DIR/tls-patcher.patch" 2>/dev/null; then
  git -C "$SRC_DIR" apply "$ASSETS_DIR/tls-patcher.patch"
elif [ -f "$SRC_DIR/hybris/common/tls_patcher.c" ]; then
  # The patch adds tls_patcher.c; later patches (tls-default-on) touch the
  # same regions, so a reverse --check is not a reliable "already applied"
  # signal once they are on top.
  echo "tls-patcher patch already applied, skipping"
else
  echo "ERROR: tls-patcher patch does not apply to $HYBRIS_REF" >&2
  exit 1
fi

log "apply tls-default-on patch (TLS patcher on unless HYBRIS_PATCH_TLS=0)"
if git -C "$SRC_DIR" apply --check "$ASSETS_DIR/tls-default-on.patch" 2>/dev/null; then
  git -C "$SRC_DIR" apply "$ASSETS_DIR/tls-default-on.patch"
elif grep -qF "patch_tls[0] != '0'" "$SRC_DIR/hybris/common/hooks.c"; then
  echo "tls-default-on patch already applied, skipping"
else
  echo "ERROR: tls-default-on patch does not apply to $HYBRIS_REF" >&2
  exit 1
fi

CPPFLAGS="-I$ANDROID_HEADERS -include $ANDROID_HEADERS/glibc-compat.h"

log "configure (autogen.sh must be re-run after a fresh clone)"
cd "$BUILD_DIR"
CONFIGURE_ARGS=(
  --with-android-headers="$ANDROID_HEADERS"
  --enable-arch=arm64
  --enable-debug
  --enable-mali-quirks
  --with-default-hybris-ld-library-path="$STAGING_LIBS:$DEV_SYSTEM_LIBS:$DEV_VENDOR_LIBS:$DEV_ODM_LIBS:$DEV_BIONIC_LIBS"
  # Any process gets the wayland EGL platform with no HYBRIS_EGLPLATFORM in
  # the environment; the compositor forces "null" for itself (see the
  # MetaRenderDeviceAhb patch in mutter).
  --with-default-egl-platform=wayland
  # Defines WANT_WAYLAND, which (a) builds the vulkanplatform_wayland module
  # for Vulkan Wayland surfaces and (b) compiles libvulkan's vkGetDeviceProcAddr
  # as a plain function instead of a GNU IFUNC.  The IFUNC variant segfaults:
  # vkGetInstanceProcAddr takes its address, producing an eager GLOB_DAT that
  # glibc resolves during .rela.dyn - before .rela.plt and before constructors -
  # so the resolver calls getenv()/android_dlopen() through unrelocated PLT
  # slots and jumps to the raw PLT0 offset (0xa210).
  --enable-wayland
  # The compositor's android_wlegl implementation (mutter-ahb.patch) only
  # accepts client-side buffers: libhybris allocates a gralloc buffer and
  # hands the native_handle_t over via create_handle/add_fd/create_buffer.
  # The server-side path (get_server_buffer_handle) is answered with
  # "server-side buffers not supported", which kills every EGL/GTK client on
  # its first frame (e.g. gnome-control-center aborted with a Wayland protocol
  # error).  Build the client-side allocation path.
  --disable-wayland_serverside_buffers
  --prefix="$PREFIX"
)
# Reconfigure when there is no Makefile yet, when an older one was configured
# for a different prefix/source path (the part was moved), or when it lacks the
# wayland EGL default / WANT_WAYLAND / client-side buffer allocation.
STALE_CONFIG=0
if [ -f Makefile ]; then
  grep -q "^prefix = $PREFIX\$" Makefile || STALE_CONFIG=1
  grep -q "^abs_top_srcdir = $BUILD_DIR\$" Makefile || STALE_CONFIG=1
  grep -q 'HYBRIS_NO_SERVER_SIDE_BUFFERS' egl/platforms/wayland/Makefile 2>/dev/null || STALE_CONFIG=1
fi
if [ "$STALE_CONFIG" = 1 ]; then
  log "stale configure (prefix/source path changed), cleaning"
  make distclean >/dev/null 2>&1 || rm -f Makefile config.h config.status
fi
if [ ! -f Makefile ] \
   || ! grep -q '^DEFAULT_EGL_PLATFORM = wayland' Makefile \
   || ! grep -q '^#define WANT_WAYLAND' config.h; then
  ./autogen.sh "${CONFIGURE_ARGS[@]}"
fi

log "build"
make -j"$(nproc)" CPPFLAGS="$CPPFLAGS"

log "install -> $PREFIX"
make install CPPFLAGS="$CPPFLAGS"

log "link /usr/local/lib -> $PREFIX/lib (single build invariant)"
# mutter and gnome-shell have DT_RPATH /usr/local/lib, and /usr/local/lib is in
# LD_LIBRARY_PATH for the session, so their NEEDED lookups land here *before*
# the fresh build's DT_RUNPATH.  Copies therefore went stale and shadowed the
# real libs (e.g. libhybris-platformcommon without the android_wlegl symbols).
# Keep exactly one build: every hybris name in /usr/local/lib is a symlink into
# the part's prefix.  The Android libvulkan.so.1 stays out of the default ld
# path on purpose (it breaks libgtk-4).
for f in "$PREFIX"/lib/*.so*; do
  base=${f##*/}
  case "$base" in libvulkan.so*) continue ;; esac
  ln -sfn "$f" "/usr/local/lib/$base"
done
ln -sfn "$PREFIX/lib/libhybris" /usr/local/lib/libhybris

log "runtime env script"
ENV_FILE="$AGB_HYBRIS_DIR/env/hybris_env.sh"
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<EOF
#!/bin/bash
# GENERATED by hybris/scripts/build.sh -- do not edit.
# Source this before using hybris binaries:  . "\$AGB_HYBRIS_DIR/env/hybris_env.sh"
# Linker config only.  The compiled-in defaults already give a working Mali
# driver with no further env: EGL platform = wayland, TLS patcher = on.
# For a headless/pbuffer client export HYBRIS_EGLPLATFORM=null yourself.
if [ -z "\${AGB_HYBRIS_DIR:-}" ]; then
    _agb_here="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
    while [ ! -f "\$_agb_here/workspace.env" ]; do _agb_here="\$(dirname "\$_agb_here")"; done
    . "\$_agb_here/workspace.env"
fi
# Curated dirs (see hybris/scripts/make-gl-libs.sh / make-vk-libs.sh); they are
# also registered in /etc/ld.so.conf.d/00-hybris-gl.conf.  Never put prefix/lib
# itself here: it contains the Android libvulkan.so.1 that breaks libgtk-4.
export LD_LIBRARY_PATH="\$AGB_HYBRIS_DIR/gl-libs:\$AGB_HYBRIS_DIR/vk-libs"
export HYBRIS_LD_LIBRARY_PATH="\$AGB_HYBRIS_DIR/android-libs:$DEV_SYSTEM_LIBS:$DEV_VENDOR_LIBS:$DEV_VENDOR_LIBS/hw:$DEV_VENDOR_LIBS/egl:$DEV_ODM_LIBS:$DEV_BIONIC_LIBS"
export HYBRIS_LOGGING_LEVEL=warn
EOF
chmod +x "$ENV_FILE"

log "build probe_egl"
mkdir -p "$AGB_HYBRIS_DIR/bin"
gcc -O2 -o "$AGB_HYBRIS_DIR/bin/probe_egl" "$ASSETS_DIR/probe_egl.c" \
  -I"$PREFIX/include" -L"$PREFIX/lib" -lEGL -lGLESv2 -Wl,-rpath,"$PREFIX/lib"

log "refresh curated GL/VK lib dirs + ld.so cache"
"$AGB_HYBRIS_DIR/scripts/make-gl-libs.sh"
"$AGB_HYBRIS_DIR/scripts/make-vk-libs.sh"
ldconfig

echo
echo "All done. Run the probe:"
echo "  $AGB_HYBRIS_DIR/tests/probe_egl.sh"