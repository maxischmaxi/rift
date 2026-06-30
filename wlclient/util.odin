#+build linux
package wayland

// ═══════════════════════════════════════════════════════════════════════════
//  Wayland C-Protokoll-Typen — vom odin-wayland Scanner benötigte Basis-Typen.
//  Diese entsprechen den C-Typen aus libwayland-client:
//    interface   → struct wl_interface
//    message     → struct wl_message
//    array       → struct wl_array
//    fixed_t     → wl_fixed_t (i32, 24.8 Fixkomma)
//    proxy       → struct wl_proxy (opaque)
//    event_queue → struct wl_event_queue (opaque)
//    argument    → union wl_argument (raw union, nicht Odin-tagged)
// ═══════════════════════════════════════════════════════════════════════════

generic_c_call :: proc "c" ()

dispatcher_func_t :: proc "c" (impl: rawptr, target: rawptr, opcode: u32, msg: ^message, args: [^]argument)

fixed_t :: i32

event_queue :: struct {}
proxy :: struct {}

argument :: union {}

message :: struct {
    name: cstring,
    signature: cstring,
    types: [^]^interface,
}

interface :: struct {
    name: cstring,
    version: i32,
    method_count: i32,
    methods: [^]message,
    event_count: i32,
    events: [^]message,
}

array :: struct {
    size: i64,
    alloc: i64,
    data: rawptr,
}