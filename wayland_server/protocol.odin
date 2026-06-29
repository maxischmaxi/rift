package wayland_server

// ═══════════════════════════════════════════════════════════════════════════
//  libwayland-server Bindings — Teil B: Protokoll-Interfaces
//
//  Quelle: /usr/include/wayland-server-protocol.h
//  Diese Datei ist MASCHINELL generiert von wayland-scanner aus wayland.xml.
//
//  Strategie: Die Daten-Tabellen (wl_interface-Structs mit method_count,
//  methods[], events[]) werden NICHT per Hand übersetzt. Stattdessen:
//    1. wayland-scanner private-code wayland.xml wayland-protocol.c  (generiert)
//    2. cc -c wayland-protocol.c -o wayland-protocol.o              (compiliert)
//    3. Hier: nur die fertigen C-Symbole binden + Vtable-Structs definieren.
//
//  Build: odin build . -extra-linker-flags:"-lwayland-server wayland_server/wayland-protocol.o"
//
//  Was DU hier in Odin schreibst:
//   • Die 23 externen wl_*_interface Symbole   (Daten, fertig aus C)
//   • Die 22 Vtable-Structs                     (die DU mit Handlern füllst)
//   • Event-Opcodes + send_* Helper             (um Events an Clients zu schicken)
// ═══════════════════════════════════════════════════════════════════════════

// ─── Die generierten Interface-Daten aus dem C-Objekt binden ────────────
//    Jedes Symbol ist: const struct wl_interface wl_<name>_interface = {...};
//    → in Odin: <name>_interface : wl_interface;  (mit link_prefix="wl_")
foreign import wl_proto_lib "wayland-protocol.o"

@(link_prefix="wl_")
foreign wl_proto_lib {
    display_interface            : wl_interface;
    registry_interface            : wl_interface;
    callback_interface            : wl_interface;
    compositor_interface          : wl_interface;
    shm_pool_interface            : wl_interface;
    shm_interface                 : wl_interface;
    buffer_interface              : wl_interface;
    data_offer_interface          : wl_interface;
    data_source_interface         : wl_interface;
    data_device_interface         : wl_interface;
    data_device_manager_interface : wl_interface;
    shell_interface               : wl_interface;
    shell_surface_interface       : wl_interface;
    surface_interface             : wl_interface;
    seat_interface                : wl_interface;
    pointer_interface             : wl_interface;
    keyboard_interface            : wl_interface;
    touch_interface               : wl_interface;
    output_interface              : wl_interface;
    region_interface              : wl_interface;
    subcompositor_interface       : wl_interface;
    subsurface_interface          : wl_interface;
    fixes_interface               : wl_interface;
}

// Pointer-Helfer (global_create erwartet ^wl_interface)
compositor_interface_ptr           :: proc() -> ^wl_interface { return &compositor_interface }
shm_interface_ptr                  :: proc() -> ^wl_interface { return &shm_interface }
seat_interface_ptr                 :: proc() -> ^wl_interface { return &seat_interface }
output_interface_ptr              :: proc() -> ^wl_interface { return &output_interface }
subcompositor_interface_ptr       :: proc() -> ^wl_interface { return &subcompositor_interface }
data_device_manager_interface_ptr :: proc() -> ^wl_interface { return &data_device_manager_interface }
shell_interface_ptr                :: proc() -> ^wl_interface { return &shell_interface }

// ═══════════════════════════════════════════════════════════════════════════
//  Vtable-Structs — die Implementationstabellen, die DU mit Handlern füllst.
//  C: struct wl_compositor_interface { void (*create_surface)(...); ... };
//  Jede Funktion = ein Request, den ein Client an diesen Server-Resource
//  schickt. Du setzt die Pointer auf deine Odin-Handler und übergibst die
//  Struct an wl_resource_set_implementation.
// ═══════════════════════════════════════════════════════════════════════════

// Gemeinsame Request-Handler-Signatur (erste 2 Args bei jedem Request):
//   client  : welcher Client den Request schickt
//   resource: die serverseitige wl_resource, an die der Request geht
req_handler_t :: proc "c" (client: ^wl_client, resource: ^wl_resource)

// ── wl_display (nur intern; Client→Server: sync, get_registry) ──────────
wl_display_interface :: struct {
    sync:         proc "c" (client: ^wl_client, resource: ^wl_resource, callback: u32),
    get_registry: proc "c" (client: ^wl_client, resource: ^wl_resource, registry: u32),
}

