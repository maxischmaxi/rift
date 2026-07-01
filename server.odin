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
    workspaces: [dynamic]^Workspace,    // alle Workspaces (1-N)
    active_ws: ^Workspace,               // aktuell sichtbarer Workspace
    keyboards: [dynamic]^wls.wl_resource, // wl_keyboard-Resources der rift-Clients
    pointers:  [dynamic]^wls.wl_resource, // wl_pointer-Resources der rift-Clients
    outputs:   [dynamic]^wls.wl_resource, // wl_output-Resources (für mode-Updates + surface.enter)
    popups:    [dynamic]^XdgPopup,        // gemappte+ungemappte Popups (Reihenfolge = Stacking)
    focused:   ^XdgToplevel,              // aktuell fokussiertes Fenster (bekommt Keyboard)
    ptr_focus: ^Surface,                  // Surface unter dem Mauszeiger (Toplevel ODER Popup)
    // WM-Interaktion (Super/Alt + Drag)
    mods_depressed: u32,                  // aktuelle Modifier-Maske (vom Parent)
    mods_latched:   u32,                  // für modifiers-Event nach keyboard.enter
    mods_locked:    u32,
    mods_group:     u32,
    suppressed_keys: [dynamic]u32,        // Keys, deren Press ein Keybind schluckte → Release auch schlucken
    wm_mode:    WM_Mode,                  // None/Move/Resize
    wm_tl:      ^XdgToplevel,             // gezogenes/resizetes Fenster
    wm_split:   ^Node,                    // Split, dessen Ratio gezogen wird (Resize)
    wm_start_ratio: f64,                  // Ratio beim Resize-Start
    wm_start_x: f64, wm_start_y: f64,     // Cursorpos beim Start
    // Floating-Drag/Resize: Start-Geometrie
    wm_start_gx: i32, wm_start_gy: i32,   // Floating-Move: Start x,y
    wm_start_gw: i32, wm_start_gh: i32,   // Floating-Resize: Start w,h
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
    resource: ^wls.wl_resource,  // die wl_surface-Resource (für keyboard enter/leave)
    // pending (vom Client gesetzt, bis commit kommt)
    pending_buffer:  ^wls.wl_resource,   // nil = detach
    pending_dx:      i32,
    pending_dy:      i32,
    pending_damage:  [dynamic]Rect,
    // current (nach commit das aktive Bild)
    current_buffer: ^wls.wl_resource,
    // Destroy-Listener auf current_buffer: zerstört ein Client die wl_buffer,
    // solange sie noch attached ist, würde der Pointer sonst danglen (UAF in
    // composite_all). armed = Listener hängt gerade in einer Signal-Liste.
    buffer_destroy_listener: wls.wl_listener,
    buffer_listener_armed: bool,
    // Frame-Callbacks, die beim nächsten commit feuern sollen
    frame_callbacks: [dynamic]^wls.wl_resource,
    // xdg-Rolle (nil = nackte Surface ohne Fenster-Rolle)
    xdg: ^XdgSurface,
    // layer-shell-Rolle (rofi, Bars, …) — schließt xdg-Rolle aus
    layer: ^LayerSurface,
    // Cursor-Rolle (wl_pointer.set_cursor): nie als Fenster-Inhalt präsentieren
    is_cursor: bool,
    // Subsurface-Rolle + Kinder (wl_subcompositor)
    sub: ^Subsurface,
    children: [dynamic]^Subsurface,
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
    surface.resource = surface_resource
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
    // Layer-Rolle lösen (falls die wl_surface vor der layer_surface stirbt)
    if surface.layer != nil {
        surface.layer.mapped = false
        layer_keyboard_unfocus(surface.layer)
        surface.layer.surface = nil
        surface.layer = nil
    }
    // xdg-Rolle lösen: Bei Client-Disconnect zerstört libwayland Ressourcen in
    // ID-Reihenfolge — die wl_surface stirbt VOR ihrer xdg_surface. Ohne das
    // Nullen des Rückzeigers liest xdg_surface_destroy_resource später die
    // bereits freigegebene Surface (UAF bei praktisch jedem App-Schließen).
    if surface.xdg != nil {
        xs := surface.xdg
        if xs.toplevel != nil && xs.toplevel.mapped {
            toplevel_unmap(xs.toplevel)
        }
        if xs.popup != nil {
            popup_unmap(xs.popup)
        }
        xs.surface = nil
        surface.xdg = nil
    }
    if g_server.ptr_focus == surface do g_server.ptr_focus = nil
    // Subsurface-Verknüpfungen lösen: eigene Rolle (Kind stirbt) und Kinder
    // (Parent stirbt) — sonst danglen die Surface-Pointer in beiden Richtungen.
    if surface.sub != nil do subsurface_detach(surface.sub)
    for len(surface.children) > 0 {
        subsurface_detach(surface.children[0])
    }
    delete(surface.children)
    // Buffer-Destroy-Listener aushängen, BEVOR die Surface freigegeben wird —
    // sonst feuert er nach dem free auf die tote Surface.
    if surface.buffer_listener_armed {
        wls.list_remove(&surface.buffer_destroy_listener.link)
        surface.buffer_listener_armed = false
    }
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

