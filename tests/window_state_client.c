/* Exercise real foreign-toplevel requests and state events. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "foreign-toplevel-client-protocol.h"

struct view {
	struct zwlr_foreign_toplevel_handle_v1 *handle;
	char app_id[128];
	int minimized, maximized;
};
static struct view views[128];
static size_t count;
static struct zwlr_foreign_toplevel_manager_v1 *manager;
static struct wl_seat *seat;
static void title(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s) {}
static void app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *s)
{ snprintf(((struct view *)data)->app_id, 128, "%s", s); }
static void output(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o) {}
static void state(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *array)
{
	struct view *v = data;
	uint32_t *value;
	v->minimized = v->maximized = 0;
	wl_array_for_each(value, array) {
		if (*value == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED) v->minimized = 1;
		if (*value == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED) v->maximized = 1;
	}
}
static void done(void *data, struct zwlr_foreign_toplevel_handle_v1 *h) {}
static void closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *h)
{ ((struct view *)data)->handle = NULL; zwlr_foreign_toplevel_handle_v1_destroy(h); }
static void parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
    struct zwlr_foreign_toplevel_handle_v1 *p) {}
static const struct zwlr_foreign_toplevel_handle_v1_listener listener = {
	.title = title, .app_id = app_id, .output_enter = output, .output_leave = output,
	.state = state, .done = done, .closed = closed, .parent = parent,
};
static void toplevel(void *data, struct zwlr_foreign_toplevel_manager_v1 *m,
    struct zwlr_foreign_toplevel_handle_v1 *h)
{
	if (count == 128) exit(2);
	views[count].handle = h;
	zwlr_foreign_toplevel_handle_v1_add_listener(h, &listener, &views[count++]);
}
static void finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *m) {}
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = {
	.toplevel = toplevel, .finished = finished,
};
static void global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version)
{
	if (!strcmp(interface, "zwlr_foreign_toplevel_manager_v1")) {
		manager = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, version < 3 ? version : 3);
		zwlr_foreign_toplevel_manager_v1_add_listener(manager, &manager_listener, NULL);
	} else if (!strcmp(interface, "wl_seat")) {
		seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
	}
}
static void removed(void *data, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
int main(int argc, char **argv)
{
	if (argc != 3 && argc != 4) return 2;
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) return 2;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0 || !manager) return 2;
	struct view *v = NULL;
	for (size_t i = 0; i < count; ++i)
		if (views[i].handle && !strcmp(views[i].app_id, argv[1])) v = &views[i];
	if (!v) return 2;
	if (!strcmp(argv[2], "minimize")) zwlr_foreign_toplevel_handle_v1_set_minimized(v->handle);
	else if (!strcmp(argv[2], "restore")) zwlr_foreign_toplevel_handle_v1_unset_minimized(v->handle);
	else if (!strcmp(argv[2], "activate") && seat) zwlr_foreign_toplevel_handle_v1_activate(v->handle, seat);
	else if (!strcmp(argv[2], "maximize")) zwlr_foreign_toplevel_handle_v1_set_maximized(v->handle);
	else if (!strcmp(argv[2], "unmaximize")) zwlr_foreign_toplevel_handle_v1_unset_maximized(v->handle);
	else if (strcmp(argv[2], "state")) return 2;
	if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0) return 2;
	FILE *reply = argc == 4 ? fopen(argv[3], "w") : stdout;
	if (!reply) return 2;
	fprintf(reply, "%d %d\n", v->minimized, v->maximized);
	if (argc == 4 && fclose(reply) != 0) return 2;
	wl_display_disconnect(display);
	return 0;
}
