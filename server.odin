package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:time"
import "base:runtime"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  rift-Compositor — Globals, Bind-Handler, Request-Handler.
//
//  Erste echte Compositor-Logik: Clients können sich verbinden, Globals
//  auflisten und binden, eine Surface anlegen. Es wird noch nichts gerendert
//  (kein Output-Backend) — das ist die reine Protokoll-Ebene.
//
//  WICHTIG: libwayland crasht (wl_abort), wenn ein Request einen nil-Handler
//  trifft (connection.c:1239). Daher wird JEDER Handler gefüllt, ggf. noop.
// ═══════════════════════════════════════════════════════════════════════════

// ─── Zustand ───────────────────────────────────────────────────────────
Server :: struct {
    display: ^wls.wl_display,
    toplevels: [dynamic]^XdgToplevel,   // alle gemappten Fenster (für Layout/Composite)
}

// Globaler Server-Pointer (für Handler, die Serials/display brauchen).
g_server: ^Server

// Odin-context für C-Callbacks (fmt/allocation brauchen context).
// proc "c" bekommt kein context → wir restaurieren es aus dieser globalen.
ctx: runtime.Context

// ─── Universeller Noop-Handler (2-Arg-Form: client + resource) ─────────
noop_req :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {}

// ─── Surface-Zustand (double-buffered: pending → current bei commit) ─────
//  Wayland-Surfaces sind doppelt gepuffert: der Client sammelt Änderungen
//  in `pending` und promotes sie mit wl_surface.commit nach `current`.
//  Frame-Callbacks feuern wir (ohne echtes Rendering) direkt beim commit —
//  das ist eine Vereinfachung; ein echter Compositor feuert sie nach der
//  Presentation auf dem Output.
Rect :: [4]i32   // {x, y, w, h}

Surface :: struct {
    // pending (vom Client gesetzt, bis commit kommt)
    pending_buffer:  ^wls.wl_resource,   // nil = detach
    pending_dx:      i32,
    pending_dy:      i32,
    pending_damage:  [dynamic]Rect,
    // current (nach commit das aktive Bild)
    current_buffer: ^wls.wl_resource,
    // Frame-Callbacks, die beim nächsten commit feuern sollen
    frame_callbacks: [dynamic]^wls.wl_resource,
    // xdg-Rolle (nil = nackte Surface ohne Fenster-Rolle)
    xdg: ^XdgSurface,
}

// Hilfsfunktion: Surface-Pointer aus einer Resource holen.
surface_get :: proc(resource: ^wls.wl_resource) -> ^Surface {
    return (^Surface)(wls.resource_get_user_data(resource))
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_compositor
// ═══════════════════════════════════════════════════════════════════════════

compositor_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[compositor] Client bindet wl_compositor (v", version, ")")
    server := (^Server)(data)
    resource := wls.resource_create(client, &wls.compositor_interface, c.int(version), id)
    if resource == nil {
        wls.client_post_no_memory(client)
        return
    }
    wls.resource_set_implementation(resource, &compositor_impl, server, nil)
}

compositor_create_surface :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    fmt.println("[compositor] create_surface angefordert")
    surface := new(Surface)   // zero-init: pending/current_buffer=nil, dyn-Arrays leer
    surface_resource := wls.resource_create(client, &wls.surface_interface, 4, id)
    if surface_resource == nil {
        delete(surface.pending_damage)
        delete(surface.frame_callbacks)
        free(surface, ctx.allocator)
        wls.client_post_no_memory(client)
        return
    }
    // user_data = unsere Surface-Struct; destroy-Callback gibt sie frei.
    wls.resource_set_implementation(surface_resource, &surface_impl, surface, surface_destroy_resource)
}

compositor_create_region :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    region_resource := wls.resource_create(client, &wls.region_interface, 2, id)
    if region_resource == nil {
        wls.client_post_no_memory(client)
        return
    }
    wls.resource_set_implementation(region_resource, &region_impl, nil, nil)
}

