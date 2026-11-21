#ifndef NIMZO_WLR_FOREIGN_TOPLEVEL_MANAGEMENT_H
#define NIMZO_WLR_FOREIGN_TOPLEVEL_MANAGEMENT_H

enum {
    NIMZO_WLR_TOPLEVEL_ACTIVATE = 1,
    NIMZO_WLR_TOPLEVEL_CLOSE = 2,
    NIMZO_WLR_TOPLEVEL_SET_MAXIMIZED = 3,
    NIMZO_WLR_TOPLEVEL_UNSET_MAXIMIZED = 4,
    NIMZO_WLR_TOPLEVEL_SET_MINIMIZED = 5,
    NIMZO_WLR_TOPLEVEL_UNSET_MINIMIZED = 6,
    NIMZO_WLR_TOPLEVEL_SET_FULLSCREEN = 7,
    NIMZO_WLR_TOPLEVEL_UNSET_FULLSCREEN = 8,
};

typedef void (*nimzo_wlr_toplevel_request_fn)(void *view, int request, void *seat, void *output);
void nimzo_wlr_toplevel_init(void *display, nimzo_wlr_toplevel_request_fn request);
void nimzo_wlr_toplevel_finish(void);
void nimzo_wlr_toplevel_output_add(void *output);
void nimzo_wlr_toplevel_sync(void *view, const char *title, const char *app_id,
    void *output, int visible, int activated, int maximized, int minimized, int fullscreen);
void nimzo_wlr_toplevel_remove_view(void *view);

#endif