// Feuert, wenn die aktuell attachte wl_buffer-Resource zerstört wird (z. B.
// Client-Realloc beim Resize oder Teardown in beliebiger ID-Reihenfolge).
surface_buffer_destroyed :: proc "c" (listener: ^wls.wl_listener, data: rawptr) {
    context = ctx
    surface := wls.container_of(listener, Surface, "buffer_destroy_listener")
    buf := (^wls.wl_resource)(data)
    if surface.current_buffer == buf do surface.current_buffer = nil
    if surface.pending_buffer == buf do surface.pending_buffer = nil
    wls.list_remove(&listener.link)
    surface.buffer_listener_armed = false
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
    // destroy-Handler räumt die Callback-Resource aus der globalen Pending-Liste
    // (Client-Disconnect, bevor der nächste Page Flip sie feuert).
    wls.resource_set_implementation(cb, nil, nil, frame_cb_destroy)
    append(&surface.frame_callbacks, cb)
}

// ─── Frame-Callbacks: im DRM-Modus VBlank-getaktet ──────────────────────────
// Sofortiges done beim Commit lässt Clients (Firefox!) unthrottled rendern —
// Commit-Sturm weit über der Monitor-Rate. Im DRM-Modus wandern die Callbacks
// deshalb in eine Pending-Liste und feuern erst beim Page-Flip-Event (Frame
// wurde präsentiert) → Clients takten sich auf die Monitor-Hz.
// Im Nested-Modus throttlet der Parent-Compositor uns bereits → sofort feuern.
g_pending_frame_cbs: [dynamic]^wls.wl_resource

frame_cb_destroy :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    for cb, i in g_pending_frame_cbs {
        if cb == resource { ordered_remove(&g_pending_frame_cbs, i); break }
    }
}

surface_flush_frames :: proc(surface: ^Surface) {
    if len(surface.frame_callbacks) == 0 do return
    if g_backend_drm {
        for cb in surface.frame_callbacks {
            append(&g_pending_frame_cbs, cb)
        }
        clear(&surface.frame_callbacks)
        return
    }
    t := time.now()
    ms := u32((time.to_unix_nanoseconds(t) / 1_000_000) & 0xFFFFFFFF)
    for cb in surface.frame_callbacks {
        wls.resource_post_event(cb, wls.WL_CALLBACK_DONE, ms)
        wls.resource_destroy(cb)
    }
    clear(&surface.frame_callbacks)
}

