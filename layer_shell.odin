package main

import "core:fmt"
import "core:c"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  wlr-layer-shell — Overlay-Surfaces (Launcher wie rofi, Bars, Notifications)
//
//  Minimale Implementierung des zwlr_layer_shell_v1-Protokolls:
//    • get_layer_surface gibt einer wl_surface die Layer-Rolle
//    • Erster commit (ohne Buffer) → configure(serial, w, h)
//    • Client ackt, attacht Buffer, commit → gemappt
//    • Positionierung über anchor/margin; unverankerte Achse = zentriert
//    • Layer background/bottom unter den Fenstern, top/overlay darüber
//    • keyboard_interactivity != none → Layer-Surface bekommt Tastaturfokus
//      (exklusiv, solange gemappt — genau was Launcher wie rofi erwarten)
//
//  Nicht implementiert: exclusive_zone (Platz-Reservierung für Bars),
//  Popups, mehrere Outputs.
// ═══════════════════════════════════════════════════════════════════════════

LAYER_ANCHOR_TOP    :: u32(1)
LAYER_ANCHOR_BOTTOM :: u32(2)
LAYER_ANCHOR_LEFT   :: u32(4)
LAYER_ANCHOR_RIGHT  :: u32(8)

LayerSurface :: struct {
    resource:   ^wls.wl_resource,   // zwlr_layer_surface_v1
    surface:    ^Surface,           // die wl_surface mit Layer-Rolle
    layer:      u32,                // 0=background 1=bottom 2=top 3=overlay
    desired_w:  u32,                // vom Client via set_size (0 = Compositor wählt)
    desired_h:  u32,
    anchor:     u32,
    margin_t, margin_r, margin_b, margin_l: i32,
    kb_mode:    u32,                // keyboard_interactivity (0=none 1=exclusive 2=on_demand)
    configured: bool,               // configure-Event geschickt
    mapped:     bool,
    geom:       Rect,               // berechnete Position/Größe auf dem Output
}

g_layer_surfaces: [dynamic]^LayerSurface
g_layer_kb_focus: ^LayerSurface = nil   // Layer-Surface mit exklusivem Tastaturfokus

// ─── Output-Größe (DRM oder Nested) ─────────────────────────────────────
layer_output_size :: proc() -> (i32, i32) {
    if g_backend_drm && g_drm_output != nil {
        return i32(g_drm_output.width), i32(g_drm_output.height)
    }
    w := i32(nested.win_w); if w <= 0 do w = NESTED_W
    h := i32(nested.win_h); if h <= 0 do h = NESTED_H
    return w, h
}

// ═══════════════════════════════════════════════════════════════════════════
//  zwlr_layer_shell_v1
// ═══════════════════════════════════════════════════════════════════════════

layer_shell_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    fmt.println("[layer] Client bindet zwlr_layer_shell_v1 (v", version, ")")
    resource := wls.resource_create(client, &wls.zwlr_layer_shell_iface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &layer_shell_impl, data, nil)
}

layer_shell_get_layer_surface :: proc "c" (
    client: ^wls.wl_client, resource: ^wls.wl_resource,
    id: u32, surface_res: ^wls.wl_resource, output: ^wls.wl_resource,
    layer: u32, namespace: cstring,
) {
    context = ctx
    surf := surface_get(surface_res)
    fmt.printfln("[layer] get_layer_surface: layer={} namespace={}", layer, string(namespace))

    ls := new(LayerSurface)
    ls.surface = surf
    ls.layer = layer

    ls_res := wls.resource_create(client, &wls.zwlr_layer_surface_iface,
        wls.resource_get_version(resource), id)
    if ls_res == nil {
        free(ls, context.allocator)
        wls.client_post_no_memory(client)
        return
    }
    ls.resource = ls_res
    surf.layer = ls
    wls.resource_set_implementation(ls_res, &layer_surface_impl, ls, layer_surface_destroy_resource)
    append(&g_layer_surfaces, ls)
}

layer_shell_impl: wls.zwlr_layer_shell_v1_interface = {
    get_layer_surface = layer_shell_get_layer_surface,
    destroy           = proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
        wls.resource_destroy(resource)
    },
}

// ═══════════════════════════════════════════════════════════════════════════
//  zwlr_layer_surface_v1
// ═══════════════════════════════════════════════════════════════════════════

layer_surface_get :: proc "contextless" (resource: ^wls.wl_resource) -> ^LayerSurface {
    return (^LayerSurface)(wls.resource_get_user_data(resource))
}

ls_set_size :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, width, height: u32) {
    ls := layer_surface_get(resource)
    ls.desired_w = width
    ls.desired_h = height
}
ls_set_anchor :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, anchor: u32) {
    layer_surface_get(resource).anchor = anchor
}
ls_set_exclusive_zone :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, zone: i32) {
    // Platz-Reservierung (Bars) — für Launcher nicht nötig, ignoriert.
}
ls_set_margin :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, top, right, bottom, left: i32) {
    ls := layer_surface_get(resource)
    ls.margin_t = top; ls.margin_r = right; ls.margin_b = bottom; ls.margin_l = left
}
ls_set_keyboard_interactivity :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, ki: u32) {
    layer_surface_get(resource).kb_mode = ki
}
ls_get_popup :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, popup: ^wls.wl_resource) {
    // Popups über Layer-Surfaces: nicht unterstützt (rofi drun braucht keine).
}
ls_ack_configure :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32) {}
ls_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
ls_set_layer :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, layer: u32) {
    layer_surface_get(resource).layer = layer
}
ls_set_exclusive_edge :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, edge: u32) {}

