package popup_client

import wl "../../wlclient"
import xdg "../../wlclient/xdg"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Test-Client — Popup-Handshake.
//  Mappt ein Toplevel (grau), öffnet dann ein xdg_popup (orange) mit
//  Positioner (anchor bottom_left auf einem anchor_rect) und loggt das
//  xdg_popup.configure. Beweist: Positioner-Auswertung, Popup-configure,
//  Map + Rendering über dem Parent.
// ═══════════════════════════════════════════════════════════════════════════

compositor  : ^wl.compositor
shm         : ^wl.shm
wm_base     : ^xdg.wm_base
surface     : ^wl.surface
xdg_surface : ^xdg.surface
toplevel    : ^xdg.toplevel
popup_surf  : ^wl.surface
popup_xdg   : ^xdg.surface
popup       : ^xdg.popup
g_ctx       : runtime.Context
tl_configured: bool
popup_opened : bool
popup_confs  : int
done         : bool

XRGB8888 :: wl.shm_format.xrgb8888
TL_W :: 400
TL_H :: 300
POP_W :: 150
POP_H :: 100

commit_color :: proc(s: ^wl.surface, w, h: int, color: u32) {
    context = g_ctx
    size := w * h * 4
    nm := fmt.caprintf("/popupc_%v", uintptr(s))
    fd := posix.shm_open(nm, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
    defer posix.close(fd)
    if fd >= 0 do posix.shm_unlink(nm)
    posix.ftruncate(auto_cast fd, auto_cast size)
    raw, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
    if err != .NONE do return
    px := cast([^]u32)raw
    for i in 0..<w*h do px[i] = color
    linux.munmap(raw, uint(size))
    pool := wl.shm_create_pool(shm, auto_cast fd, size)
    buf := wl.shm_pool_create_buffer(pool, 0, w, h, w*4, XRGB8888)
    wl.shm_pool_destroy(pool)
    wl.surface_attach(s, buf, 0, 0)
    wl.surface_damage(s, 0, 0, w, h)
    wl.surface_commit(s)
}

registry_global :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint, interface: cstring, version: uint) {
    context = g_ctx
    iface := string(interface)
    if iface == "wl_compositor" {
        compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
    } else if iface == "wl_shm" {
        shm = cast(^wl.shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
    } else if iface == "xdg_wm_base" {
        wm_base = cast(^xdg.wm_base)wl.registry_bind(registry, name, &xdg.wm_base_interface, 1)
    }
}
registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}
reg_listener: wl.registry_listener = { global = registry_global, global_remove = registry_global_remove }

wm_ping :: proc "c" (data: rawptr, wm: ^xdg.wm_base, serial: uint) {
    xdg.wm_base_pong(wm, serial)
}
wm_listener: xdg.wm_base_listener = { ping = wm_ping }

// Toplevel-xdg_surface: configure ack'en + zeichnen.
tl_xsurf_configure :: proc "c" (data: rawptr, xs: ^xdg.surface, serial: uint) {
    context = g_ctx
    xdg.surface_ack_configure(xs, serial)
    if !tl_configured {
        tl_configured = true
        commit_color(surface, TL_W, TL_H, 0xFF505050)   // grau
        fmt.println("[popupc] toplevel gemappt")
    }
}
tl_xsurf_listener: xdg.surface_listener = { configure = tl_xsurf_configure }

tl_configure :: proc "c" (data: rawptr, t: ^xdg.toplevel, w, h: int, states: wl.array) {}
tl_close :: proc "c" (data: rawptr, t: ^xdg.toplevel) {}
tl_listener: xdg.toplevel_listener = { configure = tl_configure, close = tl_close }

// Popup-xdg_surface: configure ack'en + zeichnen.
pop_xsurf_configure :: proc "c" (data: rawptr, xs: ^xdg.surface, serial: uint) {
    context = g_ctx
    xdg.surface_ack_configure(xs, serial)
    commit_color(popup_surf, POP_W, POP_H, 0xFFF97316)   // orange
    fmt.println("[popupc] popup committed")
}
pop_xsurf_listener: xdg.surface_listener = { configure = pop_xsurf_configure }

pop_configure :: proc "c" (data: rawptr, p: ^xdg.popup, x, y, w, h: int) {
    context = g_ctx
    popup_confs += 1
    fmt.printfln("[popupc] ★ POPUP CONFIGURE x=%d y=%d %dx%d", x, y, w, h)
}
pop_done :: proc "c" (data: rawptr, p: ^xdg.popup) {
    context = g_ctx
    fmt.println("[popupc] ★ POPUP DONE (dismissed)")
    done = true
}
pop_repositioned :: proc "c" (data: rawptr, p: ^xdg.popup, token: uint) {}
pop_listener: xdg.popup_listener = { configure = pop_configure, popup_done = pop_done, repositioned = pop_repositioned }

open_popup :: proc() {
    context = g_ctx
    // Positioner: 150x100, verankert an der Unterkante eines 10x10-Rects bei
    // (50,50), wächst nach unten-rechts → erwartete Position (60,60).
    pos := xdg.wm_base_create_positioner(wm_base)
    xdg.positioner_set_size(pos, POP_W, POP_H)
    xdg.positioner_set_anchor_rect(pos, 50, 50, 10, 10)
    xdg.positioner_set_anchor(pos, .bottom_right)
    xdg.positioner_set_gravity(pos, .bottom_right)
    popup_surf = wl.compositor_create_surface(compositor)
    popup_xdg = xdg.wm_base_get_xdg_surface(wm_base, popup_surf)
    xdg.surface_add_listener(popup_xdg, &pop_xsurf_listener, nil)
    popup = xdg.surface_get_popup(popup_xdg, xdg_surface, pos)
    xdg.popup_add_listener(popup, &pop_listener, nil)
    xdg.positioner_destroy(pos)   // Client darf den Positioner sofort zerstören
    wl.surface_commit(popup_surf)
    popup_opened = true
    fmt.println("[popupc] popup angefordert (erwartet: x=60 y=60 150x100)")
}

main :: proc() {
    g_ctx = context
    d := wl.display_connect(nil)
    if d == nil { fmt.println("[popupc] connect fail"); return }
    reg := wl.display_get_registry(d)
    wl.registry_add_listener(reg, &reg_listener, nil)
    wl.display_roundtrip(d)
    if compositor == nil || shm == nil || wm_base == nil { fmt.println("[popupc] globals fehlen"); return }

    surface = wl.compositor_create_surface(compositor)
    xdg.wm_base_add_listener(wm_base, &wm_listener, nil)
    xdg_surface = xdg.wm_base_get_xdg_surface(wm_base, surface)
    xdg.surface_add_listener(xdg_surface, &tl_xsurf_listener, nil)
    toplevel = xdg.surface_get_toplevel(xdg_surface)
    xdg.toplevel_add_listener(toplevel, &tl_listener, nil)
    xdg.toplevel_set_title(toplevel, "popup test")
    wl.surface_commit(surface)

    iterations := 0
    for wl.display_dispatch(d) != 0 && !done {
        iterations += 1
        if tl_configured && !popup_opened {
            open_popup()
            wl.display_flush(d)
        }
        if iterations > 200 do break
    }
    fmt.printfln("[popupc] fertig (popup_confs=%d)", popup_confs)
    wl.display_disconnect(d)
}
