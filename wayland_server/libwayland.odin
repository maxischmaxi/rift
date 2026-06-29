package wayland_server

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libwayland-server Bindings — Teil A: Core API
//  Quelle: /usr/include/wayland-server-core.h + wayland-util.h
//
//  Was hier NICHT steht: die Protokoll-Interfaces (wl_compositor_interface
//  etc.) — siehe protocol.odin (generiert via wayland-scanner).
// ═══════════════════════════════════════════════════════════════════════════

// ─── Opaque Structs (Interna egal; wir reichen Pointer weiter) ──────────
wl_event_loop :: struct {}
wl_event_source :: struct {}
wl_display :: struct {}
wl_client :: struct {}
wl_resource :: struct {}
wl_global :: struct {}
wl_shm_buffer :: struct {}
wl_shm_pool :: struct {}
wl_protocol_logger :: struct {}
wl_object :: struct {} // deprecated, aber in wl_argument referenziert

// ─── Konkrete Structs (Layout wichtig!) ─────────────────────────────────

// wayland-util.h: intrusive doubly-linked list
wl_list :: struct {
	prev: ^wl_list,
	next: ^wl_list,
}

// wayland-server-core.h: listener = Eintrag in einer wl_signal
wl_listener :: struct {
	link:   wl_list,
	notify: wl_notify_func_t,
}

// wayland-server-core.h: signal = Sammlung von listeners
wl_signal :: struct {
	listener_list: wl_list,
}

// wayland-util.h: Protokoll-Nachrichten-Signatur (Request/Event)
wl_message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^wl_interface,
}

// wayland-util.h: Interface-Deskriptor (wird in protocol.odin gebunden)
wl_interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      [^]wl_message,
	event_count:  c.int,
	events:       [^]wl_message,
}

// wayland-util.h: dynamisches Array
wl_array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

// wayland-util.h: Argument-Union für das Wire-Format
// i=int, u=uint, f=fixed, s=string, o=object, n=new_id, a=array, h=fd
wl_argument :: struct {
	_storage: [size_of(rawptr)]u8, // RAW union, 8 Byte = sizeof(void*)
}

// wayland-server-core.h: Logger-Nachricht
wl_protocol_logger_message :: struct {
	resource:        ^wl_resource,
	message_opcode:  c.int,
	message:         ^wl_message,
	arguments_count: c.int,
	arguments:       [^]wl_argument,
}

// ─── Enums ──────────────────────────────────────────────────────────────
wl_iterator_result :: enum c.int {
	STOP     = 0,
	CONTINUE = 1,
}

wl_protocol_logger_type :: enum c.int {
	REQUEST = 0,
	EVENT   = 1,
}

// ─── Event-Masken (Konstanten) ───────────────────────────────────────────
WL_EVENT_READABLE :: u32(0x01)
WL_EVENT_WRITABLE :: u32(0x02)
WL_EVENT_HANGUP :: u32(0x04)
WL_EVENT_ERROR :: u32(0x08)

// ─── Basis-Typen aus wayland-util.h ─────────────────────────────────────
wl_fixed_t :: i32 // 24.8 signed fixed-point

// POSIX-Credential-Typen (nicht in core:c; Linux-ABI: pid=i32, uid/gid=u32)
pid_t :: i32
uid_t :: u32
gid_t :: u32