// Vtable als VARIABLE (nicht ::), damit &address genommen werden kann.
compositor_impl: wls.wl_compositor_interface = {
    create_surface = compositor_create_surface,
    create_region  = compositor_create_region,
    release        = noop_req,
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_surface — 12 Handler (v4 → offset/get_release kommen nicht, aber gefüllt).
// ═══════════════════════════════════════════════════════════════════════════

// Wird von libwayland aufgerufen, wenn die wl_surface-Resource zerstört wird
// (Client schickt destroy, oder Client trennt). Gibt die Surface-Struct frei.
surface_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    surface := surface_get(resource)
    // Aktuellen Buffer releasen, damit der Client ihn wiederverwenden kann.
    if surface.current_buffer != nil {
        wls.resource_post_event(surface.current_buffer, wls.WL_BUFFER_RELEASE)
    }
    // Ausstehende Frame-Callback-Resources killen.
    for cb in surface.frame_callbacks {
        wls.resource_destroy(cb)
    }
    delete(surface.pending_damage)
    delete(surface.frame_callbacks)
    free(surface, ctx.allocator)
}

surface_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    // resource_destroy triggert surface_destroy_resource (unten) → gibt frei.
    wls.resource_destroy(resource)
}
surface_attach :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, buffer: ^wls.wl_resource, x, y: i32) {
    context = ctx
    surface := surface_get(resource)
    surface.pending_buffer = buffer   // nil = detach
    surface.pending_dx = x
    surface.pending_dy = y
}
surface_damage :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {
    context = ctx
    surface := surface_get(resource)
    append(&surface.pending_damage, Rect{x, y, w, h})
}
surface_frame :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, callback_id: u32) {
    context = ctx
    surface := surface_get(resource)
    cb := wls.resource_create(client, &wls.callback_interface, 1, callback_id)
    if cb == nil { wls.client_post_no_memory(client); return }
    // wl_callback hat KEINE Requests (nur done-Event) → nil-Implementation sicher.
    wls.resource_set_implementation(cb, nil, nil, nil)
    append(&surface.frame_callbacks, cb)
}
surface_set_opaque_region :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, region: ^wls.wl_resource) {}
surface_set_input_region  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, region: ^wls.wl_resource) {}
surface_commit :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    context = ctx
    surface := surface_get(resource)

    // 1) pending → current promoten. Alten current-Buffer releasen,
    //    wenn er durch einen anderen ersetzt wird.
    if surface.current_buffer != nil && surface.current_buffer != surface.pending_buffer {
        wls.resource_post_event(surface.current_buffer, wls.WL_BUFFER_RELEASE)
    }
    surface.current_buffer = surface.pending_buffer

    // 2) Map-Logik: xdg-Toplevel wird gemappt, wenn configure geackt + Buffer da.
    if surface.xdg != nil && surface.xdg.toplevel != nil && surface.xdg.configured {
        tl := surface.xdg.toplevel
        if !tl.mapped {
            tl.mapped = true
            fmt.printfln("[xdg] Toplevel %q GEMAPPT", tl.title)
            append(&g_server.toplevels, tl)   // Fenster registrieren
            layout_toplevels()                 // Neu-Layout aller Fenster
        }
    }

    if surface.current_buffer != nil {
        shm := wls.shm_buffer_get(surface.current_buffer)
        if shm != nil {
            w := wls.shm_buffer_get_width(shm)
            h := wls.shm_buffer_get_height(shm)
            f := wls.shm_buffer_get_format(shm)
            fmt.printfln("[surface] commit: shm-Buffer %dx%d format=%d  damage=%d rects",
                w, h, f, len(surface.pending_damage))
            // Compositing:
            //  • xdg-Toplevel → composite_all (alle Fenster neu zeichnen, skaliert+getilt)
            //  • nackte Surface (keine Rolle) → direkter Fullscreen-Blit (alte API)
            if surface.xdg != nil && surface.xdg.toplevel != nil && surface.xdg.toplevel.mapped {
                composite_all()                       // liest selbst alle Buffer (begin/end access)
            } else if surface.xdg == nil {
                wls.shm_buffer_begin_access(shm)
                src := cast([^]u32)(wls.shm_buffer_get_data(shm))
                nested_present(src, w, h)
                wls.shm_buffer_end_access(shm)
            }
        } else {
            fmt.println("[surface] commit: Buffer (nicht-shm)")
        }
    } else {
        fmt.println("[surface] commit: kein Buffer (detach)")
    }

    // 3) Damage für diesen Frame verwerfen (würde beim Rendern verbraucht).
    clear(&surface.pending_damage)

    // 4) Frame-Callbacks feuern (done-Event mit Zeitstempel) & Resources freigeben.
    //    Echter Compositor: feuert nach Presentation. Wir feuern direkt (kein Backend).
    if len(surface.frame_callbacks) > 0 {
        t := time.now()
        ms := u32((time.to_unix_nanoseconds(t) / 1_000_000) & 0xFFFFFFFF)
        for cb in surface.frame_callbacks {
            wls.resource_post_event(cb, wls.WL_CALLBACK_DONE, ms)
            wls.resource_destroy(cb)
        }
        clear(&surface.frame_callbacks)
    }
}
surface_set_buffer_transform :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, transform: i32) {}
surface_set_buffer_scale     :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, scale: i32) {}
surface_damage_buffer        :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {}
surface_offset_noop         :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y: i32) {}
surface_get_release_noop    :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, callback_id: u32) {}

