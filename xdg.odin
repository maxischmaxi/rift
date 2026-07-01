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
    popup: ^XdgPopup,            // nil bis get_popup (Rolle schließt toplevel aus)
    configured: bool,            // Client hat das initiale configure geackt
    configure_serial: u32,       // zuletzt gesendeter Serial
    awaiting_ack: bool,          // configure raus, ack steht aus (max. 1 in-flight)
    win_geom: Rect,              // window geometry (Inhalt ohne CSD-Schatten)
    has_win_geom: bool,          // set_window_geometry kam (sonst = ganzer Buffer)
}

// One-Shot-Rezept für die Popup-Platzierung (xdg_positioner). Lebt als
// user_data der positioner-Resource; get_popup KOPIERT die Werte (Clients
// dürfen den Positioner sofort danach zerstören — GTK tut das).
XdgPositioner :: struct {
    size_w, size_h: i32,
    anchor_rect: Rect,
    anchor: u32,
    gravity: u32,
    offset_x, offset_y: i32,
}

XdgPopup :: struct {
    xdg_surface: ^XdgSurface,    // eigene xdg_surface (back-link)
    resource: ^wls.wl_resource,
    parent: ^XdgSurface,         // Parent: Toplevel ODER Popup (verschachtelte Menüs)
    rel: Rect,                   // Position relativ zur Window-Geometry des Parents
    mapped: bool,
    grabbed: bool,               // grab kam → Außenklick sendet popup_done
}

XdgToplevel :: struct {
    xdg_surface: ^XdgSurface,
    resource: ^wls.wl_resource,  // xdg_toplevel-Resource
    title: string,
    mapped: bool,
    geom: Rect,                 // {x,y,w,h} im Nested-Fenster (vom Tiling-Baum zugewiesen)
    floating: bool,             // true = frei positioniert (nicht im Tiling-Baum)
    float_geom: Rect,           // {x,y,w,h} im Floating-Modus
    fullscreen: bool,           // true = nimmt die ganze Canvas ein (über allem)
    // configure-Pipeline (echtes Resize)
    sent_w, sent_h: i32,        // Größe des zuletzt gesendeten configure
    sent_activated: bool,       // ACTIVATED-Bit des zuletzt gesendeten configure
    sent_fullscreen: bool,      // FULLSCREEN-Bit des zuletzt gesendeten configure
    configure_dirty: bool,      // Layout änderte sich, während ack ausstand
    min_w, min_h: i32,          // set_min_size (0 = unset)
    max_w, max_h: i32,          // set_max_size (0 = unbegrenzt)
    app_id: string,             // set_app_id (owned; für Window-Rules)
    // set_parent → Dialog-Erkennung. NUR mit nil vergleichen, nie dereferenzieren:
    // stirbt ein ungemappter Parent, kann der Zeiger danglen (gemappte werden
    // in den Destroy-Pfaden bereinigt).
    parent: ^XdgToplevel,
}

