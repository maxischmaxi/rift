package wayland_server

// ═══════════════════════════════════════════════════════════════════════════
//  wlr-layer-shell Server-Bindings
//
//  Quelle: protocols/wlr-layer-shell-unstable-v1.xml (Version 5)
//  Generiert via wayland-scanner (siehe Makefile).
//
//  Gleiche Strategie wie xdg-shell: die wl_interface-Daten bleiben im
//  kompilierten C-Objekt (wlr-layer-shell-protocol.o); hier binden wir nur
//  die Symbole + definieren die Vtable-Structs, die rift mit Handlern füllt.
// ═══════════════════════════════════════════════════════════════════════════

foreign import wl_layer_lib "wlr-layer-shell-protocol.o"

foreign wl_layer_lib {
    @(link_name="zwlr_layer_shell_v1_interface")   zwlr_layer_shell_iface   : wl_interface;
    @(link_name="zwlr_layer_surface_v1_interface") zwlr_layer_surface_iface : wl_interface;
}

// ─── Vtable-Structs (Requests, Client → Server) ─────────────────────────

zwlr_layer_shell_v1_interface :: struct {
    get_layer_surface: proc "c" (client: ^wl_client, resource: ^wl_resource,
                                 id: u32, surface: ^wl_resource, output: ^wl_resource,
                                 layer: u32, namespace: cstring),
    destroy:           req_handler_t,   // since v3
}

zwlr_layer_surface_v1_interface :: struct {
    set_size:                   proc "c" (client: ^wl_client, resource: ^wl_resource, width, height: u32),
    set_anchor:                 proc "c" (client: ^wl_client, resource: ^wl_resource, anchor: u32),
    set_exclusive_zone:         proc "c" (client: ^wl_client, resource: ^wl_resource, zone: i32),
    set_margin:                 proc "c" (client: ^wl_client, resource: ^wl_resource, top, right, bottom, left: i32),
    set_keyboard_interactivity: proc "c" (client: ^wl_client, resource: ^wl_resource, ki: u32),
    get_popup:                  proc "c" (client: ^wl_client, resource: ^wl_resource, popup: ^wl_resource),
    ack_configure:              proc "c" (client: ^wl_client, resource: ^wl_resource, serial: u32),
    destroy:                    req_handler_t,
    set_layer:                  proc "c" (client: ^wl_client, resource: ^wl_resource, layer: u32),   // since v2
    set_exclusive_edge:         proc "c" (client: ^wl_client, resource: ^wl_resource, edge: u32),    // since v5
}

// ─── Event-Opcodes (Server → Client) ────────────────────────────────────
ZWLR_LAYER_SURFACE_CONFIGURE :: u32(0)
ZWLR_LAYER_SURFACE_CLOSED    :: u32(1)

zwlr_layer_surface_send_configure :: proc "c" (resource: ^wl_resource, serial, width, height: u32) {
    resource_post_event(resource, ZWLR_LAYER_SURFACE_CONFIGURE, serial, width, height)
}

zwlr_layer_surface_send_closed :: proc "c" (resource: ^wl_resource) {
    resource_post_event(resource, ZWLR_LAYER_SURFACE_CLOSED)
}