// Vom DRM-Flip-Handler aufgerufen: präsentierter Frame → alle pending done.
frame_cbs_fire_pending :: proc(ms: u32) {
    // resource_destroy → frame_cb_destroy entfernt das Element selbst aus der
    // Liste — deshalb keine for-Iteration (Mutation), sondern Abarbeiten von vorn.
    for len(g_pending_frame_cbs) > 0 {
        cb := g_pending_frame_cbs[0]
        wls.resource_post_event(cb, wls.WL_CALLBACK_DONE, ms)
        wls.resource_destroy(cb)
    }
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
    // Destroy-Listener auf den neuen current_buffer umhängen (gegen dangling
    // Pointer, falls der Client die wl_buffer zerstört, solange sie attached ist).
    if surface.buffer_listener_armed {
        wls.list_remove(&surface.buffer_destroy_listener.link)
        surface.buffer_listener_armed = false
    }
    if surface.current_buffer != nil {
        surface.buffer_destroy_listener.notify = surface_buffer_destroyed
        wls.resource_add_destroy_listener(surface.current_buffer, &surface.buffer_destroy_listener)
        surface.buffer_listener_armed = true
    }

    // 2a) Layer-Surface-Lebenszyklus (configure/map/unmap + Compositing)
    if surface.layer != nil {
        layer_surface_handle_commit(surface)
        clear(&surface.pending_damage)
        surface_flush_frames(surface)
        return
    }

    // 2b) Popup-Map: configure geackt + Buffer da → sichtbar machen.
    if surface.xdg != nil && surface.xdg.popup != nil && surface.xdg.configured {
        p := surface.xdg.popup
        if !p.mapped && surface.current_buffer != nil {
            p.mapped = true
            fmt.println("[xdg] Popup GEMAPPT")
        }
    }

    // 2) Map-Logik: xdg-Toplevel wird gemappt, wenn configure geackt + Buffer da.
    if surface.xdg != nil && surface.xdg.toplevel != nil && surface.xdg.configured {
        tl := surface.xdg.toplevel
        if !tl.mapped {
            tl.mapped = true
            fmt.printfln("[xdg] Toplevel %q GEMAPPT", tl.title)
            append(&g_server.active_ws.toplevels, tl)   // Fenster registrieren
            tree_add(tl)                     // in Split-Tree einfügen (splittet Fokus)
            // wl_surface.enter: dem Client sagen, auf welchem Output er ist
            // (manche Apps rendern erst nach dem ersten enter / wählen Scale).
            surf_client := wls.resource_get_client(resource)
            for out_res in g_server.outputs {
                if wls.resource_get_client(out_res) == surf_client {
                    wls.surface_send_enter(resource, out_res)
                    break
                }
            }
            // Window-Rules (Regex auf app_id, Fallback Titel) + Dialog-Heuristik:
            // Fenster mit Parent (Dialoge) oder fester Größe (min==max) werden
            // nie getilt — sie bleiben klein, zentriert und damit 1:1 scharf.
            class := len(tl.app_id) > 0 ? tl.app_id : tl.title
            wr := config_match_window_rule(class)
            fixed_size := tl.min_w > 0 && tl.min_w == tl.max_w &&
                          tl.min_h > 0 && tl.min_h == tl.max_h
            is_dialog := tl.parent != nil || fixed_size
            if (wr != nil && wr.floating) || is_dialog {
                tl.floating = true
                tree_remove(tl)
                // Wunschgröße: feste Größe > window_geometry > Buffer > 800x600
                w, h := i32(800), i32(600)
                if fixed_size {
                    w = tl.min_w; h = tl.min_h
                } else if surface.xdg.has_win_geom && surface.xdg.win_geom[2] > 0 {
                    w = surface.xdg.win_geom[2]; h = surface.xdg.win_geom[3]
                } else if surface.current_buffer != nil {
                    if shm := wls.shm_buffer_get(surface.current_buffer); shm != nil {
                        w = wls.shm_buffer_get_width(shm)
                        h = wls.shm_buffer_get_height(shm)
                    }
                }
                cw, ch := canvas_size()
                tl.float_geom = {(i32(cw) - w) / 2, (i32(ch) - h) / 2, w, h}
                fmt.printfln("[xdg] %q → FLOAT (%s, %dx%d)",
                    class, is_dialog ? "dialog/fixed-size" : "window-rule", w, h)
            }
            layout_toplevels()                 // Neu-Layout aller Fenster
            input_focus_toplevel(tl)          // neu gemapptes Fenster fokussieren
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
            //  • xdg-Toplevel/Popup → composite_all (alle Fenster neu zeichnen)
            //  • nackte Surface (keine Rolle) → direkter Fullscreen-Blit (alte API)
            if surface.xdg != nil &&
               ((surface.xdg.toplevel != nil && surface.xdg.toplevel.mapped) ||
                (surface.xdg.popup != nil && surface.xdg.popup.mapped)) {
                composite_all()                       // liest selbst alle Buffer (begin/end access)
            } else if surface.sub != nil {
                composite_all()                       // Subsurface-Update → Parent neu zeichnen
            } else if surface.xdg == nil && surface.layer == nil && !surface.is_cursor {
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

    // 4) Frame-Callbacks: DRM → beim nächsten Page Flip, Nested → sofort.
    surface_flush_frames(surface)
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
    wls.seat_send_capabilities(resource, WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER)
}

seat_get_pointer :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    input_seat_get_pointer(client, id, wls.resource_get_version(resource))
}
seat_get_keyboard :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    input_seat_get_keyboard(client, id, wls.resource_get_version(resource))
}
seat_get_touch :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    t := wls.resource_create(client, &wls.touch_interface, 4, id)
    if t == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(t, &touch_impl, nil, nil)
}
pointer_set_cursor :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32, surface: ^wls.wl_resource, hx, hy: i32) {
    context = ctx
    // Cursor-Rolle vergeben: Die Surface darf nie als Fenster-Inhalt in den
    // Framebuffer geblittet werden (vorher lief sie durch den nested_present-
    // Pfad und übermalte die linke obere Ecke). Das Cursor-BILD selbst zeigt
    // im Nested-Modus der Host (left_ptr), im DRM-Modus backend_cursor.
    if surface != nil {
        if s := surface_get(surface); s != nil do s.is_cursor = true
    }
}

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