// Zentrale configure-Pipeline: schickt dem Client seine Layout-Größe + States.
// Ack-Gating: maximal EIN configure in-flight pro Toplevel — weitere Layout-
// Änderungen setzen nur configure_dirty; ack_configure sendet dann den
// aktuellen Stand nach. Verhindert configure-Stürme beim Split-Ratio-Drag.
toplevel_send_configure :: proc(tl: ^XdgToplevel) {
    context = ctx
    if tl == nil || tl.resource == nil || tl.xdg_surface == nil do return
    xs := tl.xdg_surface
    g := toplevel_render_geom(tl)
    w, h := g[2], g[3]
    if w <= 0 || h <= 0 do return   // noch kein Layout zugewiesen
    if !tl.fullscreen {
        if tl.min_w > 0 && w < tl.min_w do w = tl.min_w
        if tl.min_h > 0 && h < tl.min_h do h = tl.min_h
        if tl.max_w > 0 && w > tl.max_w do w = tl.max_w
        if tl.max_h > 0 && h > tl.max_h do h = tl.max_h
    }
    activated := tl == g_server.focused
    if w == tl.sent_w && h == tl.sent_h && activated == tl.sent_activated && tl.fullscreen == tl.sent_fullscreen do return
    if xs.awaiting_ack {
        tl.configure_dirty = true
        return
    }
    serial := wls.display_next_serial(g_server.display)
    xs.configure_serial = serial
    xs.awaiting_ack = true
    // states-Array stack-lokal — resource_post_event kopiert beim Marshalling.
    states: [2]u32
    n: uint = 0
    if activated { states[n] = wls.XDG_TOPLEVEL_STATE_ACTIVATED; n += 1 }
    if tl.fullscreen { states[n] = wls.XDG_TOPLEVEL_STATE_FULLSCREEN; n += 1 }
    arr := wls.wl_array{ size = c.size_t(n * size_of(u32)), alloc = c.size_t(len(states) * size_of(u32)), data = raw_data(states[:]) }
    wls.xdg_toplevel_send_configure(tl.resource, w, h, &arr)
    wls.xdg_surface_send_configure(xs.resource, serial)
    tl.sent_w = w; tl.sent_h = h; tl.sent_activated = activated; tl.sent_fullscreen = tl.fullscreen
    fmt.printfln("[xdg] configure %q → %dx%d activated=%v (serial %d)", tl.title, w, h, activated, serial)
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
    context = ctx
    pos_res := wls.resource_create(client, &wls.xdg_positioner_iface, 1, id)
    if pos_res == nil { wls.client_post_no_memory(client); return }
    pos := new(XdgPositioner)
    wls.resource_set_implementation(pos_res, &xdg_positioner_impl, pos, pos_destroy_resource)
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
        // Toplevel-Lebenszyklus HIER besitzen (xdg_toplevel-Handler wird no-op).
        if xs.toplevel.mapped do toplevel_unmap(xs.toplevel)
        toplevel_clear_parent_refs(xs.toplevel)
        if len(xs.toplevel.title) > 0 do delete(xs.toplevel.title)
        if len(xs.toplevel.app_id) > 0 do delete(xs.toplevel.app_id)
        wls.resource_set_user_data(xs.toplevel.resource, nil)  // → xdg_toplevel_destroy no-op
        free(xs.toplevel, ctx.allocator)
        xs.toplevel = nil
    }
    if xs.popup != nil {
        // Popup-Lebenszyklus analog: aus Liste nehmen, xdg_popup-Handler wird no-op.
        p := xs.popup
        popup_unmap(p)
        for q, i in g_server.popups {
            if q == p { ordered_remove(&g_server.popups, i); break }
        }
        wls.resource_set_user_data(p.resource, nil)   // → xdg_popup_destroy_resource no-op
        free(p, ctx.allocator)
        xs.popup = nil
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
    // 0/0 bedeutet "Client wählt eigene Größe". Nach dem Map schickt
    // layout_toplevels via toplevel_send_configure die echte Tile-Größe nach.
    serial := wls.display_next_serial(g_server.display)
    xs.configure_serial = serial
    xs.awaiting_ack = true
    wls.xdg_toplevel_send_configure(tl.resource, 0, 0, &empty_states)
    wls.xdg_surface_send_configure(xs.resource, serial)
    fmt.printfln("[xdg] get_toplevel → configure serial %d gesendet", serial)
}

