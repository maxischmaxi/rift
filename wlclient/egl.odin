package wayland
foreign import wl_egl_lib "system:wayland-egl"

egl_window :: struct {}


@(default_calling_convention="c")
@(link_prefix="wl_")
foreign wl_egl_lib {
	egl_window_create :: proc(surface: ^surface, width: int, height: int) -> ^egl_window ---

	egl_window_destroy :: proc(window: ^egl_window) ---

	/* The dx,dy are the x,y arguments to wl_surface.attach request. If you
	have a floating top-level window, setting these to non-zero should
	cause the window to move. They are used to tell how many columns and
	rows of pixels to remove from the top/left of the surface, when a
	surface spontaneously (programmatically by the client, not a user or
	server performed resize) changes size. */
	egl_window_resize :: proc(window: ^egl_window, width: int, height: int, dx: int, dy: int) ---

	egl_window_get_attached_size :: proc(window: ^egl_window, width: ^int, height: ^int) ---
}
