#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#include "lazyvk.h"

/* Hand-written runtime of the lazy Vulkan shim: everything else in this
 * directory is generated (scripts/gen-lazyvk.py).  The shim exports every
 * entrypoint as a tail-call stub (lazyvk.S) whose slot we fill from the real
 * hybris loader, so clients never link against the heavy Android loader
 * directly. */

/* In-tree fallback only: make-vk-libs.sh passes the real absolute path via
 * -DLAZYVK_DEFAULT_REAL at build time.  Clients normally resolve the shim
 * through ld.so.cache and set VK_REAL_SHIM. */
#ifndef LAZYVK_DEFAULT_REAL
#define LAZYVK_DEFAULT_REAL "/root/android-ubuntu-gl/hybris/vk-libs/libvulkan-hybris.so.1"
#endif

static int debug(void){ const char *d = getenv("LAZYVK_DEBUG"); return d && *d && *d != '0'; }

static void *real_handle(void){
    static void *h = (void*)-1;
    if (h != (void*)-1) return h;
    const char *p = getenv("VK_REAL_SHIM");
    if (!p) p = LAZYVK_DEFAULT_REAL;
    h = dlopen(p, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "[lazyvk] dlopen(%s) failed: %s\n", p, dlerror()); return NULL; }

    /* The loader's entrypoints are IFUNCs that forward into the Android-side
     * libvulkan (android_dlopen("libvulkan.so")); that handle only becomes
     * usable while the loader is still coming up, so a dlsym issued straight
     * from our constructor can spuriously return NULL.  Re-scan until a whole
     * pass resolves nothing new.  Each name is tried once more at most, since
     * the retry never lowers a slot.
     *
     * After the passes, the slots match the real loader exactly: whatever is
     * still NULL is not exported by the Android implementation at all (mostly
     * NV/INTEL/EXT entrypoints Mali does not provide) and must stay NULL -
     * that is how Vulkan reports "unsupported". */
    for (int pass = 0; pass < 64; pass++) {
        int progressed = 0;
        for (struct vkent *e = vk_ents; e->name; e++) {
            if (*e->slot) continue;
            void *s = dlsym(h, e->name);
            if (s) { *e->slot = s; progressed++; }
        }
        if (!progressed) break;
    }
    if (debug()) {
        int avail = 0, unsupported = 0;
        for (struct vkent *e = vk_ents; e->name; e++) {
            if (*e->slot) { avail++; continue; }
            unsupported++;
            fprintf(stderr, "[lazyvk] unsupported by driver: %s\n", e->name);
        }
        fprintf(stderr, "[lazyvk] %d entrypoints available, %d unsupported\n",
                avail, unsupported);
    }
    return h;
}

__attribute__((constructor))
static void lazyvk_init(void){ real_handle(); }

/* Reached only when a slot is NULL (unsupported entrypoint): tell the caller
 * and return a null result, which is the documented Vulkan answer for
 * unsupported functions (x0 = 0 is the first result register for every
 * vk* prototype). */
void *__lazyvk_unresolved(void){
    fprintf(stderr, "[lazyvk] called unresolved Vulkan entrypoint\n");
    return NULL;
}
