#include <stdio.h>
#include <GLES2/gl2.h>
#include <EGL/egl.h>

int main(void)
{
    printf("probe: hybris EGL/GLES2 headless\n");
    fflush(stdout);

    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    printf("  eglGetDisplay=%p err=0x%x\n", (void *)dpy, (unsigned)eglGetError());
    if (dpy == EGL_NO_DISPLAY) { printf("  FAIL: no display\n"); return 2; }

    if (!eglInitialize(dpy, 0, 0)) { printf("  FAIL: eglInitialize err=0x%x\n", (unsigned)eglGetError()); return 3; }
    printf("  EGL_VERSION : %s\n", eglQueryString(dpy, EGL_VERSION));
    printf("  EGL_VENDOR  : %s\n", eglQueryString(dpy, EGL_VENDOR));
    printf("  CLIENT_APIS : %s\n", eglQueryString(dpy, EGL_CLIENT_APIS));

    EGLint attr[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg; EGLint n = 0;
    eglChooseConfig(dpy, attr, &cfg, 1, &n);
    printf("  chooseConfig n=%d err=0x%x\n", n, (unsigned)eglGetError());
    if (n < 1) return 4;

    EGLint pbattrs[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pbattrs);
    printf("  pbuffer=%p err=0x%x\n", (void *)surf, (unsigned)eglGetError());

    EGLint ctxattrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxattrs);
    printf("  context=%p err=0x%x\n", (void *)ctx, (unsigned)eglGetError());
    if (ctx == EGL_NO_CONTEXT) return 5;

    EGLBoolean mc = eglMakeCurrent(dpy, surf, surf, ctx);
    printf("  makeCurrent=%d err=0x%x\n", (int)mc, (unsigned)eglGetError());
    if (!mc) return 6;

    printf("  GL_RENDERER : %s\n", glGetString(GL_RENDERER));
    printf("  GL_VERSION  : %s\n", glGetString(GL_VERSION));
    printf("  GL_VENDOR   : %s\n", glGetString(GL_VENDOR));

    glClearColor(0.2f, 0.4f, 0.8f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    printf("  post-clear err=0x%x\n", (unsigned)glGetError());

    eglSwapBuffers(dpy, surf);
    printf("  swapBuffers err=0x%x\n", (unsigned)eglGetError());
    printf("DONE\n");
    fflush(stdout);
    return 0;
}