surface_impl: wls.wl_surface_interface = {
    destroy              = surface_destroy,
    attach               = surface_attach,
    damage               = surface_damage,
    frame                = surface_frame,
    set_opaque_region    = surface_set_opaque_region,
    set_input_region     = surface_set_input_region,
    commit               = surface_commit,
    set_buffer_transform = surface_set_buffer_transform,
    set_buffer_scale     = surface_set_buffer_scale,
    damage_buffer        = surface_damage_buffer,
    offset               = surface_offset_noop,
    get_release          = surface_get_release_noop,
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_region
// ═══════════════════════════════════════════════════════════════════════════
region_destroy  :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) { wls.resource_destroy(resource) }
region_add      :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {}
region_subtract :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y, w, h: i32) {}

region_impl: wls.wl_region_interface = {
    destroy  = region_destroy,
    add      = region_add,
    subtract = region_subtract,
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_seat — capabilities=0 (keine Geräte), aber alle Handler gefüllt.
// ═══════════════════════════════════════════════════════════════════════════
WL_SEAT_CAPABILITY_POINTER  :: u32(1)
WL_SEAT_CAPABILITY_KEYBOARD :: u32(2)
WL_SEAT_CAPABILITY_TOUCH    :: u32(4)

seat_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[seat] Client bindet wl_seat (v", version, ")")
    server := (^Server)(data)
    resource := wls.resource_create(client, &wls.seat_interface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &seat_impl, server, nil)
    wls.seat_send_capabilities(resource, 0)   // keine Eingabegeräte
}

seat_get_pointer :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    ptr := wls.resource_create(client, &wls.pointer_interface, 4, id)
    if ptr == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(ptr, &pointer_impl, nil, nil)
}
seat_get_keyboard :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    kb := wls.resource_create(client, &wls.keyboard_interface, 4, id)
    if kb == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(kb, &keyboard_impl, nil, nil)
}
seat_get_touch :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    t := wls.resource_create(client, &wls.touch_interface, 4, id)
    if t == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(t, &touch_impl, nil, nil)
}
pointer_set_cursor :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32, surface: ^wls.wl_resource, hx, hy: i32) {}

pointer_impl:  wls.wl_pointer_interface = { set_cursor = pointer_set_cursor, release = noop_req }
keyboard_impl: wls.wl_keyboard_interface = { release = noop_req }
touch_impl:    wls.wl_touch_interface    = { release = noop_req }
seat_impl: wls.wl_seat_interface = {
    get_pointer  = seat_get_pointer,
    get_keyboard = seat_get_keyboard,
    get_touch    = seat_get_touch,
    release      = noop_req,
}

