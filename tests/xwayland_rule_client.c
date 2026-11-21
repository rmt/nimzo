/* Real X11 WM_CLASS instance/class values for the new-window rule test. */
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>

int main(void) {
    int screen_number;
    xcb_connection_t *connection = xcb_connect(NULL, &screen_number);
    if (xcb_connection_has_error(connection)) return 1;
    xcb_screen_iterator_t screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    while (screen_number-- > 0) xcb_screen_next(&screens);
    xcb_screen_t *screen = screens.data;
    xcb_window_t window = xcb_generate_id(connection);
    uint32_t background = screen->white_pixel;
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, window, screen->root,
        0, 0, 180, 140, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual,
        XCB_CW_BACK_PIXEL, &background);
    const char wm_class[] = "piano-ui\0Pianoteq 9";
    const char title[] = "Pianoteq v9.1.2";
    xcb_change_property(connection, XCB_PROP_MODE_REPLACE, window, XCB_ATOM_WM_CLASS,
        XCB_ATOM_STRING, 8, sizeof(wm_class), wm_class);
    xcb_change_property(connection, XCB_PROP_MODE_REPLACE, window, XCB_ATOM_WM_NAME,
        XCB_ATOM_STRING, 8, strlen(title), title);
    xcb_map_window(connection, window);
    xcb_flush(connection);
    xcb_generic_event_t *event;
    while ((event = xcb_wait_for_event(connection))) free(event);
    xcb_disconnect(connection);
    return 0;
}