// ── wl_registry ─────────────────────────────────────────────────────────
wl_registry_interface :: struct {
    bind: proc "c" (client: ^wl_client, resource: ^wl_resource, name: u32,
                    interface: cstring, version: u32, id: u32),
}

// ── wl_compositor ────────────────────────────────────────────────────────
wl_compositor_interface :: struct {
    create_surface: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    create_region:  proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    release:         req_handler_t,
}

// ── wl_shm_pool ─────────────────────────────────────────────────────────
wl_shm_pool_interface :: struct {
    create_buffer: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32,
                             offset: i32, width: i32, height: i32, stride: i32, format: u32),
    destroy: req_handler_t,
    resize:  proc "c" (client: ^wl_client, resource: ^wl_resource, size: i32),
}

// ── wl_shm ──────────────────────────────────────────────────────────────
wl_shm_interface :: struct {
    create_pool: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32,
                          fd: i32, size: i32),
    release:     req_handler_t,
}

// ── wl_buffer ───────────────────────────────────────────────────────────
wl_buffer_interface :: struct {
    destroy: req_handler_t,
}

// ── wl_data_offer ───────────────────────────────────────────────────────
wl_data_offer_interface :: struct {
    accept:      proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32, mime_type: cstring),
    receive:     proc "c" (client: ^wl_client, resource: ^wl_resource, mime_type: cstring, fd: i32),
    destroy:     req_handler_t,
    finish:      req_handler_t,
    set_actions: proc "c" (client: ^wl_client, resource: ^wl_resource, dnd_actions: u32, preferred_action: u32),
}

// ── wl_data_source ──────────────────────────────────────────────────────
wl_data_source_interface :: struct {
    offer:       proc "c" (client: ^wl_client, resource: ^wl_resource, mime_type: cstring),
    destroy:     req_handler_t,
    set_actions: proc "c" (client: ^wl_client, resource: ^wl_resource, dnd_actions: u32),
}

// ── wl_data_device ──────────────────────────────────────────────────────
wl_data_device_interface :: struct {
    start_drag:    proc "c" (client: ^wl_client, resource: ^wl_resource, source, origin, icon: ^wl_resource, serial: u32),
    set_selection: proc "c" (client: ^wl_client, resource: ^wl_resource, source: ^wl_resource, serial: u32),
    release:       req_handler_t,
}

// ── wl_data_device_manager ─────────────────────────────────────────────
wl_data_device_manager_interface :: struct {
    create_data_source: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    get_data_device:    proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32, seat: ^wl_resource),
    release:            req_handler_t,
}

// ── wl_shell (veraltet, aber für Kompatibilität) ───────────────────────
wl_shell_interface :: struct {
    get_shell_surface: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32, surface: ^wl_resource),
}

// ── wl_shell_surface ────────────────────────────────────────────────────
wl_shell_surface_interface :: struct {
    pong:          proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32),
    move:          proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32),
    resize:        proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32, edges: u32),
    set_toplevel:  req_handler_t,
    set_transient: proc "c" (client: ^wl_client, resource: ^wl_resource, parent: ^wl_resource, x: i32, y: i32, flags: u32),
    set_fullscreen: proc "c" (client: ^wl_client, resource: ^wl_resource, method: u32, framerate: u32, output: ^wl_resource),
    set_popup:     proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32, parent: ^wl_resource, x: i32, y: i32, flags: u32),
    set_maximized: proc "c" (client: ^wl_client, resource: ^wl_resource, output: ^wl_resource),
    set_title:     proc "c" (client: ^wl_client, resource: ^wl_resource, title: cstring),
    set_class:     proc "c" (client: ^wl_client, resource: ^wl_resource, class_: cstring),
}

// ── wl_surface ──────────────────────────────────────────────────────────
wl_surface_interface :: struct {
    destroy:             req_handler_t,
    attach:              proc "c" (client: ^wl_client, resource: ^wl_resource, buffer: ^wl_resource, x: i32, y: i32),
    damage:              proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32, width: i32, height: i32),
    frame:               proc "c" (client: ^wl_client, resource: ^wl_resource, callback: u32),
    set_opaque_region:   proc "c" (client: ^wl_client, resource: ^wl_resource, region: ^wl_resource),
    set_input_region:    proc "c" (client: ^wl_client, resource: ^wl_resource, region: ^wl_resource),
    commit:              req_handler_t,
    set_buffer_transform: proc "c" (client: ^wl_client, resource: ^wl_resource, transform: i32),
    set_buffer_scale:    proc "c" (client: ^wl_client, resource: ^wl_resource, scale: i32),
    damage_buffer:       proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32, width: i32, height: i32),
    offset:              proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32),
    get_release:         proc "c" (client: ^wl_client, resource: ^wl_resource, callback: u32),
}