// Ankerpunkt + Wuchsrichtung auf dem anchor_rect auswerten (Enums für anchor
// und gravity teilen das Nummernschema: 0=none 1=top 2=bottom 3=left 4=right
// 5=top_left 6=bottom_left 7=top_right 8=bottom_right).
positioner_compute :: proc(pos: ^XdgPositioner) -> Rect {
    w := pos.size_w > 0 ? pos.size_w : 1
    h := pos.size_h > 0 ? pos.size_h : 1
    r := pos.anchor_rect
    ax, ay := r[0], r[1]
    switch pos.anchor {
    case 3, 5, 6: // left
    case 4, 7, 8: ax += r[2]         // right
    case:         ax += r[2] / 2     // zentriert
    }
    switch pos.anchor {
    case 1, 5, 7: // top
    case 2, 6, 8: ay += r[3]         // bottom
    case:         ay += r[3] / 2
    }
    // Gravity = Richtung, in die das Popup vom Ankerpunkt WEGwächst.
    x := ax + pos.offset_x
    y := ay + pos.offset_y
    switch pos.gravity {
    case 3, 5, 6: x -= w             // wächst nach links
    case 4, 7, 8: // nach rechts
    case:         x -= w / 2
    }
    switch pos.gravity {
    case 1, 5, 7: y -= h             // nach oben
    case 2, 6, 8: // nach unten
    case:         y -= h / 2
    }
    return {x, y, w, h}
}

xdg_surface_get_popup :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32, parent: ^wls.wl_resource, positioner: ^wls.wl_resource) {
    context = ctx
    pop_res := wls.resource_create(client, &wls.xdg_popup_iface, 1, id)
    if pop_res == nil { wls.client_post_no_memory(client); return }
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    parent_xs := parent != nil ? (^XdgSurface)(wls.resource_get_user_data(parent)) : nil
    pos := positioner != nil ? (^XdgPositioner)(wls.resource_get_user_data(positioner)) : nil
    if xs == nil || parent_xs == nil || pos == nil {
        // Popup ohne Parent (v1-Protokoll kennt das nicht sinnvoll) → no-op-Resource,
        // damit der Client keinen Protokollfehler bekommt.
        fmt.println("[xdg] get_popup ohne parent/positioner — no-op")
        wls.resource_set_implementation(pop_res, &xdg_popup_impl, nil, nil)
        return
    }
    p := new(XdgPopup)
    p.xdg_surface = xs
    p.resource = pop_res
    p.parent = parent_xs
    p.rel = positioner_compute(pos)   // Positioner-Werte JETZT auswerten (Kopie)
    xs.popup = p
    append(&g_server.popups, p)       // Append-Reihenfolge = Stacking unten→oben
    wls.resource_set_implementation(pop_res, &xdg_popup_impl, p, xdg_popup_destroy_resource)
    // Configure-Handshake sofort (bei Popups üblich): Position + Größe zusagen.
    serial := wls.display_next_serial(g_server.display)
    xs.configure_serial = serial
    wls.xdg_popup_send_configure(pop_res, p.rel[0], p.rel[1], p.rel[2], p.rel[3])
    wls.xdg_surface_send_configure(xs.resource, serial)
    fmt.printfln("[xdg] popup → rel %d,%d %dx%d (serial %d)", p.rel[0], p.rel[1], p.rel[2], p.rel[3], serial)
}

xdg_surface_set_window_geometry :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {
    context = ctx
    // Window-Geometry = sichtbarer Inhalt ohne CSD-Schatten. Ohne sie sitzen
    // GTK-Fenster, Klick-Koordinaten und Popup-Anker um die Schattenbreite daneben.
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    if xs == nil || w <= 0 || h <= 0 do return
    xs.win_geom = {x, y, w, h}
    xs.has_win_geom = true
}