// ─── Funktionspointer-Typen (Callbacks) ─────────────────────────────────
wl_event_loop_fd_func_t :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int
wl_event_loop_timer_func_t :: proc "c" (data: rawptr) -> c.int
wl_event_loop_signal_func_t :: proc "c" (signal_number: c.int, data: rawptr) -> c.int
wl_event_loop_idle_func_t :: proc "c" (data: rawptr)
wl_notify_func_t :: proc "c" (listener: ^wl_listener, data: rawptr)
wl_resource_destroy_func_t :: proc "c" (resource: ^wl_resource)
wl_global_bind_func_t :: proc "c" (client: ^wl_client, data: rawptr, version: u32, id: u32)
wl_display_global_filter_func_t :: proc "c" (
	client: ^wl_client,
	global: ^wl_global,
	data: rawptr,
) -> bool
wl_client_for_each_resource_iterator_func_t :: proc "c" (
	resource: ^wl_resource,
	user_data: rawptr,
) -> wl_iterator_result
wl_user_data_destroy_func_t :: proc "c" (data: rawptr)
wl_dispatcher_func_t :: proc "c" (
	user_data: rawptr,
	target: rawptr,
	opcode: u32,
	msg: ^wl_message,
	args: [^]wl_argument,
) -> c.int
wl_log_func_t :: proc "c" (fmt: cstring, args: c.va_list) // WL_PRINTF(1,0)
wl_protocol_logger_func_t :: proc "c" (
	user_data: rawptr,
	direction: wl_protocol_logger_type,
	message: ^wl_protocol_logger_message,
)

// ─── Die Library linken ────────────────────────────────────────────────
foreign import wl_server_lib "system:wayland-server"

