# hybris — libhybris for the Mali GPU

Builds libhybris against the device's Android libs, installs it into `prefix/`,
and prepares the two curated runtime dirs the desktop needs.

## Layout

| Path        | Contents                                                        |
|-------------|-----------------------------------------------------------------|
| `libhybris/`| Upstream libhybris checkout with the local patches (own repo)    |
| `assets/`   | Patches + `probe_egl.c` + the prebuilt Android headers tarball   |
| `scripts/`  | `build.sh`, `make-gl-libs.sh`, `make-vk-libs.sh`, `gen-lazyvk.py`|
| `env/`      | `hybris_env.sh` — generated, source it before running binaries   |
| `lazyvk/`   | Lazy Vulkan shim (`libvulkan.so.1` → hybris loader)              |
| `tests/`    | `probe_egl.sh` — headless EGL/GLES smoke test                    |
| `prefix/`   | Install prefix (generated)                                       |
| `gl-libs/`, `vk-libs/` | Curated runtime dirs (generated)                      |

## Build

```bash
./scripts/build.sh        # idempotent; reconfigures itself if it was moved
./tests/probe_egl.sh      # expect "GL_RENDERER: Mali-G57 MC2"
```

## Why the curated dirs

`prefix/lib` also contains the Android `libvulkan.so.1`, whose probe breaks
libgtk-4. Clients therefore link against `gl-libs/` (only libhybris EGL/GLES +
libhybris-common) and `vk-libs/` (the lazy shim), never `prefix/lib` directly.
Both dirs are registered in `/etc/ld.so.conf.d/00-hybris-gl.conf`.

The shim's real driver is located via `VK_REAL_SHIM`, or from the absolute path
compiled in by `make-vk-libs.sh` — no env var needed in the normal case.
