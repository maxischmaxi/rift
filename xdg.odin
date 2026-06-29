package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  rift xdg-shell — damit rift-Clients *echte Fenster* (xdg_toplevel)
//  anmelden können, die rift verwaltet. Das ist der Sprung vom reinen
//  Compositor zum Window-Manager.
//
//  Läuft komplett auf rifts Server-Seite (rift-0). Berührt Hyprland NICHT.
// ═══════════════════════════════════════════════════════════════════════════

// Forward-Deklarationen werden paketweise aufgelöst:
XdgSurface :: struct {
    surface: ^Surface,           // back-link zur wl_surface
    resource: ^wls.wl_resource,  // xdg_surface-Resource
    toplevel: ^XdgToplevel,      // nil bis get_toplevel
    configured: bool,            // Client hat das initiale configure geackt
    configure_serial: u32,       // zuletzt gesendeter Serial
}

XdgToplevel :: struct {
    xdg_surface: ^XdgSurface,
    resource: ^wls.wl_resource,  // xdg_toplevel-Resource
    title: string,
    mapped: bool,
    geom: Rect,                 // {x,y,w,h} im Nested-Fenster (vom Layout zugewiesen)
}

// Leeres wl_array für configure-states (keine States = 0/0 → Client wählt Größe).
empty_states: wls.wl_array = {}

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_wm_base — der Global. ping/pong + get_xdg_surface.
// ═══════════════════════════════════════════════════════════════════════════

xdg_wm_base_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[xdg] Client bindet xdg_wm_base")
    resource := wls.resource_create(client, &wls.xdg_wm_base_iface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &xdg_wm_base_impl, nil, nil)
}

xdg_wm_base_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
xdg_wm_base_create_positioner :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    pos := wls.resource_create(client, &wls.xdg_positioner_iface, 1, id)
    if pos == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(pos, &xdg_positioner_impl, nil, nil)
}
xdg_wm_base_get_xdg_surface :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32, surface_resource: ^wls.wl_resource) {
    context = ctx
    // Surface-Struct der übergebenen wl_surface finden.
    surface := (^Surface)(wls.resource_get_user_data(surface_resource))
    if surface == nil {
        fmt.println("[xdg] get_xdg_surface: unbekannte Surface")
        return
    }
    xs := new(XdgSurface)
    xs.surface = surface
    xs.resource = wls.resource_create(client, &wls.xdg_surface_iface, 1, id)
    if xs.resource == nil {
        free(xs, ctx.allocator); wls.client_post_no_memory(client); return
    }
    surface.xdg = xs
    wls.resource_set_implementation(xs.resource, &xdg_surface_impl, xs, xdg_surface_destroy_resource)
    fmt.println("[xdg] get_xdg_surface → xdg_surface angelegt")
}
xdg_wm_base_pong :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32) {}

xdg_wm_base_impl: wls.xdg_wm_base_interface = {
    destroy = xdg_wm_base_destroy,
    create_positioner = xdg_wm_base_create_positioner,
    get_xdg_surface = xdg_wm_base_get_xdg_surface,
    pong = xdg_wm_base_pong,
}

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_surface — get_toplevel (→ Fenster), ack_configure (Handshake).
// ═══════════════════════════════════════════════════════════════════════════

xdg_surface_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    if xs.toplevel != nil {
        // toplevel.title (Odin-string) freigeben; toplevel-Struct selbst wird
        // via xdg_toplevel_destroy_resource freigegeben, falls noch nicht geschehen.
        if len(xs.toplevel.title) > 0 do delete(xs.toplevel.title)
        free(xs.toplevel, ctx.allocator)
    }
    if xs.surface != nil do xs.surface.xdg = nil
    free(xs, ctx.allocator)
}

xdg_surface_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)   // triggert xdg_surface_destroy_resource
}

xdg_surface_get_toplevel :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    tl := new(XdgToplevel)
    tl.xdg_surface = xs
    tl.resource = wls.resource_create(client, &wls.xdg_toplevel_iface, 1, id)
    if tl.resource == nil {
        free(tl, ctx.allocator); wls.client_post_no_memory(client); return
    }
    xs.toplevel = tl
    wls.resource_set_implementation(tl.resource, &xdg_toplevel_impl, tl, xdg_toplevel_destroy_resource)

    // Initialer Configure-Handshake: toplevel.configure(0,0,∅) + surface.configure(serial).
    // 0/0 bedeutet "Client wählt eigene Größe".
    serial := wls.display_next_serial(g_server.display)
    xs.configure_serial = serial
    wls.xdg_toplevel_send_configure(tl.resource, 0, 0, &empty_states)
    wls.xdg_surface_send_configure(xs.resource, serial)
    fmt.printfln("[xdg] get_toplevel → configure serial %d gesendet", serial)
}

xdg_surface_get_popup :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32, parent: ^wls.wl_resource, positioner: ^wls.wl_resource) {
    // Popups noch nicht voll unterstützt — Resource erzeugen (gültige new_id),
    // damit der Client keinen Fehler bekommt. Handler sind no-op.
    pop := wls.resource_create(client, &wls.xdg_popup_iface, 1, id)
    if pop == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(pop, &xdg_popup_impl, nil, nil)
}

