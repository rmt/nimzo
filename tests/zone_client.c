/* Minimal real XDG client for compositor interaction tests. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wl_surface *surface;
static struct xdg_surface *xdg;
static int width = 180, height = 140, running = 1;
static uint32_t color = 0xff305070;
static volatile sig_atomic_t run_action;

static void request_action(int signum) {
    (void)signum;
    run_action = 1;
}

static void release_buffer(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = { .release = release_buffer };

static void draw(struct wl_surface *target, int width, int height) {
    size_t size = (size_t)width * height * 4;
    int fd = memfd_create("nimzo-zone-client", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) exit(2);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) exit(2);
    for (size_t i = 0; i < size / 4; ++i) pixels[i] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
        width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    wl_surface_attach(target, buffer, 0, 0);
    wl_surface_damage_buffer(target, 0, 0, width, height);
    wl_surface_commit(target);
}
static void configure_surface(void *data, struct xdg_surface *object, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(object, serial);
    draw(surface, width, height);
}
static const struct xdg_surface_listener surface_listener = { .configure = configure_surface };

static void configure_popup_surface(void *data, struct xdg_surface *object, uint32_t serial) {
    xdg_surface_ack_configure(object, serial);
    draw(data, 80, 160);
}
static const struct xdg_surface_listener popup_surface_listener = {
    .configure = configure_popup_surface
};

static void configure_popup(void *data, struct xdg_popup *popup,
        int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)data; (void)popup; (void)x; (void)y; (void)w; (void)h;
}
static void popup_done(void *data, struct xdg_popup *popup) {
    (void)data; (void)popup;
    running = 0;
}
static const struct xdg_popup_listener popup_listener = {
    .configure = configure_popup, .popup_done = popup_done
};

static void open_popup(void) {
    struct wl_surface *menu = wl_compositor_create_surface(compositor);
    struct xdg_surface *menu_xdg = xdg_wm_base_get_xdg_surface(wm, menu);
    xdg_surface_add_listener(menu_xdg, &popup_surface_listener, menu);
    struct xdg_positioner *positioner = xdg_wm_base_create_positioner(wm);
    xdg_positioner_set_size(positioner, 80, 160);
    xdg_positioner_set_anchor_rect(positioner, 10, 0, 30, 8);
    xdg_positioner_set_anchor(positioner, XDG_POSITIONER_ANCHOR_BOTTOM_LEFT);
    xdg_positioner_set_gravity(positioner, XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT);
    struct xdg_popup *popup = xdg_surface_get_popup(menu_xdg, xdg, positioner);
    xdg_popup_add_listener(popup, &popup_listener, NULL);
    xdg_positioner_destroy(positioner);
    wl_surface_commit(menu);
}

static void configure_toplevel(void *data, struct xdg_toplevel *object,
        int32_t w, int32_t h, struct wl_array *states) {
    (void)data; (void)object; (void)states;
    if (w > 0) width = w;
    if (h > 0) height = h;
}
static void close_toplevel(void *data, struct xdg_toplevel *object) {
    (void)data; (void)object;
    running = 0;
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = configure_toplevel, .close = close_toplevel
};
static void ping(void *data, struct xdg_wm_base *object, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(object, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name,
        const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base"))
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 2);
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_remove
};
int main(int argc, char **argv) {
    display = wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !wm) return 2;
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    surface = wl_compositor_create_surface(compositor);
    xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(top, argc > 1 ? argv[1] : "zone-test");
    int untitled = argc > 2 && !strcmp(argv[2], "fixed-untitled");
    int with_popup = argc > 2 && !strcmp(argv[2], "fixed-popup");
    if (!untitled)
        xdg_toplevel_set_title(top, argc > 3 ? argv[3] : argc > 1 ? argv[1] : "zone-test");
    if (untitled || with_popup || (argc > 2 && !strcmp(argv[2], "fixed"))) {
        xdg_toplevel_set_min_size(top, width, height);
        xdg_toplevel_set_max_size(top, width, height);
    }
    if (argc > 1) color += (uint32_t)(unsigned char)argv[1][0] * 0x00030102;
    wl_surface_commit(surface);
    if (argc > 4 || with_popup) {
        /* Perform a protocol action on request from the compositor test. */
        struct sigaction action = { .sa_handler = request_action };
        sigemptyset(&action.sa_mask);
        sigaction(SIGUSR1, &action, NULL);
        int next_title = 4;
        while (running) {
            if (run_action) {
                run_action = 0;
                if (with_popup) {
                    open_popup();
                    with_popup = 0;
                } else if (next_title < argc) {
                    xdg_toplevel_set_title(top, argv[next_title++]);
                    wl_surface_commit(surface);
                }
            }
            if (wl_display_dispatch_pending(display) < 0) break;
            wl_display_flush(display);
            struct pollfd fd = { .fd = wl_display_get_fd(display), .events = POLLIN };
            int result = poll(&fd, 1, 250);
            if (result < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (fd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
            if ((fd.revents & POLLIN) && wl_display_dispatch(display) < 0) break;
        }
    } else {
        while (running && wl_display_dispatch(display) >= 0) {}
    }
    wl_display_disconnect(display);
    return 0;
}
