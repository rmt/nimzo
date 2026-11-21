/* Protocol resource ownership; compositor policy stays in wlr_foreign_toplevel_management.nim. */
#include "nimzo_ffi.h"
#include "wlr_foreign_toplevel_management.h"

/* wlroots 0.20 provides ext listing, but not this taskbar management protocol. */
#include "wlr-foreign-toplevel-management-unstable-v1-protocol.h"
struct nimzo_wlr_toplevel_manager_client;
struct nimzo_wlr_toplevel_handle;
struct nimzo_wlr_toplevel_handle_instance;
struct nimzo_wlr_toplevel_output;
struct nimzo_wlr_toplevel_output_resource {
	struct wl_list link;
	struct wl_listener destroy;
	struct wl_resource *resource;
	struct nimzo_wlr_toplevel_output *output;
};
struct nimzo_wlr_toplevel_output {
	struct wl_list link;
	struct wl_listener bind;
	struct wl_listener destroy;
	void *output;
	struct wl_list resources;
};
struct nimzo_wlr_toplevel_handle_instance {
	struct wl_list link;
	struct wl_resource *resource;
	struct nimzo_wlr_toplevel_manager_client *manager;
	struct nimzo_wlr_toplevel_handle *handle;
};
struct nimzo_wlr_toplevel_handle {
	struct wl_list link;
	void *view;
	char *title, *app_id;
	void *output;
	int activated, maximized, minimized, fullscreen;
	struct wl_list instances;
};
struct nimzo_wlr_toplevel_manager_client {
	struct wl_list link;
	struct wl_resource *resource;
	int stopped;
};
static struct {
	struct wl_global *global;
	struct wl_list managers, handles, outputs;
	nimzo_wlr_toplevel_request_fn request;
} nimzo_wlr_toplevel_state;