xdg_surface_set_window_geometry :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {
    // Später: Toplevel-Geometrie tracken. Aktuell ignoriert (Client hat seine Größe selbst gewählt).
}

xdg_surface_ack_configure :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32) {
    context = ctx
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    if serial == xs.configure_serial {
        xs.configured = true
        fmt.printfln("[xdg] ack_configure serial %d → Fenster bereit zum Mappen", serial)
    }
}

xdg_surface_impl: wls.xdg_surface_interface = {
    destroy = xdg_surface_destroy,
    get_toplevel = xdg_surface_get_toplevel,
    get_popup = xdg_surface_get_popup,
    set_window_geometry = xdg_surface_set_window_geometry,
    ack_configure = xdg_surface_ack_configure,
}

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_toplevel — Title/App_id speichern, Rest no-op.
// ═══════════════════════════════════════════════════════════════════════════

xdg_toplevel_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl.mapped do toplevel_unmap(tl)   // aus Layout nehmen + restliche Fenster neu zeichnen
    if tl.xdg_surface != nil do tl.xdg_surface.toplevel = nil
    free(tl, ctx.allocator)
}
xdg_toplevel_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
xdg_toplevel_set_title :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, title: cstring) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    // WICHTIG: string(cstring) referenziert nur die C-Daten (werden wiederverwendet).
    // Daher in owned Memory kopieren, sonst use-after-free (Titel wird zu Müll).
    if len(tl.title) > 0 do delete(tl.title)
    tl.title = strings.clone(string(title))
    fmt.printfln("[xdg] toplevel title = %q", tl.title)
}
xdg_toplevel_set_app_id :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, app_id: cstring) {
    context = ctx
    fmt.printfln("[xdg] toplevel app_id = %q", string(app_id))
}
xdg_toplevel_set_parent       :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, parent: ^wls.wl_resource) {}
xdg_toplevel_show_window_menu :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32, x, y: i32) {}
xdg_toplevel_move             :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32) {}
xdg_toplevel_resize           :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32, edges: u32) {}
xdg_toplevel_set_max_size     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {}
xdg_toplevel_set_min_size     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {}
xdg_toplevel_set_fullscreen   :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, output: ^wls.wl_resource) {}

xdg_toplevel_impl: wls.xdg_toplevel_interface = {
    destroy = xdg_toplevel_destroy,
    set_parent = xdg_toplevel_set_parent,
    set_title = xdg_toplevel_set_title,
    set_app_id = xdg_toplevel_set_app_id,
    show_window_menu = xdg_toplevel_show_window_menu,
    move = xdg_toplevel_move,
    resize = xdg_toplevel_resize,
    set_max_size = xdg_toplevel_set_max_size,
    set_min_size = xdg_toplevel_set_min_size,
    set_maximized = noop_req,
    unset_maximized = noop_req,
    set_fullscreen = xdg_toplevel_set_fullscreen,
    unset_fullscreen = noop_req,
    set_minimized = noop_req,
}

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_positioner + xdg_popup — Minimal-Vtables (no-op, nur für Popups).
// ═══════════════════════════════════════════════════════════════════════════
pos_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) { wls.resource_destroy(resource) }
pos_set_size        :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {}
pos_set_anchor_rect :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {}
pos_set_anchor      :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, anchor: u32) {}
pos_set_gravity     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, gravity: u32) {}
pos_set_constraint  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, ca: u32) {}
pos_set_offset      :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y: i32) {}
pos_set_parent_size :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, pw, ph: i32) {}
pos_set_parent_conf :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32) {}

xdg_positioner_impl: wls.xdg_positioner_interface = {
    destroy = pos_destroy,
    set_size = pos_set_size,
    set_anchor_rect = pos_set_anchor_rect,
    set_anchor = pos_set_anchor,
    set_gravity = pos_set_gravity,
    set_constraint_adjustment = pos_set_constraint,
    set_offset = pos_set_offset,
    set_reactive = noop_req,
    set_parent_size = pos_set_parent_size,
    set_parent_configure = pos_set_parent_conf,
}

popup_destroy  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) { wls.resource_destroy(resource) }
popup_grab     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32) {}
popup_reposition :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, positioner: ^wls.wl_resource, token: u32) {}

xdg_popup_impl: wls.xdg_popup_interface = {
    destroy = popup_destroy,
    grab = popup_grab,
    reposition = popup_reposition,
}

// ═══════════════════════════════════════════════════════════════════════════
//  Global registrieren (aus main/register_globals)
// ═══════════════════════════════════════════════════════════════════════════
register_xdg_global :: proc(server: ^Server) -> bool {
    if wls.global_create(server.display, &wls.xdg_wm_base_iface, 1, server, xdg_wm_base_bind) == nil {
        fmt.println("[init] xdg_wm_base global fehlgeschlagen"); return false
    }
    fmt.println("[init] xdg_wm_base global registriert (v1)")
    return true
}