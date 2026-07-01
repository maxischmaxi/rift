package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  wl_data_device_manager — Zwischenablage (Selection) zwischen rift-Clients.
//
//  Ablauf (Copy/Paste):
//   1. Quell-Client: create_data_source → offer(mime)* → set_selection(source)
//   2. rift merkt die Source und schickt dem Keyboard-Fokus-Client ein
//      data_offer (+ offer(mime)* + selection(offer)).
//   3. Ziel-Client: data_offer.receive(mime, fd) → rift reicht das als
//      data_source.send(mime, fd) an die Quelle weiter; die schreibt in den fd.
//
//  Drag & Drop (start_drag) ist bewusst NICHT implementiert (v1: Clipboard).
// ═══════════════════════════════════════════════════════════════════════════

DataSource :: struct {
    resource: ^wls.wl_resource,
    mimes: [dynamic]string,
}

// Aktuelle Selection (nil = leer).
g_selection: ^DataSource

data_source_get :: proc "c" (resource: ^wls.wl_resource) -> ^DataSource {
    return (^DataSource)(wls.resource_get_user_data(resource))
}

// ─── wl_data_source ──────────────────────────────────────────────────────
data_source_offer :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, mime_type: cstring) {
    context = ctx
    src := data_source_get(resource)
    if src == nil do return
    append(&src.mimes, strings.clone(string(mime_type)))
}
data_source_destroy_req :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
data_source_destroy_resource :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    src := data_source_get(resource)
    if src == nil do return
    if g_selection == src {
        g_selection = nil
        // Fokus-Client informieren: Selection ist weg.
        data_device_send_selection_to(focused_client(), nil)
    }
    for m in src.mimes do delete(m)
    delete(src.mimes)
    free(src, ctx.allocator)
}
data_source_set_actions :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, dnd_actions: u32) {}

data_source_impl: wls.wl_data_source_interface = {
    offer       = data_source_offer,
    destroy     = data_source_destroy_req,
    set_actions = data_source_set_actions,
}

// ─── wl_data_offer ───────────────────────────────────────────────────────
// user_data der Offer-Resource = die DataSource, aus der sie gespeist wird.
data_offer_accept :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, serial: u32, mime_type: cstring) {}
data_offer_receive :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, mime_type: cstring, fd: i32) {
    context = ctx
    src := data_source_get(resource)   // gleiche user_data-Konvention
    if src != nil && src.resource != nil {
        wls.resource_post_event(src.resource, wls.WL_DATA_SOURCE_SEND, mime_type, c.int(fd))
    }
    // libwayland dupliziert den fd beim Marshalling — unser Ende immer schließen.
    posix.close(posix.FD(fd))
}
data_offer_destroy :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}
data_offer_finish :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {}
data_offer_set_actions :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, dnd_actions: u32, preferred_action: u32) {}

data_offer_impl: wls.wl_data_offer_interface = {
    accept      = data_offer_accept,
    receive     = data_offer_receive,
    destroy     = data_offer_destroy,
    finish      = data_offer_finish,
    set_actions = data_offer_set_actions,
}

// ─── wl_data_device ──────────────────────────────────────────────────────
data_device_start_drag :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, source, origin, icon: ^wls.wl_resource, serial: u32) {
    context = ctx
    fmt.println("[data] start_drag (DnD nicht implementiert — ignoriert)")
}
data_device_set_selection :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, source: ^wls.wl_resource, serial: u32) {
    context = ctx
    old := g_selection
    g_selection = source != nil ? data_source_get(source) : nil
    // Alte Source canceln (Protokoll: sie darf ihre Daten freigeben).
    if old != nil && old != g_selection && old.resource != nil {
        wls.resource_post_event(old.resource, wls.WL_DATA_SOURCE_CANCELLED)
    }
    fmt.printfln("[data] set_selection (%d mime-Typen)", g_selection != nil ? len(g_selection.mimes) : 0)
    // Dem aktuellen Fokus-Client sofort anbieten.
    data_device_send_selection_to(focused_client(), g_selection)
}
data_device_release :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource) {
    wls.resource_destroy(resource)
}