// ── wl_seat ─────────────────────────────────────────────────────────────
wl_seat_interface :: struct {
    get_pointer:  proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    get_keyboard: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    get_touch:    proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    release:      req_handler_t,
}

// ── wl_pointer ──────────────────────────────────────────────────────────
wl_pointer_interface :: struct {
    set_cursor: proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32,
                          surface: ^wl_resource, hotspot_x: i32, hotspot_y: i32),
    release:    req_handler_t,
}

// ── wl_keyboard / wl_touch ──────────────────────────────────────────────
wl_keyboard_interface :: struct { release: req_handler_t }
wl_touch_interface    :: struct { release: req_handler_t }

// ── wl_output ───────────────────────────────────────────────────────────
wl_output_interface :: struct { release: req_handler_t }

// ── wl_region ───────────────────────────────────────────────────────────
wl_region_interface :: struct {
    destroy:  req_handler_t,
    add:      proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32, w: i32, h: i32),
    subtract: proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32, w: i32, h: i32),
}

// ── wl_subcompositor ────────────────────────────────────────────────────
wl_subcompositor_interface :: struct {
    destroy:        req_handler_t,
    get_subsurface: proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32,
                              surface: ^wl_resource, parent: ^wl_resource),
}

// ── wl_subsurface ───────────────────────────────────────────────────────
wl_subsurface_interface :: struct {
    destroy:     req_handler_t,
    set_position: proc "c" (client: ^wl_client, resource: ^wl_resource, x: i32, y: i32),
    place_above: proc "c" (client: ^wl_client, resource: ^wl_resource, sibling: ^wl_resource),
    place_below: proc "c" (client: ^wl_client, resource: ^wl_resource, sibling: ^wl_resource),
    set_sync:    req_handler_t,
    set_desync:  req_handler_t,
}

// ── wl_fixes ────────────────────────────────────────────────────────────
wl_fixes_interface :: struct {
    destroy:          req_handler_t,
    destroy_registry: proc "c" (client: ^wl_client, resource: ^wl_resource, registry: ^wl_resource),
}

// ═══════════════════════════════════════════════════════════════════════════
//  Event-Opcodes — für resource_post_event (Server → Client)
//  Quelle: #define WL_<INTERFACE>_<EVENT_NAME> <opcode>
//  Du rufst: resource_post_event(res, WL_REGISTRY_GLOBAL, name, iface, ver)
// ═══════════════════════════════════════════════════════════════════════════

// wl_display
WL_DISPLAY_ERROR     :: u32(0)
WL_DISPLAY_DELETE_ID :: u32(1)

// wl_registry (Events vom Server: globale Objekte bekanntmachen)
WL_REGISTRY_GLOBAL       :: u32(0)
WL_REGISTRY_GLOBAL_REMOVE :: u32(1)

// wl_callback
WL_CALLBACK_DONE :: u32(0)

// wl_shm
WL_SHM_FORMAT :: u32(0)

// wl_buffer
WL_BUFFER_RELEASE :: u32(0)

// wl_data_offer
WL_DATA_OFFER_OFFER         :: u32(0)
WL_DATA_OFFER_SOURCE_ACTIONS :: u32(1)
WL_DATA_OFFER_ACTION         :: u32(2)

// wl_data_source
WL_DATA_SOURCE_TARGET            :: u32(0)
WL_DATA_SOURCE_SEND              :: u32(1)
WL_DATA_SOURCE_CANCELLED         :: u32(2)
WL_DATA_SOURCE_DND_DROP_PERFORMED :: u32(3)
WL_DATA_SOURCE_DND_FINISHED      :: u32(4)
WL_DATA_SOURCE_ACTION             :: u32(5)

// wl_data_device
WL_DATA_DEVICE_DATA_OFFER :: u32(0)
WL_DATA_DEVICE_ENTER      :: u32(1)
WL_DATA_DEVICE_LEAVE     :: u32(2)
WL_DATA_DEVICE_MOTION    :: u32(3)
WL_DATA_DEVICE_DROP      :: u32(4)
WL_DATA_DEVICE_SELECTION :: u32(5)