// Aktuelle Output-Daten (Mode) ermitteln.
output_current_mode :: proc() -> (ow, oh, refresh_mhz: i32) {
    ow, oh, refresh_mhz = 1920, 1080, 60000
    if g_backend_drm && g_drm_output != nil {
        ow = i32(g_drm_output.width)
        oh = i32(g_drm_output.height)
        refresh_mhz = i32(g_drm_output.refresh * 1000)
    } else if nested.win_w > 0 && nested.win_h > 0 {
        ow = i32(nested.win_w)
        oh = i32(nested.win_h)
    }
    return
}

output_send_state :: proc(resource: ^wls.wl_resource) {
    ow, oh, refresh_mhz := output_current_mode()
    // physical size 0x0 = unbekannt (virtueller Output) — vorher log 800x600 mm.
    wls.output_send_geometry(resource, 0, 0, 0, 0, 0, "rift", "virtual", 0)
    wls.output_send_mode(resource, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED, ow, oh, refresh_mhz)
    if wls.resource_get_version(resource) >= 2 {
        wls.resource_post_event(resource, wls.WL_OUTPUT_DONE)
    }
}

// Nach einem Resize der Canvas (Host-Fenster) allen Clients den neuen Mode melden.
output_broadcast_mode :: proc() {
    context = ctx
    for res in g_server.outputs {
        output_send_state(res)
    }
}

output_resource_destroy :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    for res, i in g_server.outputs {
        if res == resource { ordered_remove(&g_server.outputs, i); break }
    }
}

output_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[output] Client bindet wl_output (v", version, ")")
    resource := wls.resource_create(client, &wls.output_interface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &output_impl, nil, output_resource_destroy)
    append(&g_server.outputs, resource)
    output_send_state(resource)
}

output_impl: wls.wl_output_interface = { release = noop_req }

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-Window-Compositing — alle gemappten Toplevels ins Nested-Fenster.
//  Layout: horizontales Tiling (N Fenster → jedes bekommt 1/N der Breite).
//  Composite: Hintergrund löschen, dann jeden Toplevel (skaliert) blitten.
// ═══════════════════════════════════════════════════════════════════════════

// Größe der Compositing-Fläche (DRM-Mode bzw. Nested-Fenster).
canvas_size :: proc() -> (int, int) {
    ww: int = NESTED_W
    wh: int = NESTED_H
    if g_backend_drm {
        drm_get_output_size(&ww, &wh)
    } else {
        ww = int(nested.win_w)
        wh = int(nested.win_h)
        if ww <= 0 do ww = NESTED_W
        if wh <= 0 do wh = NESTED_H
    }
    return ww, wh
}

// Effektives Render-Rechteck eines Toplevels (Fullscreen > Floating > Tile).
toplevel_render_geom :: proc(tl: ^XdgToplevel) -> Rect {
    if tl.fullscreen {
        ww, wh := canvas_size()
        return {0, 0, i32(ww), i32(wh)}
    }
    return tl.floating ? tl.float_geom : tl.geom
}