data_device_impl: wls.wl_data_device_interface = {
    start_drag    = data_device_start_drag,
    set_selection = data_device_set_selection,
    release       = data_device_release,
}

data_device_resource_destroy :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    for d, i in g_data_devices {
        if d == resource { ordered_remove(&g_data_devices, i); break }
    }
}

// Alle gebundenen wl_data_device-Resources (eine pro Client, der sie holt).
g_data_devices: [dynamic]^wls.wl_resource

// Client des fokussierten Toplevels (nil wenn kein Fokus).
focused_client :: proc() -> ^wls.wl_client {
    tl := g_server.focused
    if tl == nil || tl.resource == nil do return nil
    return wls.resource_get_client(tl.resource)
}

// Selection an einen bestimmten Client melden (offer bauen oder nil senden).
data_device_send_selection_to :: proc(client: ^wls.wl_client, src: ^DataSource) {
    context = ctx
    if client == nil do return
    // data_device-Resource dieses Clients suchen.
    device: ^wls.wl_resource
    for d in g_data_devices {
        if wls.resource_get_client(d) == client { device = d; break }
    }
    if device == nil do return
    if src == nil {
        wls.resource_post_event(device, wls.WL_DATA_DEVICE_SELECTION, nil)
        return
    }
    // Neues data_offer beim Ziel-Client anlegen (Server-seitige new_id via id=0).
    offer := wls.resource_create(client, &wls.data_offer_interface, wls.resource_get_version(device), 0)
    if offer == nil do return
    wls.resource_set_implementation(offer, &data_offer_impl, src, nil)
    wls.resource_post_event(device, wls.WL_DATA_DEVICE_DATA_OFFER, offer)
    for m in src.mimes {
        cm := strings.clone_to_cstring(m)
        wls.resource_post_event(offer, wls.WL_DATA_OFFER_OFFER, cm)
        delete(cm)
    }
    wls.resource_post_event(device, wls.WL_DATA_DEVICE_SELECTION, offer)
}

// Beim Fokuswechsel (aus input_focus_toplevel): neuem Fokus-Client anbieten.
data_device_offer_selection_to_focus :: proc() {
    context = ctx
    data_device_send_selection_to(focused_client(), g_selection)
}

// ─── wl_data_device_manager ──────────────────────────────────────────────
ddm_create_data_source :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32) {
    context = ctx
    res := wls.resource_create(client, &wls.data_source_interface, wls.resource_get_version(resource), id)
    if res == nil { wls.client_post_no_memory(client); return }
    src := new(DataSource)
    src.resource = res
    wls.resource_set_implementation(res, &data_source_impl, src, data_source_destroy_resource)
}
ddm_get_data_device :: proc "c" (client: ^wls.wl_client, resource: ^wls.wl_resource, id: u32, seat: ^wls.wl_resource) {
    context = ctx
    res := wls.resource_create(client, &wls.data_device_interface, wls.resource_get_version(resource), id)
    if res == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(res, &data_device_impl, nil, data_device_resource_destroy)
    append(&g_data_devices, res)
    // Falls schon eine Selection existiert, gleich anbieten (wl-paste direkt
    // nach dem Binden).
    if g_selection != nil && focused_client() == client {
        data_device_send_selection_to(client, g_selection)
    }
}

ddm_impl: wls.wl_data_device_manager_interface = {
    create_data_source = ddm_create_data_source,
    get_data_device    = ddm_get_data_device,
    release            = noop_req,
}

ddm_bind :: proc "c" (client: ^wls.wl_client, data: rawptr, version: u32, id: u32) {
    context = ctx
    resource := wls.resource_create(client, &wls.data_device_manager_interface, c.int(version), id)
    if resource == nil { wls.client_post_no_memory(client); return }
    wls.resource_set_implementation(resource, &ddm_impl, nil, nil)
}

register_data_device_manager_global :: proc(server: ^Server) -> bool {
    if wls.global_create(server.display, &wls.data_device_manager_interface, 3, server, ddm_bind) == nil {
        fmt.println("[init] wl_data_device_manager global fehlgeschlagen"); return false
    }
    fmt.println("[init] wl_data_device_manager global registriert (v3)")
    return true
}
