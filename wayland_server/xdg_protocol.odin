package wayland_server

// ═══════════════════════════════════════════════════════════════════════════
//  xdg-shell Server-Bindings (Teil B für xdg-shell)
//
//  Quelle: /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
//  Generiert via wayland-scanner (siehe Makefile/Build).
//
//  Gleiche Strategie wie beim Core-Protokoll: die wl_interface-Daten
//  (method_count/methods/events) bleiben im kompilierten C-Objekt
//  (xdg-shell-protocol.o); hier binden wir nur die Symbole + definieren
//  die Vtable-Structs, die rift mit Handlern füllt.
// ═══════════════════════════════════════════════════════════════════════════

// ─── Interface-Daten aus dem C-Objekt binden ─────────────────────────────
//    C-Symbole: xdg_wm_base_interface, xdg_surface_interface, …
//    Wir nutzen @link_name (explizit), da `surface_interface` sonst mit dem
//    Core-Protokoll kollidiert.
foreign import wl_xdg_lib "xdg-shell-protocol.o"

foreign wl_xdg_lib {
    @(link_name="xdg_wm_base_interface")    xdg_wm_base_iface    : wl_interface;
    @(link_name="xdg_positioner_interface") xdg_positioner_iface : wl_interface;
    @(link_name="xdg_surface_interface")    xdg_surface_iface    : wl_interface;
    @(link_name="xdg_toplevel_interface")   xdg_toplevel_iface   : wl_interface;
    @(link_name="xdg_popup_interface")      xdg_popup_iface      : wl_interface;
}

// Pointer-Helfer (global_create erwartet ^wl_interface)
xdg_wm_base_interface_ptr :: proc() -> ^wl_interface { return &xdg_wm_base_iface }

// ─── Vtable-Structs (die rift mit Handlern füllt) ──────────────────────

xdg_wm_base_interface :: struct {
    destroy:            req_handler_t,
    create_positioner:  proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    get_xdg_surface:    proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32, surface: ^wl_resource),
    pong:               proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32),
}

xdg_positioner_interface :: struct {
    destroy:                  req_handler_t,
    set_size:                 proc "c" (client: ^wl_client, resource: ^wl_resource, w, h: i32),
    set_anchor_rect:          proc "c" (client: ^wl_client, resource: ^wl_resource, x, y, w, h: i32),
    set_anchor:               proc "c" (client: ^wl_client, resource: ^wl_resource, anchor: u32),
    set_gravity:              proc "c" (client: ^wl_client, resource: ^wl_resource, gravity: u32),
    set_constraint_adjustment: proc "c" (client: ^wl_client, resource: ^wl_resource, ca: u32),
    set_offset:               proc "c" (client: ^wl_client, resource: ^wl_resource, x, y: i32),
    set_reactive:             req_handler_t,
    set_parent_size:          proc "c" (client: ^wl_client, resource: ^wl_resource, pw, ph: i32),
    set_parent_configure:     proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32),
}

xdg_surface_interface :: struct {
    destroy:             req_handler_t,
    get_toplevel:        proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32),
    get_popup:           proc "c" (client: ^wl_client, resource: ^wl_resource, id: u32, parent: ^wl_resource, positioner: ^wl_resource),
    set_window_geometry: proc "c" (client: ^wl_client, resource: ^wl_resource, x, y, w, h: i32),
    ack_configure:       proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32),
}

xdg_toplevel_interface :: struct {
    destroy:          req_handler_t,
    set_parent:       proc "c" (client: ^wl_client, resource: ^wl_resource, parent: ^wl_resource),
    set_title:        proc "c" (client: ^wl_client, resource: ^wl_resource, title: cstring),
    set_app_id:       proc "c" (client: ^wl_client, resource: ^wl_resource, app_id: cstring),
    show_window_menu: proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32, x, y: i32),
    move:             proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32),
    resize:           proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32, edges: u32),
    set_max_size:     proc "c" (client: ^wl_client, resource: ^wl_resource, w, h: i32),
    set_min_size:     proc "c" (client: ^wl_client, resource: ^wl_resource, w, h: i32),
    set_maximized:    req_handler_t,
    unset_maximized:  req_handler_t,
    set_fullscreen:   proc "c" (client: ^wl_client, resource: ^wl_resource, output: ^wl_resource),
    unset_fullscreen: req_handler_t,
    set_minimized:    req_handler_t,
}

xdg_popup_interface :: struct {
    destroy:    req_handler_t,
    grab:       proc "c" (client: ^wl_client, resource: ^wl_resource, seat: ^wl_resource, serial: u32),
    reposition: proc "c" (client: ^wl_client, resource: ^wl_resource, positioner: ^wl_resource, token: u32),
}

// ─── Event-Opcodes (Server → Client) ────────────────────────────────────
XDG_WM_BASE_PING        :: u32(0)
XDG_SURFACE_CONFIGURE   :: u32(0)
XDG_TOPLEVEL_CONFIGURE  :: u32(0)
XDG_TOPLEVEL_CLOSE      :: u32(1)
XDG_POPUP_CONFIGURE     :: u32(0)
XDG_POPUP_POPUP_DONE    :: u32(1)

// ─── xdg_toplevel.state-Werte (xdg-shell.xml, ab v1 gültig) ─────────────
XDG_TOPLEVEL_STATE_MAXIMIZED  :: u32(1)
XDG_TOPLEVEL_STATE_FULLSCREEN :: u32(2)
XDG_TOPLEVEL_STATE_RESIZING   :: u32(3)
XDG_TOPLEVEL_STATE_ACTIVATED  :: u32(4)

// ─── send_* Helper (post_event mit richtigem Opcode) ────────────────────
xdg_wm_base_send_ping :: proc "c" (resource: ^wl_resource, serial: u32) {
    resource_post_event(resource, XDG_WM_BASE_PING, serial)
}

xdg_surface_send_configure :: proc "c" (resource: ^wl_resource, serial: u32) {
    resource_post_event(resource, XDG_SURFACE_CONFIGURE, serial)
}

// xdg_toplevel.configure: width, height, states(wl_array). 0/0 = Client wählt.
xdg_toplevel_send_configure :: proc "c" (resource: ^wl_resource, width, height: i32, states: ^wl_array) {
    resource_post_event(resource, XDG_TOPLEVEL_CONFIGURE, width, height, states)
}

// xdg_popup.configure: Position relativ zur Window-Geometry des Parents.
xdg_popup_send_configure :: proc "c" (resource: ^wl_resource, x, y, width, height: i32) {
    resource_post_event(resource, XDG_POPUP_CONFIGURE, x, y, width, height)
}

// xdg_popup.popup_done: Popup wurde dismissed (Außenklick, Parent weg).
xdg_popup_send_popup_done :: proc "c" (resource: ^wl_resource) {
    resource_post_event(resource, XDG_POPUP_POPUP_DONE)
}