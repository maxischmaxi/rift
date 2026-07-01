package main

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libinput Bindings für Odin
//
//  libinput verarbeitet Input-Events vom Kernel (evdev) und liefert sie
//  an rift weiter. Ersetzt den Wayland-Pointer/Keyboard-Forwarding aus
//  dem Nested-Modus.
// ═══════════════════════════════════════════════════════════════════════════

foreign import libinput "system:input"

// ─── Opaque Types ──────────────────────────────────────────────────────────────
Libinput :: distinct struct {}
LibinputDevice :: distinct struct {}
LibinputSeat :: distinct struct {}
LibinputEvent :: distinct struct {}
LibinputEventKeyboard :: distinct struct {}
LibinputEventPointer :: distinct struct {}
LibinputEventTouch :: distinct struct {}
LibinputEventTabletTool :: distinct struct {}
LibinputEventTabletPad :: distinct struct {}
LibinputEventDeviceNotify :: distinct struct {}
LibinputDeviceGroup :: distinct struct {}

// ─── Enums ──────────────────────────────────────────────────────────────────────
LibinputEventType :: enum c.int {
	NONE = 0,
	DEVICE_ADDED,
	DEVICE_REMOVED,
	KEYBOARD_KEY = 300,
	POINTER_MOTION = 400,
	POINTER_MOTION_ABSOLUTE,
	POINTER_BUTTON,
	POINTER_AXIS,
	POINTER_SCROLL_WHEEL = 410,
	POINTER_SCROLL_FINGER,
	POINTER_SCROLL_CONTINUOUS,
	TOUCH_DOWN = 500,
	TOUCH_UP,
	TOUCH_MOTION,
	TOUCH_CANCEL,
	TOUCH_FRAME,
	TABLET_TOOL_PROXIMITY = 700,
	TABLET_TOOL_TIP,
	TABLET_TOOL_AXIS,
	TABLET_TOOL_BUTTON,
	TABLET_PAD_BUTTON = 800,
	TABLET_PAD_RING,
	TABLET_PAD_STRIP,
	TABLET_PAD_DIAL,
	GESTURE_SWIPE_BEGIN = 900,
	GESTURE_SWIPE_UPDATE,
	GESTURE_SWIPE_END,
	GESTURE_PINCH_BEGIN,
	GESTURE_PINCH_UPDATE,
	GESTURE_PINCH_END,
	GESTURE_HOLD_BEGIN,
	GESTURE_HOLD_END,
	SWITCH_TOGGLE = 1000,
}

LibinputKeyState :: enum c.int {
	RELEASED = 0,
	PRESSED = 1,
}

LibinputButtonState :: enum c.int {
	RELEASED = 0,
	PRESSED = 1,
}

LibinputPointerAxis :: enum c.int {
	SCROLL_VERTICAL = 0,
	SCROLL_HORIZONTAL = 1,
}

LibinputPointerAxisSource :: enum c.int {
	WHEEL = 0,
	FINGER = 1,
	CONTINUOUS = 2,
	WHEEL_TILT = 3,
}

LibinputDeviceCapability :: enum c.int {
	KEYBOARD     = 1 << 0,
	POINTER      = 1 << 1,
	TOUCH        = 1 << 2,
	TABLET_TOOL   = 1 << 3,
	TABLET_PAD    = 1 << 4,
	GESTURE      = 1 << 5,
	SWITCH       = 1 << 6,
}

LibinputLogPriority :: enum c.int {
	NONE    = 0,
	ERROR   = 1,
	INFO    = 2,
	DEBUG   = 3,
}

// ─── LibinputInterface (Callbacks für Device-Open/Close) ───────────────────────
LibinputOpenRestricted  :: proc "c" (path: cstring, flags: c.int, user_data: rawptr) -> c.int
LibinputCloseRestricted :: proc "c" (fd: c.int, user_data: rawptr)

LibinputInterface :: struct {
	open_restricted:  LibinputOpenRestricted,  // proc type, not pointer
	close_restricted: LibinputCloseRestricted,
}

// ─── Context ──────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_udev_create_context :: proc(
		interface: ^LibinputInterface,
		log_priority: LibinputLogPriority,
		udev: ^Udev,
	) -> ^Libinput ---

	libinput_path_create_context :: proc(
		interface: ^LibinputInterface,
		log_priority: LibinputLogPriority,
	) -> ^Libinput ---

	libinput_udev_assign_seat :: proc(li: ^Libinput, seat: cstring) -> c.int ---
	libinput_ref  :: proc(li: ^Libinput) -> ^Libinput ---
	libinput_unref :: proc(li: ^Libinput) -> ^Libinput ---
}