layout_toplevels :: proc() {
    context = ctx
    ww, wh := canvas_size()
    // Nur geteilte Fenster layouten — Floating-Fenster behalten ihre float_geom.
    if g_server.active_ws != nil && g_server.active_ws.root != nil {
        layout_tree(g_server.active_ws.root, Rect{0, 0, i32(ww), i32(wh)})
    }
    for i in 0..<len(g_server.active_ws.toplevels) {
        tl := g_server.active_ws.toplevels[i]
        if tl.floating {
            fmt.printfln("  geom[%d] FLOAT %d,%d %dx%d", i, tl.float_geom[0], tl.float_geom[1], tl.float_geom[2], tl.float_geom[3])
        } else {
            fmt.printfln("  geom[%d] %d,%d %dx%d", i, tl.geom[0], tl.geom[1], tl.geom[2], tl.geom[3])
        }
    }
    // Configure-Pipeline: jedem Toplevel seine (neue) Größe mitteilen.
    // toplevel_send_configure sendet nur bei tatsächlicher Änderung und
    // gated auf ausstehende acks — hier pauschal aufzurufen ist billig.
    for tl in g_server.active_ws.toplevels {
        toplevel_send_configure(tl)
    }
    fmt.printfln("[layout] %d Fenster (canvas %dx%d)", len(g_server.active_ws.toplevels), ww, wh)
}

composite_all :: proc() {
    context = ctx
    // DRM: Steht noch ein Page Flip aus, NICHT zeichnen — pixels[back] ist der
    // gerade zum Scanout eingereichte Buffer; ein clear darauf blitzt sichtbar
    // als Hintergrundfarbe auf (Flackern bei jedem Client-Commit). Der
    // Flip-Handler holt das Rendering nach VBlank nach (needs_frame).
    if g_backend_drm && g_drm_output != nil && g_drm_output.page_flip_pending {
        g_drm_output.needs_frame = true
        return
    }
    // Hintergrund-Clear überspringen, wenn ein Fenster die ganze Canvas mit
    // Buffer-Inhalt deckt (33MB/Frame bei 4K) — der 1:1-Blit überschreibt dann
    // ohnehin jeden Pixel (kein Blending). Bedingung spiegelt exakt die
    // Blit-Geometrie unten (toplevel_render_geom + window_geometry-Offset).
    clear_needed := true
    {
        cww, cwh := canvas_size()
        for tl in g_server.active_ws.toplevels {
            if !tl.mapped do continue
            xs := tl.xdg_surface
            if xs == nil || xs.surface == nil || xs.surface.current_buffer == nil do continue
            g := toplevel_render_geom(tl)
            if !(g[0] <= 0 && g[1] <= 0 && g[0] + g[2] >= i32(cww) && g[1] + g[3] >= i32(cwh)) do continue
            shm := wls.shm_buffer_get(xs.surface.current_buffer)
            if shm == nil do continue
            sw := wls.shm_buffer_get_width(shm)
            sh := wls.shm_buffer_get_height(shm)
            wg := xs.has_win_geom ? xs.win_geom : Rect{0, 0, sw, sh}
            dst_x := g[0] - wg[0]
            dst_y := g[1] - wg[1]
            if dst_x <= 0 && dst_y <= 0 && dst_x + sw >= i32(cww) && dst_y + sh >= i32(cwh) {
                clear_needed = false
                break
            }
        }
    }
    if clear_needed {
        if g_backend_drm {
            drm_clear(g_config.bg_color)
        } else {
            nested_clear(g_config.bg_color)
        }
    }
    // Layer background(0)/bottom(1) unter den Fenstern
    composite_layer_range(0, 1)
    // Geteilte Fenster zuerst (unten), dann Floating/Fullscreen oben drauf.
    for pass in 0..<2 {
        for tl in g_server.active_ws.toplevels {
            on_top := tl.floating || tl.fullscreen
            if pass == 0 &&  on_top do continue   // Pass 0: nur geteilte
            if pass == 1 && !on_top do continue   // Pass 1: floating + fullscreen
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
            stride := wls.shm_buffer_get_stride(shm) / 4   // Bytes → Pixel
            g := toplevel_render_geom(tl)
            // 1:1-Blit statt Skalierung: die Window-Geometry-Box (Inhalt ohne
            // CSD-Schatten) landet auf dem Tile-Origin; Überstände (Schatten,
            // alter Buffer während des configure-Handshakes) werden weggeclippt.
            wg := xs.has_win_geom ? xs.win_geom : Rect{0, 0, sw, sh}
            dst_x := g[0] - wg[0]
            dst_y := g[1] - wg[1]
            if g_backend_drm {
                drm_blit_clipped(src, sw, sh, stride, dst_x, dst_y, g)
            } else {
                nested_blit_clipped(src, sw, sh, stride, dst_x, dst_y, g)
            }
            wls.shm_buffer_end_access(shm)
            composite_subsurfaces(surf, dst_x, dst_y, g)   // mpv/Firefox-Overlays
        }
    }
    // Pass 3: Popups über ihren Parents (Listen-Reihenfolge = unten→oben,
    // verschachtelte Menüs stapeln korrekt, da Kinder nach Parents appended werden).
    for p in g_server.popups {
        if !p.mapped do continue
        root := popup_root_toplevel(p)
        if root == nil || !root.mapped do continue
        on_ws := false
        for t in g_server.active_ws.toplevels {
            if t == root { on_ws = true; break }
        }
        if !on_ws do continue
        xs := p.xdg_surface
        if xs == nil || xs.surface == nil || xs.surface.current_buffer == nil do continue
        shm := wls.shm_buffer_get(xs.surface.current_buffer)
        if shm == nil do continue
        wls.shm_buffer_begin_access(shm)
        src := cast([^]u32)(wls.shm_buffer_get_data(shm))
        sw := wls.shm_buffer_get_width(shm)
        sh := wls.shm_buffer_get_height(shm)
        stride := wls.shm_buffer_get_stride(shm) / 4
        ax, ay := popup_abs_pos(p)
        wg := xs.has_win_geom ? xs.win_geom : Rect{0, 0, sw, sh}
        // Clip nur auf die Canvas (Blit clippt selbst auf Buffergrenzen) —
        // Popups dürfen über ihr Parent-Tile hinausragen.
        clip := Rect{0, 0, max(i32(1) << 24, 0), max(i32(1) << 24, 0)}
        if g_backend_drm {
            drm_blit_clipped(src, sw, sh, stride, ax - wg[0], ay - wg[1], clip)
        } else {
            nested_blit_clipped(src, sw, sh, stride, ax - wg[0], ay - wg[1], clip)
        }
        wls.shm_buffer_end_access(shm)
    }
    // Layer top(2)/overlay(3) über allen Fenstern (rofi & Co.)
    composite_layer_range(2, 3)
    if g_backend_drm {
        drm_commit()
    } else {
        nested_commit_window()
    }
}