// wl_output
WL_OUTPUT_GEOMETRY     :: u32(0)
WL_OUTPUT_MODE         :: u32(1)
WL_OUTPUT_DONE         :: u32(2)
WL_OUTPUT_SCALE        :: u32(3)

// wl_seat
WL_SEAT_CAPABILITIES :: u32(0)
WL_SEAT_NAME         :: u32(1)

// wl_pointer
WL_POINTER_ENTER       :: u32(0)
WL_POINTER_LEAVE       :: u32(1)
WL_POINTER_MOTION       :: u32(2)
WL_POINTER_BUTTON       :: u32(3)
WL_POINTER_AXIS         :: u32(4)
WL_POINTER_FRAME        :: u32(5)
WL_POINTER_AXIS_SOURCE  :: u32(6)
WL_POINTER_AXIS_STOP    :: u32(7)
WL_POINTER_AXIS_DISCRETE :: u32(8)
WL_POINTER_AXIS_VALUE120 :: u32(9)

// wl_keyboard
WL_KEYBOARD_KEYMAP    :: u32(0)
WL_KEYBOARD_ENTER      :: u32(1)
WL_KEYBOARD_LEAVE      :: u32(2)
WL_KEYBOARD_KEY        :: u32(3)
WL_KEYBOARD_MODIFIERS  :: u32(4)
WL_KEYBOARD_REPEAT_INFO :: u32(5)

// wl_touch
WL_TOUCH_DOWN    :: u32(0)
WL_TOUCH_UP      :: u32(1)
WL_TOUCH_MOTION  :: u32(2)
WL_TOUCH_FRAME    :: u32(3)
WL_TOUCH_CANCEL  :: u32(4)
WL_TOUCH_SHAPE    :: u32(5)
WL_TOUCH_ORIENTATION :: u32(6)

// wl_surface (Events vom Server)
WL_SURFACE_ENTER    :: u32(0)
WL_SURFACE_LEAVE    :: u32(1)
WL_SURFACE_PREFERRED_BUFFER_SCALE :: u32(2)
WL_SURFACE_PREFERRED_BUFFER_TRANSFORM :: u32(3)

// ═══════════════════════════════════════════════════════════════════════════
//  send_* Helper — die static-inline-Funktionen aus dem Protocol-Header.
//  Sie wickeln einfach resource_post_event mit dem richtigen Opcode auf.
//  (Quelle: wayland-server-protocol.h, die `wl_*_send_*` Funktionen)
// ═══════════════════════════════════════════════════════════════════════════

// wl_registry_send_global
registry_send_global :: proc "c" (resource: ^wl_resource, name: u32, interface: cstring, version: u32) {
    resource_post_event(resource, WL_REGISTRY_GLOBAL, name, interface, version)
}

// wl_registry_send_global_remove
registry_send_global_remove :: proc "c" (resource: ^wl_resource, name: u32) {
    resource_post_event(resource, WL_REGISTRY_GLOBAL_REMOVE, name)
}

// wl_callback_send_done
callback_send_done :: proc "c" (resource: ^wl_resource, callback_data: u32) {
    resource_post_event(resource, WL_CALLBACK_DONE, callback_data)
}

// wl_seat_send_capabilities
seat_send_capabilities :: proc "c" (resource: ^wl_resource, capabilities: u32) {
    resource_post_event(resource, WL_SEAT_CAPABILITIES, capabilities)
}

// wl_shm_send_format
shm_send_format :: proc "c" (resource: ^wl_resource, format: u32) {
    resource_post_event(resource, WL_SHM_FORMAT, format)
}

// wl_output_send_geometry
output_send_geometry :: proc "c" (resource: ^wl_resource, x, y: i32, physical_width, physical_height: i32,
                                   subpixel: i32, make: cstring, model: cstring, transform: i32) {
    resource_post_event(resource, WL_OUTPUT_GEOMETRY, x, y, physical_width, physical_height, subpixel, make, model, transform)
}

// wl_output_send_mode
output_send_mode :: proc "c" (resource: ^wl_resource, flags: u32, width, height: i32, refresh: i32) {
    resource_post_event(resource, WL_OUTPUT_MODE, flags, width, height, refresh)
}

// wl_surface_send_enter
surface_send_enter :: proc "c" (resource: ^wl_resource, output: ^wl_resource) {
    resource_post_event(resource, WL_SURFACE_ENTER, output)
}

// wl_surface_send_leave
surface_send_leave :: proc "c" (resource: ^wl_resource, output: ^wl_resource) {
    resource_post_event(resource, WL_SURFACE_LEAVE, output)
}