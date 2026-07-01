package main

import "core:fmt"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  wl_subcompositor / wl_subsurface — Subsurfaces (Firefox, mpv, Video-Overlays).
//
//  Vereinfachungen (v1):
//   • set_sync/set_desync: immer desync — Subsurface-Commits werden sofort
//     sichtbar (korrekt genug für Video-Player; echte sync-Semantik braucht
//     gestaffelte Commit-Queues).
//   • place_above/place_below: Reihenfolge = Anlage-Reihenfolge.
//   • Position wird direkt übernommen (statt double-buffered bis Parent-Commit).
// ═══════════════════════════════════════════════════════════════════════════

Subsurface :: struct {
    surface: ^Surface,           // die Kind-Surface (trägt die Rolle)
    parent:  ^Surface,
    resource: ^wls.wl_resource,
    x, y: i32,                   // Position relativ zum Parent
}

subsurface_get :: proc "c" (resource: ^wls.wl_resource) -> ^Subsurface {
    return (^Subsurface)(wls.resource_get_user_data(resource))
}

// Aus der children-Liste des Parents austragen + Rolle lösen.
subsurface_detach :: proc(sub: ^Subsurface) {
    context = ctx
    if sub.parent != nil {
        for s, i in sub.parent.children {
            if s == sub { ordered_remove(&sub.parent.children, i); break }
        }
        sub.parent = nil
    }
    if sub.surface != nil {
        sub.surface.sub = nil
        sub.surface = nil
    }
}

subsurface_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    sub := subsurface_get(resource)
    if sub == nil do return
    subsurface_detach(sub)
    free(sub, ctx.allocator)
    composite_all()
}

subsurface_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
subsurface_set_position :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, x, y: i32) {
    context = ctx
    sub := subsurface_get(resource)
    if sub == nil do return
    sub.x = x
    sub.y = y
}
subsurface_place_above :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, sibling: ^wls.wl_resource) {}
subsurface_place_below :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, sibling: ^wls.wl_resource) {}

subsurface_impl: wls.wl_subsurface_interface = {
    destroy      = subsurface_destroy,
    set_position = subsurface_set_position,
    place_above  = subsurface_place_above,
    place_below  = subsurface_place_below,
    set_sync     = noop_req,
    set_desync   = noop_req,
}

// ─── wl_subcompositor ────────────────────────────────────────────────────
subcompositor_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}

subcompositor_get_subsurface :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32, surface_res: ^wls.wl_resource, parent_res: ^wls.wl_resource) {
    context = ctx
    sub_res := wls.resource_create(client, &wls.subsurface_interface, 1, id)
    if sub_res == nil { wls.client_post_no_memory(client); return }
    surface := surface_get(surface_res)
    parent := surface_get(parent_res)
    if surface == nil || parent == nil || surface == parent {
        wls.resource_set_implementation(sub_res, &subsurface_impl, nil, nil)
        return
    }
    sub := new(Subsurface)
    sub.surface = surface
    sub.parent = parent
    sub.resource = sub_res
    surface.sub = sub
    append(&parent.children, sub)
    wls.resource_set_implementation(sub_res, &subsurface_impl, sub, subsurface_destroy_resource)
    fmt.println("[subsurface] get_subsurface → Kind angelegt")
}

subcompositor_impl: wls.wl_subcompositor_interface = {
    destroy        = subcompositor_destroy,
    get_subsurface = subcompositor_get_subsurface,
}

subcompositor_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    resource := wls.resource_create(client, &wls.subcompositor_interface, 1, id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &subcompositor_impl, nil, nil)
}

register_subcompositor_global :: proc(server: ^Server) -> bool {
    if wls.global_create(server.display, &wls.subcompositor_interface, 1, server, subcompositor_bind) == nil {
        fmt.println("[init] wl_subcompositor global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_subcompositor global registriert (v1)")
    return true
}

// ─── Rendering: Subsurfaces eines Surface-Baums blitten ──────────────────
// base_x/base_y = absolute Canvas-Position der Parent-Surface (deren Buffer-
// Ursprung), clip = Clip-Rechteck des Fensters. Rekursiv für Enkel.
composite_subsurfaces :: proc(parent: ^Surface, base_x, base_y: i32, clip: Rect) {
    context = ctx
    for sub in parent.children {
        s := sub.surface
        if s == nil || s.current_buffer == nil do continue
        shm := wls.shm_buffer_get(s.current_buffer)
        if shm == nil do continue
        wls.shm_buffer_begin_access(shm)
        src := cast([^]u32)(wls.shm_buffer_get_data(shm))
        sw := wls.shm_buffer_get_width(shm)
        sh := wls.shm_buffer_get_height(shm)
        stride := wls.shm_buffer_get_stride(shm) / 4
        sx := base_x + sub.x
        sy := base_y + sub.y
        if g_backend_drm {
            drm_blit_clipped(src, sw, sh, stride, sx, sy, clip)
        } else {
            nested_blit_clipped(src, sw, sh, stride, sx, sy, clip)
        }
        wls.shm_buffer_end_access(shm)
        composite_subsurfaces(s, sx, sy, clip)
    }
}
