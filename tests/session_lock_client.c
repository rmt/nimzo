/* Check that a lock request stays pending, then unlock after presentation. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>
#include "ext-session-lock-client-protocol.h"

static struct ext_session_lock_manager_v1 *manager;
static int result;
static int can_lock, can_create_surfaces, other_privileges;

static int mark(const char *path)
{
    FILE *file = fopen(path, "w");
    return file == NULL || fclose(file) != 0;
}

static void global(void *data, struct wl_registry *registry, uint32_t name,
    const char *interface, uint32_t version)
{
    if (!strcmp(interface, ext_session_lock_manager_v1_interface.name)) {
        can_lock = 1;
        if (data != NULL)
            manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
    } else if (!strcmp(interface, "wl_compositor")) {
        can_create_surfaces = 1;
    }
    const char *privileged[] = {
        "zwlr_export_dmabuf_manager_v1", "zwlr_screencopy_manager_v1",
        "ext_image_copy_capture_manager_v1", "ext_output_image_capture_source_manager_v1",
        "ext_foreign_toplevel_image_capture_source_manager_v1",
        "zwlr_data_control_manager_v1", "ext_data_control_manager_v1",
        "zwp_virtual_keyboard_manager_v1", "zwlr_virtual_pointer_manager_v1",
        "zwp_input_method_manager_v2", "zwlr_foreign_toplevel_manager_v1",
        "ext_foreign_toplevel_list_v1", "zwlr_output_manager_v1",
        "zwlr_output_power_manager_v1", "zwlr_gamma_control_manager_v1",
    };
    for (size_t i = 0; i < sizeof(privileged) / sizeof(privileged[0]); ++i)
        if (!strcmp(interface, privileged[i])) other_privileges = 1;
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = { global, removed };

static void locked(void *data, struct ext_session_lock_v1 *lock) { result = 1; }
static void finished(void *data, struct ext_session_lock_v1 *lock) { result = -1; }
static const struct ext_session_lock_v1_listener lock_listener = { locked, finished };

int main(int argc, char **argv)
{
    if (argc != 2 && argc != 3) return 2;
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, argc == 3 ? display : NULL);
    if (wl_display_roundtrip(display) < 0) return 2;
    if (!can_create_surfaces || other_privileges || can_lock != (argc == 3)) {
        fputs("Client received an incorrect set of Wayland globals\n", stderr);
        return 1;
    }
    if (argc == 2) {
        wl_registry_destroy(registry);
        wl_display_disconnect(display);
        return mark(argv[1]);
    }
    if (manager == NULL) return 2;

    /* The compositor test withholds one output frame until this round trip. */
    struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(manager);
    ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
    if (wl_display_roundtrip(display) < 0) return 2;
    if (result != 0) {
        fputs("Lock resolved before both outputs could present\n", stderr);
        return 1;
    }
    if (mark(argv[1])) return 2;

    while (result == 0 && wl_display_dispatch(display) >= 0) {}
    if (result != 1) return 1;
    ext_session_lock_v1_unlock_and_destroy(lock);
    ext_session_lock_manager_v1_destroy(manager);
    wl_registry_destroy(registry);
    int status = wl_display_roundtrip(display) < 0;
    wl_display_disconnect(display);
    return status != 0 ? status : mark(argv[2]);
}