xdg_surface_ack_configure :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32) {
    context = ctx
    xs := (^XdgSurface)(wls.resource_get_user_data(resource))
    if serial == xs.configure_serial {
        xs.configured = true
        xs.awaiting_ack = false
        // Während des in-flight configure hat sich das Layout weiterbewegt →
        // jetzt den AKTUELLEN Stand nachsenden (Ack-Gating, max. 1 in-flight).
        if xs.toplevel != nil && xs.toplevel.configure_dirty {
            xs.toplevel.configure_dirty = false
            toplevel_send_configure(xs.toplevel)
        }
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
    if tl == nil do return   // schon von xdg_surface_destroy_resource aufgeräumt
    if tl.mapped do toplevel_unmap(tl)   // aus Layout nehmen + restliche Fenster neu zeichnen
    if tl.xdg_surface != nil do tl.xdg_surface.toplevel = nil
    toplevel_clear_parent_refs(tl)
    if len(tl.app_id) > 0 do delete(tl.app_id)
    free(tl, ctx.allocator)
}

// Parent-Rückverweise anderer (gemappter) Toplevels auf ein sterbendes
// Toplevel lösen — sonst dangling ^XdgToplevel in deren parent-Feld.
toplevel_clear_parent_refs :: proc(tl: ^XdgToplevel) {
    for ws in g_server.workspaces {
        for t in ws.toplevels {
            if t.parent == tl do t.parent = nil
        }
    }
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
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil do return
    // Wie set_title: cstring-Daten in owned Memory kopieren.
    if len(tl.app_id) > 0 do delete(tl.app_id)
    tl.app_id = strings.clone(string(app_id))
    fmt.printfln("[xdg] toplevel app_id = %q", tl.app_id)
}
xdg_toplevel_set_parent :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, parent: ^wls.wl_resource) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil do return
    tl.parent = parent != nil ? (^XdgToplevel)(wls.resource_get_user_data(parent)) : nil
}
xdg_toplevel_show_window_menu :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32, x, y: i32) {}
xdg_toplevel_move             :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32) {}
xdg_toplevel_resize           :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32, edges: u32) {}
xdg_toplevel_set_max_size     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil || w < 0 || h < 0 do return
    tl.max_w = w; tl.max_h = h
}
xdg_toplevel_set_min_size     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil || w < 0 || h < 0 do return
    tl.min_w = w; tl.min_h = h
}
xdg_toplevel_set_fullscreen   :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, output: ^wls.wl_resource) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil || tl.fullscreen do return
    tl.fullscreen = true
    toplevel_send_configure(tl)
    composite_all()
    fmt.printfln("[xdg] FULLSCREEN → %q", tl.title)
}
xdg_toplevel_unset_fullscreen :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil || !tl.fullscreen do return
    tl.fullscreen = false
    toplevel_send_configure(tl)
    composite_all()
    fmt.printfln("[xdg] fullscreen aus → %q", tl.title)
}
// Maximize in einem Tiling-WM: kein eigener Zustand — aber der Client wartet
// protokollkonform auf ein Antwort-configure. Aktuellen Zustand (erneut) senden.
xdg_toplevel_set_maximized :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    context = ctx
    tl := (^XdgToplevel)(wls.resource_get_user_data(resource))
    if tl == nil do return
    tl.sent_w = 0   // Änderungs-Erkennung umgehen → configure geht sicher raus
    toplevel_send_configure(tl)
}

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
    set_maximized = xdg_toplevel_set_maximized,
    unset_maximized = xdg_toplevel_set_maximized,
    set_fullscreen = xdg_toplevel_set_fullscreen,
    unset_fullscreen = xdg_toplevel_unset_fullscreen,
    set_minimized = noop_req,
}

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_positioner — speichert das Platzierungs-Rezept in XdgPositioner.
// ═══════════════════════════════════════════════════════════════════════════
positioner_get :: proc "c" (resource: ^wls.wl_resource) -> ^XdgPositioner {
    return (^XdgPositioner)(wls.resource_get_user_data(resource))
}
pos_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) { wls.resource_destroy(resource) }
pos_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    pos := positioner_get(resource)
    if pos != nil do free(pos, ctx.allocator)
}
pos_set_size        :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, w, h: i32) {
    if pos := positioner_get(resource); pos != nil { pos.size_w = w; pos.size_h = h }
}
pos_set_anchor_rect :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {
    if pos := positioner_get(resource); pos != nil { pos.anchor_rect = {x, y, w, h} }
}
pos_set_anchor      :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, anchor: u32) {
    if pos := positioner_get(resource); pos != nil { pos.anchor = anchor }
}
pos_set_gravity     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, gravity: u32) {
    if pos := positioner_get(resource); pos != nil { pos.gravity = gravity }
}
pos_set_constraint  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, ca: u32) {}
pos_set_offset      :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y: i32) {
    if pos := positioner_get(resource); pos != nil { pos.offset_x = x; pos.offset_y = y }
}
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