layer_surface_impl: wls.zwlr_layer_surface_v1_interface = {
    set_size                   = ls_set_size,
    set_anchor                 = ls_set_anchor,
    set_exclusive_zone         = ls_set_exclusive_zone,
    set_margin                 = ls_set_margin,
    set_keyboard_interactivity = ls_set_keyboard_interactivity,
    get_popup                  = ls_get_popup,
    ack_configure              = ls_ack_configure,
    destroy                    = ls_destroy,
    set_layer                  = ls_set_layer,
    set_exclusive_edge         = ls_set_exclusive_edge,
}

// Resource zerstört (Client-Destroy oder Disconnect) → unmappen + freigeben.
layer_surface_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    ls := layer_surface_get(resource)
    if ls == nil do return
    was_mapped := ls.mapped
    layer_keyboard_unfocus(ls)
    if ls.surface != nil {
        if g_server.ptr_focus == ls.surface do g_server.ptr_focus = nil
        ls.surface.layer = nil
    }
    for l, i in g_layer_surfaces {
        if l == ls { ordered_remove(&g_layer_surfaces, i); break }
    }
    free(ls, context.allocator)
    fmt.println("[layer] Layer-Surface zerstört")
    if was_mapped do composite_all()
}

// ═══════════════════════════════════════════════════════════════════════════
//  Commit-Hook (aus surface_commit) — configure/map/unmap-Lebenszyklus
// ═══════════════════════════════════════════════════════════════════════════

layer_surface_handle_commit :: proc(surf: ^Surface) {
    context = ctx
    ls := surf.layer
    if ls == nil do return

    // Erster commit (Client hat Wünsche gesetzt) → configure antworten.
    if !ls.configured {
        ow, oh := layer_output_size()
        w := ls.desired_w
        h := ls.desired_h
        // 0 = Compositor wählt: bei beidseitiger Verankerung Output minus
        // Margins, sonst voller Output.
        if w == 0 {
            w = u32(max(1, ow - ls.margin_l - ls.margin_r))
        }
        if h == 0 {
            h = u32(max(1, oh - ls.margin_t - ls.margin_b))
        }
        serial := wls.display_next_serial(g_server.display)
        wls.zwlr_layer_surface_send_configure(ls.resource, serial, w, h)
        ls.configured = true
        fmt.printfln("[layer] configure geschickt: {}x{}", w, h)
        return
    }

    if surf.current_buffer != nil {
        layer_surface_compute_geom(ls)
        if !ls.mapped {
            ls.mapped = true
            fmt.printfln("[layer] GEMAPPT: {},{} {}x{} (layer {})",
                ls.geom[0], ls.geom[1], ls.geom[2], ls.geom[3], ls.layer)
            if ls.kb_mode != 0 do layer_keyboard_focus(ls)
        }
        composite_all()
    } else if ls.mapped {
        // Buffer detacht → unmap
        ls.mapped = false
        layer_keyboard_unfocus(ls)
        if g_server.ptr_focus == ls.surface do g_server.ptr_focus = nil
        fmt.println("[layer] entmappt (Buffer detacht)")
        composite_all()
    }
}

// ─── Pointer-Hit-Testing ─────────────────────────────────────────────────────
// Gemappte Layer-Surface im Layer-Bereich [lo,hi] unter (x,y); liefert die
// wl_surface (für den vereinheitlichten Pointer-Fokus) + surface-lokale Koords.
// Rückwärts: zuletzt gemappte Surface liegt oben.
layer_surface_at :: proc(x, y: f64, lo, hi: u32, out_sx, out_sy: ^f64) -> ^Surface {
    #reverse for ls in g_layer_surfaces {
        if !ls.mapped || ls.layer < lo || ls.layer > hi do continue
        if ls.surface == nil || ls.surface.resource == nil do continue
        g := ls.geom
        if x >= f64(g[0]) && x < f64(g[0] + g[2]) && y >= f64(g[1]) && y < f64(g[1] + g[3]) {
            out_sx^ = x - f64(g[0])
            out_sy^ = y - f64(g[1])
            return ls.surface
        }
    }
    return nil
}