static struct nimzo_wlr_toplevel_output *nimzo_wlr_toplevel_find_output(void *output)
{
	struct nimzo_wlr_toplevel_output *entry;
	wl_list_for_each(entry, &nimzo_wlr_toplevel_state.outputs, link)
		if (entry->output == output) return entry;
	return NULL;
}
static struct wl_resource *nimzo_wlr_toplevel_output_resource(
    struct nimzo_wlr_toplevel_output *output, struct wl_client *client)
{
	struct nimzo_wlr_toplevel_output_resource *resource;
	if (output == NULL) return NULL;
	wl_list_for_each(resource, &output->resources, link)
		if (wl_resource_get_client(resource->resource) == client)
			return resource->resource;
	return NULL;
}
static void nimzo_wlr_toplevel_instance_destroy(struct wl_resource *resource)
{
	struct nimzo_wlr_toplevel_handle_instance *instance =
		wl_resource_get_user_data(resource);
	if (instance == NULL) return;
	wl_list_remove(&instance->link);
	free(instance);
}
static void nimzo_wlr_toplevel_send_output(
    struct nimzo_wlr_toplevel_handle_instance *instance, void *output, int enter)
{
	struct nimzo_wlr_toplevel_output *entry;
	struct wl_resource *resource;
	if (instance == NULL || output == NULL) return;
	entry = nimzo_wlr_toplevel_find_output(output);
	resource = nimzo_wlr_toplevel_output_resource(entry,
	    wl_resource_get_client(instance->resource));
	if (resource == NULL) return;
	if (enter)
		zwlr_foreign_toplevel_handle_v1_send_output_enter(instance->resource, resource);
	else
		zwlr_foreign_toplevel_handle_v1_send_output_leave(instance->resource, resource);
}
static void nimzo_wlr_toplevel_send_state(struct nimzo_wlr_toplevel_handle_instance *instance)
{
	struct nimzo_wlr_toplevel_handle *handle = instance->handle;
	uint32_t states[4];
	size_t count = 0;
	if (handle->activated) states[count++] = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED;
	if (handle->maximized) states[count++] = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED;
	if (handle->minimized) states[count++] = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED;
	if (wl_resource_get_version(instance->resource) >= 2 && handle->fullscreen)
		states[count++] = ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN;
	struct wl_array state = { .size = count * sizeof(uint32_t), .data = states };
	zwlr_foreign_toplevel_handle_v1_send_state(instance->resource, &state);
}
static void nimzo_wlr_toplevel_send_snapshot(
    struct nimzo_wlr_toplevel_handle_instance *instance)
{
	struct nimzo_wlr_toplevel_handle *handle = instance->handle;
	zwlr_foreign_toplevel_handle_v1_send_title(instance->resource,
	    handle->title != NULL ? handle->title : "");
	zwlr_foreign_toplevel_handle_v1_send_app_id(instance->resource,
	    handle->app_id != NULL ? handle->app_id : "");
	nimzo_wlr_toplevel_send_state(instance);
	if (handle->output != NULL)
		nimzo_wlr_toplevel_send_output(instance, handle->output, 1);
	zwlr_foreign_toplevel_handle_v1_send_done(instance->resource);
}
static void nimzo_wlr_toplevel_request(struct nimzo_wlr_toplevel_handle_instance *instance,
    int request, struct wl_resource *seat, struct wl_resource *output)
{
	if (instance != NULL && instance->handle != NULL && nimzo_wlr_toplevel_state.request != NULL)
		nimzo_wlr_toplevel_state.request(instance->handle->view, request, seat,
		    output == NULL ? NULL : wlr_output_from_resource(output));
}
static void nimzo_wlr_toplevel_handle_max(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_SET_MAXIMIZED, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_unmax(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_UNSET_MAXIMIZED, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_min(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_SET_MINIMIZED, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_unmin(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_UNSET_MINIMIZED, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_activate(struct wl_client *c, struct wl_resource *r,
    struct wl_resource *seat)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_ACTIVATE, seat, NULL); }
static void nimzo_wlr_toplevel_handle_close(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_CLOSE, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_destroy(struct wl_client *c, struct wl_resource *r)
{ wl_resource_destroy(r); }
static void nimzo_wlr_toplevel_handle_fullscreen(struct wl_client *c, struct wl_resource *r,
    struct wl_resource *output)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_SET_FULLSCREEN,
    NULL, output); }
static void nimzo_wlr_toplevel_handle_unfullscreen(struct wl_client *c, struct wl_resource *r)
{ nimzo_wlr_toplevel_request(wl_resource_get_user_data(r), NIMZO_WLR_TOPLEVEL_UNSET_FULLSCREEN, NULL, NULL); }
static void nimzo_wlr_toplevel_handle_rectangle(struct wl_client *c,
    struct wl_resource *r, struct wl_resource *surface,
    int32_t x, int32_t y, int32_t width, int32_t height)
{ (void)c; (void)r; (void)surface; (void)x; (void)y; (void)width; (void)height; }
static const struct zwlr_foreign_toplevel_handle_v1_interface
    nimzo_wlr_toplevel_handle_implementation = {
	.set_maximized = nimzo_wlr_toplevel_handle_max,
	.unset_maximized = nimzo_wlr_toplevel_handle_unmax,
	.set_minimized = nimzo_wlr_toplevel_handle_min,
	.unset_minimized = nimzo_wlr_toplevel_handle_unmin,
	.activate = nimzo_wlr_toplevel_handle_activate,
	.close = nimzo_wlr_toplevel_handle_close,
	.set_rectangle = nimzo_wlr_toplevel_handle_rectangle,
	.destroy = nimzo_wlr_toplevel_handle_destroy,
	.set_fullscreen = nimzo_wlr_toplevel_handle_fullscreen,
	.unset_fullscreen = nimzo_wlr_toplevel_handle_unfullscreen,
};
static void nimzo_wlr_toplevel_add_instance(
    struct nimzo_wlr_toplevel_manager_client *manager,
    struct nimzo_wlr_toplevel_handle *handle)
{
	struct nimzo_wlr_toplevel_handle_instance *instance = calloc(1, sizeof(*instance));
	if (instance == NULL) return;
	instance->resource = wl_resource_create(wl_resource_get_client(manager->resource),
	    &zwlr_foreign_toplevel_handle_v1_interface, wl_resource_get_version(manager->resource), 0);
	if (instance->resource == NULL) { free(instance); return; }
	instance->manager = manager;
	instance->handle = handle;
	wl_list_insert(&handle->instances, &instance->link);
	wl_resource_set_implementation(instance->resource,
	    &nimzo_wlr_toplevel_handle_implementation, instance, nimzo_wlr_toplevel_instance_destroy);
	zwlr_foreign_toplevel_manager_v1_send_toplevel(manager->resource, instance->resource);
	nimzo_wlr_toplevel_send_snapshot(instance);
}
static void nimzo_wlr_toplevel_manager_destroy(struct wl_resource *resource)
{
	struct nimzo_wlr_toplevel_manager_client *manager = wl_resource_get_user_data(resource);
	struct nimzo_wlr_toplevel_handle *handle;
	struct nimzo_wlr_toplevel_handle_instance *instance;
	if (manager == NULL) return;
	wl_list_for_each(handle, &nimzo_wlr_toplevel_state.handles, link)
		wl_list_for_each(instance, &handle->instances, link)
			if (instance->manager == manager) instance->manager = NULL;
	wl_list_remove(&manager->link);
	free(manager);
}
static void nimzo_wlr_toplevel_manager_stop(struct wl_client *c, struct wl_resource *r)
{
	struct nimzo_wlr_toplevel_manager_client *manager = wl_resource_get_user_data(r);
	if (manager == NULL || manager->stopped) return;
	manager->stopped = 1;
	zwlr_foreign_toplevel_manager_v1_send_finished(r);
	wl_resource_destroy(r);
}
static const struct zwlr_foreign_toplevel_manager_v1_interface
    nimzo_wlr_toplevel_manager_implementation = { .stop = nimzo_wlr_toplevel_manager_stop };
static void nimzo_wlr_toplevel_bind(struct wl_client *client, void *data,
    uint32_t version, uint32_t id)
{
	struct nimzo_wlr_toplevel_manager_client *manager = calloc(1, sizeof(*manager));
	struct nimzo_wlr_toplevel_handle *handle;
	if (manager == NULL) return;
	manager->resource = wl_resource_create(client, &zwlr_foreign_toplevel_manager_v1_interface,
	    version > 3 ? 3 : version, id);
	if (manager->resource == NULL) { free(manager); return; }
	wl_list_insert(&nimzo_wlr_toplevel_state.managers, &manager->link);
	wl_resource_set_implementation(manager->resource,
	    &nimzo_wlr_toplevel_manager_implementation, manager,
	    nimzo_wlr_toplevel_manager_destroy);
	wl_list_for_each(handle, &nimzo_wlr_toplevel_state.handles, link)
		nimzo_wlr_toplevel_add_instance(manager, handle);
}
static void nimzo_wlr_toplevel_output_resource_destroy(struct wl_listener *listener, void *data)
{
	struct nimzo_wlr_toplevel_output_resource *resource =
		wl_container_of(listener, resource, destroy);
	wl_list_remove(&resource->link);
	wl_list_remove(&resource->destroy.link);
	free(resource);
}
static void nimzo_wlr_toplevel_output_bind(struct wl_listener *listener, void *data)
{
	struct nimzo_wlr_toplevel_output *output = wl_container_of(listener, output, bind);
	struct wlr_output_event_bind *event = data;
	struct nimzo_wlr_toplevel_output_resource *resource = calloc(1, sizeof(*resource));
	struct nimzo_wlr_toplevel_handle *handle;
	struct nimzo_wlr_toplevel_handle_instance *instance;
	if (resource == NULL) return;
	resource->output = output;
	resource->resource = event->resource;
	resource->destroy.notify = nimzo_wlr_toplevel_output_resource_destroy;
	wl_list_insert(&output->resources, &resource->link);
	wl_resource_add_destroy_listener(event->resource, &resource->destroy);
	wl_list_for_each(handle, &nimzo_wlr_toplevel_state.handles, link) {
		if (handle->output != output->output) continue;
		wl_list_for_each(instance, &handle->instances, link)
			if (wl_resource_get_client(instance->resource) ==
			    wl_resource_get_client(event->resource))
				nimzo_wlr_toplevel_send_output(instance, output->output, 1);
	}
}
static void nimzo_wlr_toplevel_remove_output_internal(struct nimzo_wlr_toplevel_output *output)
{
	struct nimzo_wlr_toplevel_handle *handle;
	struct nimzo_wlr_toplevel_handle_instance *instance;
	struct nimzo_wlr_toplevel_output_resource *resource, *tmp;
	if (output == NULL) return;
	wl_list_for_each(handle, &nimzo_wlr_toplevel_state.handles, link)
		if (handle->output == output->output) {
			wl_list_for_each(instance, &handle->instances, link)
				nimzo_wlr_toplevel_send_output(instance, output->output, 0);
			handle->output = NULL;
		}
	wl_list_for_each_safe(resource, tmp, &output->resources, link) {
		wl_list_remove(&resource->destroy.link);
		wl_list_remove(&resource->link);
		free(resource);
	}
	wl_list_remove(&output->bind.link);
	wl_list_remove(&output->destroy.link);
	wl_list_remove(&output->link);
	free(output);
}
static void nimzo_wlr_toplevel_output_destroy(struct wl_listener *listener, void *data)
{
	struct nimzo_wlr_toplevel_output *output = wl_container_of(listener, output, destroy);
	nimzo_wlr_toplevel_remove_output_internal(output);
}
void nimzo_wlr_toplevel_init(void *display,
    nimzo_wlr_toplevel_request_fn request)
{
	wl_list_init(&nimzo_wlr_toplevel_state.managers);
	wl_list_init(&nimzo_wlr_toplevel_state.handles);
	wl_list_init(&nimzo_wlr_toplevel_state.outputs);
	nimzo_wlr_toplevel_state.request = request;
	nimzo_wlr_toplevel_state.global = wl_global_create(display,
	    &zwlr_foreign_toplevel_manager_v1_interface, 3, NULL, nimzo_wlr_toplevel_bind);
}
void nimzo_wlr_toplevel_output_add(void *output)
{
	struct nimzo_wlr_toplevel_output *entry;
	if (output == NULL || nimzo_wlr_toplevel_find_output(output) != NULL) return;
	entry = calloc(1, sizeof(*entry));
	if (entry == NULL) return;
	entry->output = output;
	wl_list_init(&entry->resources);
	entry->bind.notify = nimzo_wlr_toplevel_output_bind;
	entry->destroy.notify = nimzo_wlr_toplevel_output_destroy;
	wl_signal_add(&((struct wlr_output *)output)->events.bind, &entry->bind);
	wl_signal_add(&((struct wlr_output *)output)->events.destroy, &entry->destroy);
	wl_list_insert(&nimzo_wlr_toplevel_state.outputs, &entry->link);
}
void nimzo_wlr_toplevel_sync(void *view, const char *title, const char *app_id,
    void *output, int visible, int activated, int maximized, int minimized, int fullscreen)
{
	struct nimzo_wlr_toplevel_handle *handle = NULL, *candidate;
	struct nimzo_wlr_toplevel_manager_client *manager;
	struct nimzo_wlr_toplevel_handle_instance *instance;
	wl_list_for_each(candidate, &nimzo_wlr_toplevel_state.handles, link)
		if (candidate->view == view) { handle = candidate; break; }
	const int created = handle == NULL;
	if (!visible) output = NULL;
	if (!created && handle->output == output &&
	    handle->activated == (activated != 0) && handle->maximized == (maximized != 0) &&
	    handle->minimized == (minimized != 0) &&
	    handle->fullscreen == (fullscreen != 0) &&
	    strcmp(handle->title ? handle->title : "", title ? title : "") == 0 &&
	    strcmp(handle->app_id ? handle->app_id : "", app_id ? app_id : "") == 0)
		return;
	if (handle == NULL) {
		handle = calloc(1, sizeof(*handle));
		if (handle == NULL) return;
		handle->view = view;
		wl_list_init(&handle->instances);
		wl_list_insert(&nimzo_wlr_toplevel_state.handles, &handle->link);
	}
	if (strcmp(handle->title != NULL ? handle->title : "",
	    title != NULL ? title : "") != 0) {
		free(handle->title); handle->title = strdup(title != NULL ? title : "");
		wl_list_for_each(instance, &handle->instances, link)
			zwlr_foreign_toplevel_handle_v1_send_title(instance->resource,
			    handle->title != NULL ? handle->title : "");
	}
	if (strcmp(handle->app_id != NULL ? handle->app_id : "",
	    app_id != NULL ? app_id : "") != 0) {
		free(handle->app_id); handle->app_id = strdup(app_id != NULL ? app_id : "");
		wl_list_for_each(instance, &handle->instances, link)
			zwlr_foreign_toplevel_handle_v1_send_app_id(instance->resource,
			    handle->app_id != NULL ? handle->app_id : "");
	}
	handle->activated = activated != 0;
	handle->maximized = maximized != 0;
	handle->minimized = minimized != 0;
	handle->fullscreen = fullscreen != 0;
	if (handle->output != output) {
		wl_list_for_each(instance, &handle->instances, link) {
			if (handle->output != NULL)
				nimzo_wlr_toplevel_send_output(instance, handle->output, 0);
			if (output != NULL) nimzo_wlr_toplevel_send_output(instance, output, 1);
		}
		handle->output = output;
	}
	if (created) {
		wl_list_for_each(manager, &nimzo_wlr_toplevel_state.managers, link)
			if (!manager->stopped) nimzo_wlr_toplevel_add_instance(manager, handle);
		return;
	}
	wl_list_for_each(instance, &handle->instances, link) {
		nimzo_wlr_toplevel_send_state(instance);
		zwlr_foreign_toplevel_handle_v1_send_done(instance->resource);
	}
}
void nimzo_wlr_toplevel_remove_view(void *view)
{
	struct nimzo_wlr_toplevel_handle *handle, *tmp;
	struct nimzo_wlr_toplevel_handle_instance *instance, *instance_tmp;
	wl_list_for_each_safe(handle, tmp, &nimzo_wlr_toplevel_state.handles, link)
		if (handle->view == view) {
			/* The view can go away before the client destroys its closed resource.
			 * Detach the instance so late requests cannot reach the freed view. */
			wl_list_for_each_safe(instance, instance_tmp, &handle->instances, link) {
				zwlr_foreign_toplevel_handle_v1_send_closed(instance->resource);
				wl_list_remove(&instance->link);
				wl_list_init(&instance->link);
				instance->handle = NULL;
				instance->manager = NULL;
			}
			wl_list_remove(&handle->link);
			free(handle->title); free(handle->app_id); free(handle);
			return;
		}
}
void nimzo_wlr_toplevel_finish(void)
{
	struct nimzo_wlr_toplevel_handle *handle, *handle_tmp;
	struct nimzo_wlr_toplevel_output *output, *output_tmp;
	struct nimzo_wlr_toplevel_manager_client *manager, *manager_tmp;
	if (nimzo_wlr_toplevel_state.global != NULL)
		wl_global_destroy(nimzo_wlr_toplevel_state.global);
	wl_list_for_each_safe(handle, handle_tmp, &nimzo_wlr_toplevel_state.handles, link)
		nimzo_wlr_toplevel_remove_view(handle->view);
	wl_list_for_each_safe(output, output_tmp, &nimzo_wlr_toplevel_state.outputs, link)
		nimzo_wlr_toplevel_remove_output_internal(output);
	wl_list_for_each_safe(manager, manager_tmp, &nimzo_wlr_toplevel_state.managers, link)
		wl_resource_destroy(manager->resource);
	memset(&nimzo_wlr_toplevel_state, 0, sizeof(nimzo_wlr_toplevel_state));
}