// ═══════════════════════════════════════════════════════════════════════════
//  xdg_popup — Lifecycle + Dismissal.
// ═══════════════════════════════════════════════════════════════════════════

// Wurzel-Toplevel der Parent-Kette (Popup → … → Toplevel).
popup_root_toplevel :: proc(p: ^XdgPopup) -> ^XdgToplevel {
    parent := p.parent
    for parent != nil {
        if parent.toplevel != nil do return parent.toplevel
        if parent.popup != nil { parent = parent.popup.parent; continue }
        return nil
    }
    return nil
}

// Absolute Canvas-Position des Popups (Parent-Kette aufsummieren).
// anchor_rect ist relativ zur Window-Geometry-Box des Parents; die liegt
// durch das 1:1-Rendering exakt auf dem Tile-Origin.
popup_abs_pos :: proc(p: ^XdgPopup) -> (i32, i32) {
    px, py := i32(0), i32(0)
    if p.parent != nil {
        if p.parent.toplevel != nil {
            g := toplevel_render_geom(p.parent.toplevel)
            px, py = g[0], g[1]
        } else if p.parent.popup != nil {
            px, py = popup_abs_pos(p.parent.popup)
        }
    }
    return px + p.rel[0], py + p.rel[1]
}

// Popup unmappen (ohne die Resource anzutasten). Kinder zuerst.
popup_unmap :: proc(p: ^XdgPopup) {
    context = ctx
    if !p.mapped do return
    p.mapped = false
    // verschachtelte Kinder mit dismissen
    #reverse for child in g_server.popups {
        if child.mapped && child.parent == p.xdg_surface {
            wls.xdg_popup_send_popup_done(child.resource)
            popup_unmap(child)
        }
    }
    if g_server.ptr_focus != nil && p.xdg_surface != nil && g_server.ptr_focus == p.xdg_surface.surface {
        g_server.ptr_focus = nil
    }
}

// Alle Popups eines Toplevels dismissen (Fenster schließt / unmappt).
popup_dismiss_for_toplevel :: proc(tl: ^XdgToplevel) {
    context = ctx
    #reverse for p in g_server.popups {
        if p.mapped && popup_root_toplevel(p) == tl {
            wls.xdg_popup_send_popup_done(p.resource)
            popup_unmap(p)
        }
    }
}

// Außenklick: alle grabbed Popups schließen (oberste zuerst).
popup_dismiss_grabbed :: proc() -> bool {
    context = ctx
    any := false
    #reverse for p in g_server.popups {
        if p.mapped && p.grabbed {
            wls.xdg_popup_send_popup_done(p.resource)
            popup_unmap(p)
            any = true
        }
    }
    return any
}

xdg_popup_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    p := (^XdgPopup)(wls.resource_get_user_data(resource))
    if p == nil do return
    popup_unmap(p)
    for q, i in g_server.popups {
        if q == p { ordered_remove(&g_server.popups, i); break }
    }
    if p.xdg_surface != nil do p.xdg_surface.popup = nil
    free(p, ctx.allocator)
    composite_all()
}

popup_destroy  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) { wls.resource_destroy(resource) }
popup_grab     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, seat: ^wls.wl_resource, serial: u32) {
    context = ctx
    p := (^XdgPopup)(wls.resource_get_user_data(resource))
    if p != nil do p.grabbed = true   // kein echter Grab — nur Außenklick-Dismissal
}
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