// Position aus Anchor/Margins + Buffer-Größe berechnen.
layer_surface_compute_geom :: proc(ls: ^LayerSurface) {
    if ls.surface == nil || ls.surface.current_buffer == nil do return
    shm := wls.shm_buffer_get(ls.surface.current_buffer)
    if shm == nil do return
    w := wls.shm_buffer_get_width(shm)
    h := wls.shm_buffer_get_height(shm)
    ow, oh := layer_output_size()

    x: i32
    anchored_l := (ls.anchor & LAYER_ANCHOR_LEFT) != 0
    anchored_r := (ls.anchor & LAYER_ANCHOR_RIGHT) != 0
    if anchored_l && !anchored_r {
        x = ls.margin_l
    } else if anchored_r && !anchored_l {
        x = ow - w - ls.margin_r
    } else {
        x = (ow - w) / 2
    }

    y: i32
    anchored_t := (ls.anchor & LAYER_ANCHOR_TOP) != 0
    anchored_b := (ls.anchor & LAYER_ANCHOR_BOTTOM) != 0
    if anchored_t && !anchored_b {
        y = ls.margin_t
    } else if anchored_b && !anchored_t {
        y = oh - h - ls.margin_b
    } else {
        y = (oh - h) / 2
    }

    ls.geom = {x, y, w, h}
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tastaturfokus — Layer-Surface mit keyboard_interactivity bekommt Keys
// ═══════════════════════════════════════════════════════════════════════════

// wl_keyboard-Resource des Layer-Surface-Clients finden.
layer_keyboard :: proc(ls: ^LayerSurface) -> ^wls.wl_resource {
    if ls == nil || ls.resource == nil do return nil
    cl := wls.resource_get_client(ls.resource)
    for kb in g_server.keyboards {
        if wls.resource_get_client(kb) == cl do return kb
    }
    return nil
}

layer_keyboard_focus :: proc(ls: ^LayerSurface) {
    context = ctx
    if ls.surface == nil || ls.surface.resource == nil do return
    kb := layer_keyboard(ls)
    if kb == nil {
        fmt.println("[layer] WARNUNG: Layer-Client hat kein wl_keyboard gebunden")
        return
    }
    serial := wls.display_next_serial(g_server.display)
    // Fokussiertes Fenster verliert die Tastatur (leave)
    old_kb := focused_keyboard()
    old_surf := focused_surface_resource()
    if old_kb != nil && old_surf != nil {
        wls.resource_post_event(old_kb, wls.WL_KEYBOARD_LEAVE, serial, old_surf)
    }
    g_layer_kb_focus = ls
    empty: wls.wl_array = {}
    wls.resource_post_event(kb, wls.WL_KEYBOARD_ENTER, serial, ls.surface.resource, &empty)
    // Aktuellen Modifier-Stand mitteilen (Client startet sonst mit unbekanntem Zustand)
    wls.resource_post_event(kb, wls.WL_KEYBOARD_MODIFIERS, serial,
        g_server.mods_depressed, u32(0), u32(0), u32(0))
    fmt.println("[layer] Tastaturfokus → Layer-Surface")
}

layer_keyboard_unfocus :: proc(ls: ^LayerSurface) {
    context = ctx
    if g_layer_kb_focus != ls do return
    g_layer_kb_focus = nil
    serial := wls.display_next_serial(g_server.display)
    kb := layer_keyboard(ls)
    if kb != nil && ls.surface != nil && ls.surface.resource != nil {
        wls.resource_post_event(kb, wls.WL_KEYBOARD_LEAVE, serial, ls.surface.resource)
    }
    // Tastatur zurück ans fokussierte Fenster
    fkb := focused_keyboard()
    fsurf := focused_surface_resource()
    if fkb != nil && fsurf != nil {
        empty: wls.wl_array = {}
        wls.resource_post_event(fkb, wls.WL_KEYBOARD_ENTER, serial, fsurf, &empty)
    }
    fmt.println("[layer] Tastaturfokus ← zurück ans Fenster")
}

// ═══════════════════════════════════════════════════════════════════════════
//  Compositing — Layer-Surfaces eines Layer-Bereichs blitten
//  (background/bottom vor den Fenstern, top/overlay danach)
// ═══════════════════════════════════════════════════════════════════════════

composite_layer_range :: proc(lo, hi: u32) {
    context = ctx
    for ls in g_layer_surfaces {
        if !ls.mapped || ls.layer < lo || ls.layer > hi do continue
        surf := ls.surface
        if surf == nil || surf.current_buffer == nil do continue
        shm := wls.shm_buffer_get(surf.current_buffer)
        if shm == nil do continue
        wls.shm_buffer_begin_access(shm)
        src := cast([^]u32)(wls.shm_buffer_get_data(shm))
        sw := wls.shm_buffer_get_width(shm)
        sh := wls.shm_buffer_get_height(shm)
        stride := wls.shm_buffer_get_stride(shm) / 4   // Bytes → Pixel
        g := ls.geom
        if g_backend_drm {
            drm_blit_clipped(src, sw, sh, stride, g[0], g[1], g)
        } else {
            nested_blit_clipped(src, sw, sh, stride, g[0], g[1], g)
        }
        wls.shm_buffer_end_access(shm)
    }
}

// ─── Global registrieren (aus main via register_globals) ────────────────
register_layer_shell_global :: proc(server: ^Server) -> bool {
    if wls.global_create(server.display, &wls.zwlr_layer_shell_iface, 4, server, layer_shell_bind) == nil {
        fmt.println("[init] zwlr_layer_shell_v1 global fehlgeschlagen")
        return false
    }
    fmt.println("[init] zwlr_layer_shell_v1 global registriert (v4)")
    return true
}