// Toplevel aus der Liste + Baum entfernen (bei Destroy) + Neu-Layout/Composite.
toplevel_unmap :: proc(tl: ^XdgToplevel) {
    context = ctx
    tl.mapped = false   // idempotent: kann von surface- UND xdg-Teardown kommen
    popup_dismiss_for_toplevel(tl)   // offene Menüs des Fensters schließen
    for t, i in g_server.active_ws.toplevels {
        if t == tl {
            ordered_remove(&g_server.active_ws.toplevels, i)
            break
        }
    }
    tree_remove(tl)
    // Fokus-Pointer auf das verschwindende Fenster nilen (sonst dangling).
    if tl.xdg_surface != nil && g_server.ptr_focus == tl.xdg_surface.surface {
        g_server.ptr_focus = nil
    }
    if g_server.wm_tl == tl { g_server.wm_tl = nil; g_server.wm_mode = .None; g_server.wm_split = nil }
    if g_server.focused == tl {
        g_server.focused = nil
        // Fokus-Nachfolge: sonst ist die Tastatur tot, bis der Nutzer klickt.
        if len(g_server.active_ws.toplevels) > 0 {
            input_focus_toplevel(g_server.active_ws.toplevels[len(g_server.active_ws.toplevels)-1])
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

    // v5: rofi & Co. verlangen mindestens Seat v5 (wl_pointer.frame/axis_*-
    // Events — die senden wir längst; wl_seat.release ist als noop implementiert)
    if wls.global_create(server.display, &wls.seat_interface, 5, server, seat_bind) == nil {
        fmt.println("[init] wl_seat global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_seat global registriert (v4)")

    if wls.global_create(server.display, &wls.output_interface, 2, server, output_bind) == nil {
        fmt.println("[init] wl_output global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_output global registriert (v2)")

    if !register_subcompositor_global(server) do return false
    if !register_data_device_manager_global(server) do return false
    if !register_layer_shell_global(server) do return false
    return true
}