// ═══════════════════════════════════════════════════════════════════════════
//  wl_output — virtueller Monitor.
// ═══════════════════════════════════════════════════════════════════════════
WL_OUTPUT_MODE_CURRENT   :: u32(0x1)
WL_OUTPUT_MODE_PREFERRED :: u32(0x2)

output_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[output] Client bindet wl_output (v", version, ")")
    resource := wls.resource_create(client, &wls.output_interface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &output_impl, nil, nil)
    wls.output_send_geometry(resource, 0, 0, 800, 600, 0, "rift", "virtual", 0)
    wls.output_send_mode(resource, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED, 1920, 1080, 60000)
    if version >= 2 {
        wls.resource_post_event(resource, wls.WL_OUTPUT_DONE)
    }
}

output_impl: wls.wl_output_interface = { release = noop_req }

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-Window-Compositing — alle gemappten Toplevels ins Nested-Fenster.
//  Layout: horizontales Tiling (N Fenster → jedes bekommt 1/N der Breite).
//  Composite: Hintergrund löschen, dann jeden Toplevel (skaliert) blitten.
// ═══════════════════════════════════════════════════════════════════════════

layout_toplevels :: proc() {
    context = ctx
    n := len(g_server.toplevels)
    if n == 0 do return
    tile_w := NESTED_W / n
    for tl, i in g_server.toplevels {
        tl.geom = Rect{i32(i * tile_w), 0, i32(tile_w), i32(NESTED_H)}
    }
    fmt.printfln("[layout] %d Fenster → je %dx%d", n, tile_w, NESTED_H)
}

composite_all :: proc() {
    context = ctx
    nested_clear(0xFF1a1a2a)   // dunkler Hintergrund
    for tl in g_server.toplevels {
        xs := tl.xdg_surface
        if xs == nil || xs.surface == nil do continue
        surf := xs.surface
        if surf.current_buffer == nil do continue
        shm := wls.shm_buffer_get(surf.current_buffer)
        if shm == nil do continue
        wls.shm_buffer_begin_access(shm)
        src := cast([^]u32)(wls.shm_buffer_get_data(shm))
        sw := wls.shm_buffer_get_width(shm)
        sh := wls.shm_buffer_get_height(shm)
        nested_blit_scaled(src, sw, sh, tl.geom[0], tl.geom[1], tl.geom[2], tl.geom[3])
        wls.shm_buffer_end_access(shm)
    }
    nested_commit_window()
}

// Toplevel aus der Liste entfernen (bei Destroy) + Neu-Layout/Composite.
toplevel_unmap :: proc(tl: ^XdgToplevel) {
    context = ctx
    for t, i in g_server.toplevels {
        if t == tl {
            ordered_remove(&g_server.toplevels, i)
            break
        }
    }
    layout_toplevels()
    composite_all()
}

// ═══════════════════════════════════════════════════════════════════════════
//  Globals registrieren (aus main)
// ═══════════════════════════════════════════════════════════════════════════
register_globals :: proc(server: ^Server) -> bool {
    context = ctx
    if wls.display_init_shm(server.display) != 0 {
        fmt.println("[init] display_init_shm fehlgeschlagen")
        return false
    }
    fmt.println("[init] wl_shm global registriert (via libwayland)")

    if wls.global_create(server.display, &wls.compositor_interface, 4, server, compositor_bind) == nil {
        fmt.println("[init] wl_compositor global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_compositor global registriert (v4)")

    if wls.global_create(server.display, &wls.seat_interface, 4, server, seat_bind) == nil {
        fmt.println("[init] wl_seat global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_seat global registriert (v4)")

    if wls.global_create(server.display, &wls.output_interface, 2, server, output_bind) == nil {
        fmt.println("[init] wl_output global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_output global registriert (v2)")
    return true
}