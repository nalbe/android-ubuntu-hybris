# android-ubuntu-hybris

libhybris build for the Mali GPU inside an Ubuntu chroot running on an Android
phone. It gives ordinary Ubuntu/glibc programs (GTK, GNOME Shell, mutter, zink)
working EGL, GLES and Vulkan by talking to the device's own Android vendor
driver, so the desktop renders on the real GPU instead of llvmpipe.

This repository is the `hybris/` part of the
[android-ubuntu-gl](https://github.com/nalbe/android-ubuntu-gl) workspace. It
stands alone: everything needed to build, install and test the GPU stack lives
here.

## Why this exists

Android and Ubuntu cannot simply share a GPU driver. The vendor driver is a
bionic (Android libc) binary that expects Android's linker, its own TLS layout
and its own gralloc/Vulkan loaders. libhybris bridges that gap from the glibc
side. Stock libhybris does not survive on this device without local fixes, and
that is what this repo packages:

- a patched bionic `libc.so` staged ahead of the device copy;
- a TLS-slot patch for the `tpidr_el0+32` collision that otherwise SIGSEGVs the
  Mali userspace driver under glibc;
- a gralloc patch so EGL initialises in headless/pbuffer mode;
- a lazy Vulkan shim, because loading the Android `libvulkan.so.1` directly
  breaks `libgtk-4`;
- curated runtime directories so clients never see the Android Vulkan loader.

## Verified target

| Item        | Value                                                        |
|-------------|--------------------------------------------------------------|
| Device      | Blackview SHARK 8                                            |
| SoC / GPU   | MediaTek MT6789 (Helio G99), Mali-G57 MC2, kbase r32p1       |
| Android     | 14 (SDK 34) GSI                                              |
| Kernel      | 5.10.223 GKI + KernelSU                                      |
| Userspace   | Ubuntu 24.04 arm64 chroot, reaching Android via `/proc/1/root` |
| libhybris   | Linux-on-droid fork, branch `lindroid-21`                    |

Other Mali devices on a similar GKI/GSI base are likely to work, but only this
one is tested. The build must run as root inside the Ubuntu chroot.

## Quick start

The scripts resolve the workspace through `workspace.env`, walking up from
their own directory. In the full android-ubuntu-gl workspace that file already
exists. When this repo is checked out on its own, provide a `workspace.env` in
the parent directory with at least:

```bash
AGB_HYBRIS_DIR=/path/to/android-ubuntu-hybris
AGB_LOG_DIR=/path/to/logs
```

Then build and probe:

```bash
./scripts/build.sh      # idempotent; reconfigures itself if the part moved
./tests/probe_egl.sh    # expect: GL_RENDERER: Mali-G57 MC2
```

`build.sh` installs the distro build dependencies, unpacks the bundled SDK 34
Android headers, stages the patched bionic libc, clones and builds libhybris,
installs it into `prefix/`, writes `env/hybris_env.sh`, builds the probe and
refreshes the curated GL/VK dirs.

To use the GPU in a session, source the generated env file first:

```bash
. ./env/hybris_env.sh
```

## What build.sh does

1. Installs apt build dependencies.
2. Unpacks the bundled Android headers (SDK 34).
3. Stages the hybris-patched bionic `libc.so` in `android-libs/`.
4. Clones `Linux-on-droid/libhybris` at `lindroid-21` (shallow).
5. Applies `gralloc-headless.patch`: EGL/gralloc init must not abort in
   headless mode, since pbuffer rendering does not need gralloc.
6. Applies `tls-patcher.patch`: redirects Android TLS slots so glibc's errno
   cannot clobber `TLS_SLOT_OPENGL` (the Mali driver's pointer).
7. Applies `tls-default-on.patch`: TLS patcher is on unless
   `HYBRIS_PATCH_TLS=0`; configure default EGL platform becomes `wayland`, so
   no `HYBRIS_*` variable is needed in the normal case.
8. Configures for arm64 with `--enable-mali-quirks`, `--enable-wayland`,
   `--disable-wayland_serverside_buffers` and installs into `prefix/`.
9. Symlinks every hybris library from `/usr/local/lib` into `prefix/lib`, so
   there is exactly one build on the system (mutter and GNOME Shell have
   `/usr/local/lib` in their runtime search path).
10. Writes `env/hybris_env.sh` and builds `bin/probe_egl`.
11. Refreshes `gl-libs/`, `vk-libs/` and the `ld.so` cache.

The Android `libvulkan.so.1` is deliberately kept out of the default linker
path: it breaks `libgtk-4`.

## Layout

| Path        | Contents                                                          |
|-------------|-------------------------------------------------------------------|
| `assets/`   | Patches, `probe_egl.c`, bundled Android headers, prebuilt libs     |
| `scripts/`  | `build.sh`, `make-gl-libs.sh`, `make-vk-libs.sh`, `gen-lazyvk.py`  |
| `lazyvk/`   | Lazy Vulkan shim (`libvulkan.so.1` front end + generated tables)   |
| `tests/`    | `probe_egl.sh` - headless EGL/GLES smoke test                      |
| `env/`      | `hybris_env.sh` - generated, source it before running clients      |
| `prefix/`   | Install prefix (generated)                                         |
| `gl-libs/`  | Curated EGL/GLES runtime dir (generated)                           |
| `vk-libs/`  | Curated Vulkan runtime dir (generated)                             |
| `android-headers/`, `android-libs/`, `libhybris/`, `bin/` | Generated, gitignored |

## The curated runtime dirs

`prefix/lib` contains the Android `libvulkan.so.1`, whose probe breaks
`libgtk-4`. Clients therefore never link `prefix/lib` directly:

- `gl-libs/` holds only the libhybris EGL/GLES libraries plus
  `libhybris-common`; their `DT_RUNPATH` points back into `prefix/lib` for the
  platform plugins.
- `vk-libs/` holds the lazy shim as `libvulkan.so.1`. Its constructor `dlopen`s
  the real hybris loader (`libvulkan-hybris.so.1` ->
  `prefix/lib/libvulkan.so.1.2.183`) and fills one tail-call trampoline per
  exported entry point. GTK resolves the light shim, never the heavy loader.
  The trampoline tables are regenerated from the loader's exports on every
  build, so the full loader API is covered (zink needs more than a hand-picked
  subset).
- Both dirs are registered in `/etc/ld.so.conf.d/00-hybris-gl.conf`.

The shim finds the real loader via `VK_REAL_SHIM`, or through the absolute path
compiled in by `make-vk-libs.sh` - no variable needed in the normal case.

## Environment

`env/hybris_env.sh` sets only linker configuration; the compiled-in defaults
already provide a working Mali driver:

| Variable                 | Purpose                                                  |
|--------------------------|----------------------------------------------------------|
| `LD_LIBRARY_PATH`        | `gl-libs:vk-libs` (never `prefix/lib`)                   |
| `HYBRIS_LD_LIBRARY_PATH` | staged bionic libc + device lib dirs via `/proc/1/root`  |
| `HYBRIS_LOGGING_LEVEL`   | `warn`                                                   |
| `HYBRIS_EGLPLATFORM`     | defaults to `wayland`; set `null` for headless clients   |
| `HYBRIS_PATCH_TLS`       | TLS patcher is on; set `0` to disable                    |
| `VK_REAL_SHIM`           | optional override for the real Vulkan loader path        |

## Prebuilt install

`assets/hybris-prebuilt.tar.gz` plus `assets/install-hybris.sh` is a shortcut
for a machine that only needs to run the stack, not build it:

```bash
sudo ./assets/install-hybris.sh /usr/local
```

This unpacks the prebuilt libraries into `$DEST/lib` and runs `ldconfig`. It is
independent of `build.sh`, which builds from source into `prefix/`.

## Testing

`tests/probe_egl.sh` builds and runs a headless pbuffer probe. A healthy result
looks like:

```text
GL_RENDERER : Mali-G57 MC2
GL_VERSION  : OpenGL ES 3.2 ...
DONE
```

## Notes

- Run everything as root inside the Ubuntu chroot; the device libraries are
  reached through `/proc/1/root`, which only root can follow reliably.
- The part is relocatable: scripts never embed an absolute path, and generated
  `gl-libs/` links are relative.
- Rebuilds are incremental. `build.sh` detects a moved part or a stale
  configure and cleans up automatically.

## Related

- [android-ubuntu-gl](https://github.com/nalbe/android-ubuntu-gl) - the whole
  GNOME-on-Android workspace (mutter AHB renderer, compositor, session, zink).