// ─── Event-Loop ─────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_get_fd     :: proc(li: ^Libinput) -> c.int ---
	libinput_dispatch   :: proc(li: ^Libinput) -> c.int ---
	// VT-Switch: Geräte pausieren/wieder öffnen (resume re-opent via udev-Seat)
	libinput_suspend    :: proc(li: ^Libinput) ---
	libinput_resume     :: proc(li: ^Libinput) -> c.int ---
}

// ─── Event-Reading ──────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_get_event       :: proc(li: ^Libinput) -> ^LibinputEvent ---
	libinput_next_event_type :: proc(li: ^Libinput) -> LibinputEventType ---
	libinput_event_destroy   :: proc(event: ^LibinputEvent) ---

	libinput_event_get_type   :: proc(event: ^LibinputEvent) -> LibinputEventType ---
	libinput_event_get_device :: proc(event: ^LibinputEvent) -> ^LibinputDevice ---
	libinput_event_get_time    :: proc(event: ^LibinputEvent) -> u64 ---
}

// ─── Keyboard Events ───────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_event_keyboard_get_base_event :: proc(e: ^LibinputEventKeyboard) -> ^LibinputEvent ---
	libinput_event_keyboard_get_key         :: proc(e: ^LibinputEventKeyboard) -> u32 ---
	libinput_event_keyboard_get_key_state   :: proc(e: ^LibinputEventKeyboard) -> LibinputKeyState ---
	libinput_event_keyboard_get_time        :: proc(e: ^LibinputEventKeyboard) -> u64 ---
}

// ─── Pointer Events ────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_event_pointer_get_base_event   :: proc(e: ^LibinputEventPointer) -> ^LibinputEvent ---
	libinput_event_pointer_get_time         :: proc(e: ^LibinputEventPointer) -> u64 ---
	libinput_event_pointer_get_time_usec    :: proc(e: ^LibinputEventPointer) -> u64 ---
	libinput_event_pointer_get_dx           :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_dy           :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_dx_unaccelerated :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_dy_unaccelerated :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_absolute_x   :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_absolute_y   :: proc(e: ^LibinputEventPointer) -> f64 ---
	libinput_event_pointer_get_button       :: proc(e: ^LibinputEventPointer) -> u32 ---
	libinput_event_pointer_get_button_state :: proc(e: ^LibinputEventPointer) -> LibinputButtonState ---
	libinput_event_pointer_get_seat_button_count :: proc(e: ^LibinputEventPointer) -> u32 ---
	libinput_event_pointer_get_axis_source   :: proc(e: ^LibinputEventPointer) -> LibinputPointerAxisSource ---
	libinput_event_pointer_get_axis_value    :: proc(e: ^LibinputEventPointer, axis: LibinputPointerAxis) -> f64 ---
	libinput_event_pointer_get_axis_value120 :: proc(e: ^LibinputEventPointer, axis: LibinputPointerAxis) -> f64 ---
}

// ─── Event Casting ──────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_event_get_keyboard_event :: proc(e: ^LibinputEvent) -> ^LibinputEventKeyboard ---
	libinput_event_get_pointer_event  :: proc(e: ^LibinputEvent) -> ^LibinputEventPointer ---
	libinput_event_get_touch_event    :: proc(e: ^LibinputEvent) -> ^LibinputEventTouch ---
}

// ─── Device Info ─────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_device_get_name :: proc(d: ^LibinputDevice) -> cstring ---
	libinput_device_get_sysname :: proc(d: ^LibinputDevice) -> cstring ---
	libinput_device_get_seat :: proc(d: ^LibinputDevice) -> ^LibinputSeat ---
	libinput_device_get_id_vendor :: proc(d: ^LibinputDevice) -> c.uint ---
	libinput_device_get_id_product :: proc(d: ^LibinputDevice) -> c.uint ---
	libinput_device_has_capability :: proc(d: ^LibinputDevice, cap: LibinputDeviceCapability) -> c.int ---
}

// ─── Seat ──────────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libinput {
	libinput_seat_get_logical_name :: proc(seat: ^LibinputSeat) -> cstring ---
	libinput_seat_get_physical_name :: proc(seat: ^LibinputSeat) -> cstring ---
}

// ─── Log Callback ───────────────────────────────────────────────────────────────
LibinputLogHandler :: proc "c" (li: ^Libinput, priority: LibinputLogPriority, format: cstring, args: rawptr)

@(default_calling_convention = "c")
foreign libinput {
	libinput_log_set_handler :: proc(li: ^Libinput, handler: ^LibinputLogHandler) ---
}