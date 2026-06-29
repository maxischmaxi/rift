package wayland
foreign import wl_cursor_lib "system:wayland-cursor"


cursor_theme :: struct{}


/** A still image part of a cursor
 *
 * Use `cursor_image_get_buffer()` to get the corresponding `struct
 * buffer` to attach to your `struct surface`. */
cursor_image  :: struct {
	/** Actual width */
	width: u32,

	/** Actual height */
	height: u32,

	/** Hot spot x (must be inside image) */
	hotspot_x: u32,

	/** Hot spot y (must be inside image) */
	hotspot_y: u32,

	/** Animation delay to next frame (ms) */
	delay: u32,
}

/** A cursor, as returned by `cursor_theme_get_cursor()` */
cursor :: struct {
	/** How many images there are in this cursor’s animation */
	image_count: uint,

	/** The array of still images composing this animation */
	images: [^]^cursor_image,

	/** The name of this cursor */
	name: cstring,
}

@(default_calling_convention="c")
@(link_prefix="wl_")
foreign wl_cursor_lib {
	cursor_theme_load :: proc(name: cstring, size: int, shm: ^shm) -> ^cursor_theme ---

	cursor_theme_destroy :: proc(theme: ^cursor_theme) ---

	cursor_theme_get_cursor :: proc(theme: ^cursor_theme, name: cstring) -> ^cursor ---

	cursor_image_get_buffer :: proc(image: cursor_image) -> ^buffer ---

	cursor_frame :: proc(cursor: ^cursor, time: u32) -> int ---

	cursor_frame_and_duration :: proc(cursor: ^cursor, time: u32, duration: ^u32) -> int ---
}