// ─── Core-API: alle EXPORTIERTEN Funktionen (keine static-inline) ──────
//   link_prefix="wl_" macht aus `display_create` → `wl_display_create`
@(default_calling_convention = "c")
@(link_prefix = "wl_")
foreign wl_server_lib {

	// ── Event Loop ─────────────────────────────────────────────────────
	event_loop_create :: proc() -> ^wl_event_loop ---
	event_loop_destroy :: proc(loop: ^wl_event_loop) ---
	event_loop_add_fd :: proc(loop: ^wl_event_loop, fd: c.int, mask: u32, func: wl_event_loop_fd_func_t, data: rawptr) -> ^wl_event_source ---
	event_source_fd_update :: proc(source: ^wl_event_source, mask: u32) -> c.int ---
	event_loop_add_timer :: proc(loop: ^wl_event_loop, func: wl_event_loop_timer_func_t, data: rawptr) -> ^wl_event_source ---
	event_loop_add_signal :: proc(loop: ^wl_event_loop, signal_number: c.int, func: wl_event_loop_signal_func_t, data: rawptr) -> ^wl_event_source ---
	event_source_timer_update :: proc(source: ^wl_event_source, ms_delay: c.int) -> c.int ---
	event_source_remove :: proc(source: ^wl_event_source) -> c.int ---
	event_source_check :: proc(source: ^wl_event_source) ---
	event_loop_dispatch :: proc(loop: ^wl_event_loop, timeout: c.int) -> c.int ---
	event_loop_dispatch_idle :: proc(loop: ^wl_event_loop) ---
	event_loop_add_idle :: proc(loop: ^wl_event_loop, func: wl_event_loop_idle_func_t, data: rawptr) -> ^wl_event_source ---
	event_loop_get_fd :: proc(loop: ^wl_event_loop) -> c.int ---
	event_loop_add_destroy_listener :: proc(loop: ^wl_event_loop, listener: ^wl_listener) ---
	event_loop_get_destroy_listener :: proc(loop: ^wl_event_loop, notify: wl_notify_func_t) -> ^wl_listener ---

	// ── Display ────────────────────────────────────────────────────────
	display_create :: proc() -> ^wl_display ---
	display_destroy :: proc(display: ^wl_display) ---
	display_get_event_loop :: proc(display: ^wl_display) -> ^wl_event_loop ---
	display_add_socket :: proc(display: ^wl_display, name: cstring) -> c.int ---
	display_add_socket_auto :: proc(display: ^wl_display) -> cstring ---
	display_add_socket_fd :: proc(display: ^wl_display, sock_fd: c.int) -> c.int ---
	display_run :: proc(display: ^wl_display) ---
	display_terminate :: proc(display: ^wl_display) ---
	display_flush_clients :: proc(display: ^wl_display) ---
	display_destroy_clients :: proc(display: ^wl_display) ---
	display_set_default_max_buffer_size :: proc(display: ^wl_display, max_buffer_size: c.size_t) ---
	display_get_serial :: proc(display: ^wl_display) -> u32 ---
	display_next_serial :: proc(display: ^wl_display) -> u32 ---
	display_add_destroy_listener :: proc(display: ^wl_display, listener: ^wl_listener) ---
	display_add_client_created_listener :: proc(display: ^wl_display, listener: ^wl_listener) ---
	display_get_destroy_listener :: proc(display: ^wl_display, notify: wl_notify_func_t) -> ^wl_listener ---
	display_set_global_filter :: proc(display: ^wl_display, filter: wl_display_global_filter_func_t, data: rawptr) ---
	display_get_client_list :: proc(display: ^wl_display) -> ^wl_list ---
	display_init_shm :: proc(display: ^wl_display) -> c.int ---
	display_add_shm_format :: proc(display: ^wl_display, format: u32) -> ^u32 ---
	display_add_protocol_logger :: proc(display: ^wl_display, func: wl_protocol_logger_func_t, user_data: rawptr) -> ^wl_protocol_logger ---

	// ── Globals ────────────────────────────────────────────────────────
	global_create :: proc(display: ^wl_display, interface: ^wl_interface, version: c.int, data: rawptr, bind: wl_global_bind_func_t) -> ^wl_global ---
	global_remove :: proc(global: ^wl_global) ---
	global_destroy :: proc(global: ^wl_global) ---
	global_get_interface :: proc(global: ^wl_global) -> ^wl_interface ---
	global_get_name :: proc(global: ^wl_global, client: ^wl_client) -> u32 ---
	global_get_version :: proc(global: ^wl_global) -> u32 ---
	global_get_display :: proc(global: ^wl_global) -> ^wl_display ---
	global_get_user_data :: proc(global: ^wl_global) -> rawptr ---
	global_set_user_data :: proc(global: ^wl_global, data: rawptr) ---

	// ── Clients ────────────────────────────────────────────────────────
	client_create :: proc(display: ^wl_display, fd: c.int) -> ^wl_client ---
	client_destroy :: proc(client: ^wl_client) ---
	client_flush :: proc(client: ^wl_client) ---
	client_get_fd :: proc(client: ^wl_client) -> c.int ---
	client_get_credentials :: proc(client: ^wl_client, pid: ^pid_t, uid: ^uid_t, gid: ^gid_t) ---
	client_get_object :: proc(client: ^wl_client, id: u32) -> ^wl_resource ---
	client_get_display :: proc(client: ^wl_client) -> ^wl_display ---
	client_get_link :: proc(client: ^wl_client) -> ^wl_list ---
	client_from_link :: proc(link: ^wl_list) -> ^wl_client ---
	client_get_user_data :: proc(client: ^wl_client) -> rawptr ---
	client_set_user_data :: proc(client: ^wl_client, data: rawptr, dtor: wl_user_data_destroy_func_t) ---
	client_set_max_buffer_size :: proc(client: ^wl_client, max_buffer_size: c.size_t) ---
	client_post_no_memory :: proc(client: ^wl_client) ---
	client_post_implementation_error :: proc(client: ^wl_client, msg: cstring, #c_vararg args: ..any) ---
	client_add_destroy_listener :: proc(client: ^wl_client, listener: ^wl_listener) ---
	client_get_destroy_listener :: proc(client: ^wl_client, notify: wl_notify_func_t) -> ^wl_listener ---
	client_add_destroy_late_listener :: proc(client: ^wl_client, listener: ^wl_listener) ---
	client_get_destroy_late_listener :: proc(client: ^wl_client, notify: wl_notify_func_t) -> ^wl_listener ---
	client_add_resource_created_listener :: proc(client: ^wl_client, listener: ^wl_listener) ---
	client_for_each_resource :: proc(client: ^wl_client, iterator: wl_client_for_each_resource_iterator_func_t, user_data: rawptr) ---

	// ── Resources ───────────────────────────────────────────────────────
	resource_create :: proc(client: ^wl_client, interface: ^wl_interface, version: c.int, id: u32) -> ^wl_resource ---
	resource_destroy :: proc(resource: ^wl_resource) ---
	resource_set_implementation :: proc(resource: ^wl_resource, implementation: rawptr, data: rawptr, destroy: wl_resource_destroy_func_t) ---
	resource_set_dispatcher :: proc(resource: ^wl_resource, dispatcher: wl_dispatcher_func_t, implementation: rawptr, data: rawptr, destroy: wl_resource_destroy_func_t) ---
	resource_set_destructor :: proc(resource: ^wl_resource, destroy: wl_resource_destroy_func_t) ---
	resource_get_id :: proc(resource: ^wl_resource) -> u32 ---
	resource_get_link :: proc(resource: ^wl_resource) -> ^wl_list ---
	resource_from_link :: proc(link: ^wl_list) -> ^wl_resource ---
	resource_find_for_client :: proc(list: ^wl_list, client: ^wl_client) -> ^wl_resource ---
	resource_get_client :: proc(resource: ^wl_resource) -> ^wl_client ---
	resource_get_user_data :: proc(resource: ^wl_resource) -> rawptr ---
	resource_set_user_data :: proc(resource: ^wl_resource, data: rawptr) ---
	resource_get_version :: proc(resource: ^wl_resource) -> c.int ---
	resource_get_class :: proc(resource: ^wl_resource) -> cstring ---
	resource_get_interface :: proc(resource: ^wl_resource) -> ^wl_interface ---
	resource_instance_of :: proc(resource: ^wl_resource, interface: ^wl_interface, implementation: rawptr) -> c.int ---
	resource_add_destroy_listener :: proc(resource: ^wl_resource, listener: ^wl_listener) ---
	resource_get_destroy_listener :: proc(resource: ^wl_resource, notify: wl_notify_func_t) -> ^wl_listener ---

	// Events/Errors an Client senden
	resource_post_event :: proc(resource: ^wl_resource, opcode: u32, #c_vararg args: ..any) ---
	resource_post_event_array :: proc(resource: ^wl_resource, opcode: u32, args: [^]wl_argument) ---
	resource_queue_event :: proc(resource: ^wl_resource, opcode: u32, #c_vararg args: ..any) ---
	resource_queue_event_array :: proc(resource: ^wl_resource, opcode: u32, args: [^]wl_argument) ---
	resource_post_error :: proc(resource: ^wl_resource, code: u32, msg: cstring, #c_vararg args: ..any) ---
	resource_post_error_vargs :: proc(resource: ^wl_resource, code: u32, msg: cstring, argp: c.va_list) ---
	resource_post_no_memory :: proc(resource: ^wl_resource) ---

	// ── Listen ──────────────────────────────────────────────────────────
	list_init :: proc(list: ^wl_list) ---
	list_insert :: proc(list: ^wl_list, elm: ^wl_list) ---
	list_remove :: proc(elm: ^wl_list) ---
	list_length :: proc(list: ^wl_list) -> c.int ---
	list_empty :: proc(list: ^wl_list) -> c.int ---
	list_insert_list :: proc(list: ^wl_list, other: ^wl_list) ---

	// ── Signals (nur die echten, nicht static-inline) ──────────────────
	signal_emit_mutable :: proc(signal: ^wl_signal, data: rawptr) ---

	// ── SHM ─────────────────────────────────────────────────────────────
	shm_buffer_get :: proc(resource: ^wl_resource) -> ^wl_shm_buffer ---
	shm_buffer_begin_access :: proc(buffer: ^wl_shm_buffer) ---
	shm_buffer_end_access :: proc(buffer: ^wl_shm_buffer) ---
	shm_buffer_get_data :: proc(buffer: ^wl_shm_buffer) -> rawptr ---
	shm_buffer_get_stride :: proc(buffer: ^wl_shm_buffer) -> i32 ---
	shm_buffer_get_format :: proc(buffer: ^wl_shm_buffer) -> u32 ---
	shm_buffer_get_width :: proc(buffer: ^wl_shm_buffer) -> i32 ---
	shm_buffer_get_height :: proc(buffer: ^wl_shm_buffer) -> i32 ---
	shm_buffer_ref :: proc(buffer: ^wl_shm_buffer) -> ^wl_shm_buffer ---
	shm_buffer_unref :: proc(buffer: ^wl_shm_buffer) ---
	shm_buffer_ref_pool :: proc(buffer: ^wl_shm_buffer) -> ^wl_shm_pool ---
	shm_pool_unref :: proc(pool: ^wl_shm_pool) ---

	// ── Logging ──────────────────────────────────────────────────────────
	log_set_handler_server :: proc(handler: wl_log_func_t) ---
	protocol_logger_destroy :: proc(logger: ^wl_protocol_logger) ---
}

// ═══════════════════════════════════════════════════════════════════════════
//  static-inline Funktionen — NICHT in der .so, müssen in Odin nachgebaut
//  werden (Quelle: wayland-server-core.h, Zeilen ~458-510)
// ═══════════════════════════════════════════════════════════════════════════

// static inline void wl_signal_init(struct wl_signal *signal)
signal_init :: proc(signal: ^wl_signal) {
	list_init(&signal.listener_list)
}

// static inline void wl_signal_add(struct wl_signal *signal, struct wl_listener *listener)
signal_add :: proc(signal: ^wl_signal, listener: ^wl_listener) {
	list_insert(signal.listener_list.prev, &listener.link)
}

// static inline struct wl_listener * wl_signal_get(...)
signal_get :: proc(signal: ^wl_signal, notify: wl_notify_func_t) -> ^wl_listener {
	l := signal.listener_list.next
	for ; l != &signal.listener_list; l = l.next {
		listener := container_of(l, wl_listener, "link")
		if listener.notify == notify {
			return listener
		}
	}
	return nil
}

// static inline void wl_signal_emit(struct wl_signal *signal, void *data)
signal_emit :: proc(signal: ^wl_signal, data: rawptr) {
	// wl_list_for_each_safe(l, next, &signal->listener_list, link)
	l := signal.listener_list.next
	for l != &signal.listener_list {
		next := l.next
		listener := container_of(l, wl_listener, "link")
		listener.notify(listener, data)
		l = next
	}
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_container_of — das wichtigste C-Makro (wayland-util.h)
//  Holt aus einem Member-Pointer den umschließenden Struct-Pointer.
//  C:  wl_container_of(ptr, sample, member)  →  (type*)((char*)ptr - offsetof)
// ═══════════════════════════════════════════════════════════════════════════

// Generische Variante: Member-Feld als Compile-Zeit-Konstanten-String
// (offset_of_by_string verlangt eine Konstante → $member_name)
container_of :: proc(member_ptr: rawptr, $Outer: typeid, $member_name: string) -> ^Outer {
	offset := offset_of_by_string(Outer, member_name)
	raw := uintptr(member_ptr) - uintptr(offset)
	return (^Outer)(raw)
}

// ═══════════════════════════════════════════════════════════════════════════
//  Iterator-Makros als Odin-Procs (wayland-server-core.h)
//  Statt der C-`for`-Makros: explizite Schleifen-Helper.
// ═══════════════════════════════════════════════════════════════════════════

// #define wl_list_for_each(pos, head, member)
list_for_each :: proc(
	head: ^wl_list,
	callback: proc(elem_link: ^wl_list, user_data: rawptr),
	user_data: rawptr,
) {
	e := head.next
	for ; e != head; e = e.next {
		callback(e, user_data)
	}
}

// #define wl_list_for_each_safe(pos, tmp, head, member)
list_for_each_safe :: proc(
	head: ^wl_list,
	callback: proc(elem_link: ^wl_list, user_data: rawptr),
	user_data: rawptr,
) {
	e := head.next
	for e != head {
		next := e.next
		callback(e, user_data)
		e = next
	}
}

// ─── wl_fixed Hilfsfunktionen (wayland-util.h static inline) ───────────
// 24.8 fixed-point. 256 = 2^8.
fixed_to_double :: proc(f: wl_fixed_t) -> f64 {return f64(f) / 256.0}
fixed_from_double :: proc(d: f64) -> wl_fixed_t {return wl_fixed_t(d * 256.0 + 0.5)}
fixed_to_int :: proc(f: wl_fixed_t) -> i32 {return f >> 8}
fixed_from_int :: proc(i: i32) -> wl_fixed_t {return i << 8}


