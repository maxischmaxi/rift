package main

import wl "./wlclient"
import xdg "./wlclient/xdg"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Nested-Backend — rift wird ZUSÄTZlich ein Wayland-CLIENT von Hyprland.
//
//  - Verbindet sich mit $WAYLAND_DISPLAY (Hyprland, wayland-1) — wie jede App.
//  - Öffnet ein xdg-toplevel-Fenster "rift (nested)".
//  - nested_present() blittet empfangene Client-Pixel in dieses Fenster.
//  - Der fd des Parent-Clients wird in den rift-Server-Event-Loop eingehängt,
//    sodass beide (Server für rift-Clients + Client für Hyprland) in einem
//    Loop laufen.
//
//  Sicherheit: rift ist hier NUR ein Client von Hyprland — kein DRM, kein
//  Input-Grab. Crasht rift, stirbt nur rift; Hyprland räumt das Fenster auf.
// ═══════════════════════════════════════════════════════════════════════════

NESTED_W :: 800
NESTED_H :: 600
XRGB8888 :: wl.shm_format.xrgb8888   // == 1 (Spezialwert, kein FourCC)

Nested :: struct {
    display:       ^wl.display,
    compositor:    ^wl.compositor,
    shm:           ^wl.shm,
    wm_base:       ^xdg.wm_base,
    surface:       ^wl.surface,     // das Fenster in Hyprland
    xdg_surface:   ^xdg.surface,
    toplevel:      ^xdg.toplevel,
    configured:    bool,
    // Fenster-Buffer (einmal angelegt, wiederverwendet)
    buffer:        ^wl.buffer,
    pixels:        [^]u32,          // mmap'd Fenster-Backing-Store
}

nested:     Nested
nested_ctx: runtime.Context

// ─── Parent-Registry: Globals abfangen ──────────────────────────────────
nested_registry_global :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint, interface: cstring, version: uint) {
    context = nested_ctx
    iface := string(interface)
    if iface == "wl_compositor" {
        nested.compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
    } else if iface == "wl_shm" {
        nested.shm = cast(^wl.shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
    } else if iface == "xdg_wm_base" {
        nested.wm_base = cast(^xdg.wm_base)wl.registry_bind(registry, name, &xdg.wm_base_interface, 1)
    }
}
nested_registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

nested_registry_listener: wl.registry_listener = {
    global = nested_registry_global,
    global_remove = nested_registry_global_remove,
}

// ─── xdg_wm_base: ping beantworten (sonst killt der Compositor uns) ────
nested_wm_base_ping :: proc "c" (data: rawptr, wm_base: ^xdg.wm_base, serial: uint) {
    context = nested_ctx
    xdg.wm_base_pong(wm_base, serial)
}
nested_wm_base_listener: xdg.wm_base_listener = { ping = nested_wm_base_ping }

// ─── xdg_surface configure: der Fenster-Handshake ──────────────────────
nested_surface_configure :: proc "c" (data: rawptr, xsurface: ^xdg.surface, serial: uint) {
    context = nested_ctx
    xdg.surface_ack_configure(xsurface, serial)
    if nested.buffer == nil {
        nested_create_buffer()
    }
    if nested.buffer != nil {
        wl.surface_attach(nested.surface, nested.buffer, 0, 0)
        wl.surface_damage(nested.surface, 0, 0, NESTED_W, NESTED_H)
        wl.surface_commit(nested.surface)
        nested.configured = true
        fmt.println("[nested] Fenster konfiguriert + erstes Bild committet")
    }
}
nested_surface_listener: xdg.surface_listener = { configure = nested_surface_configure }

// ─── Fenster-Buffer anlegen (einmal, feste 200x200) ────────────────────
nested_create_buffer :: proc() {
    context = nested_ctx
    size := NESTED_W * NESTED_H * 4
    name := fmt.caprintf("/rift_nested_%v", uintptr(nested.display))
    fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
    if fd < 0 { fmt.println("[nested] shm_open fehlgeschlagen"); return }
    posix.shm_unlink(name)
    if posix.ftruncate(auto_cast fd, auto_cast size) == .FAIL {
        fmt.println("[nested] ftruncate fehlgeschlagen"); return
    }
    data_raw, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
    if err != .NONE { fmt.println("[nested] mmap fehlgeschlagen"); return }
    nested.pixels = cast([^]u32)data_raw
    pool := wl.shm_create_pool(nested.shm, auto_cast fd, size)
    nested.buffer = wl.shm_pool_create_buffer(pool, 0, NESTED_W, NESTED_H, NESTED_W*4, XRGB8888)
    // Pool nicht zerstören — der Buffer referenziert ihn. Wird am Ende mitfreigegeben.
    fmt.println("[nested] Fenster-Buffer 800x600 angelegt")
}

// ─── Composite-Helfer für mehrere Toplevels ────────────────────────────
// nested_clear: Fenster-Buffer mit Farbe füllen (Hintergrund).
nested_clear :: proc(color: u32) {
    context = nested_ctx
    if nested.pixels == nil do return
    for i in 0..<NESTED_W*NESTED_H do nested.pixels[i] = color
}

// nested_blit_scaled: Quelle skaliert in Fenster-Buffer an (dx,dy,dw,dh) blitten.
// Nearest-Neighbor-Skalierung (einfach, reicht für den Anfang).
nested_blit_scaled :: proc(src: [^]u32, src_w, src_h: i32, dx, dy, dw, dh: i32) {
    context = nested_ctx
    if nested.pixels == nil || dw <= 0 || dh <= 0 || src_w <= 0 || src_h <= 0 do return
    for y in 0..<dh {
        sy := y * src_h / dh
        for x in 0..<dw {
            sx := x * src_w / dw
            nested.pixels[(dy+y)*NESTED_W + (dx+x)] = src[sy*src_w + sx]
        }
    }
}

// nested_commit_window: fertigen Fenster-Buffer an Hyprland schicken.
nested_commit_window :: proc() {
    context = nested_ctx
    if !nested.configured || nested.buffer == nil do return
    wl.surface_attach(nested.surface, nested.buffer, 0, 0)
    wl.surface_damage(nested.surface, 0, 0, NESTED_W, NESTED_H)
    wl.surface_commit(nested.surface)
    wl.display_flush(nested.display)
}

// ─── Present: empfangene Pixel ins Hyprland-Fenster blitten ─────────────
nested_present :: proc(src: [^]u32, w, h: i32) {
    context = nested_ctx
    if !nested.configured || nested.buffer == nil do return
    cw := w if w < NESTED_W else NESTED_W
    ch := h if h < NESTED_H else NESTED_H
    for y in 0..<ch {
        for x in 0..<cw {
            nested.pixels[y*NESTED_W + x] = src[y*w + x]
        }
    }
    wl.surface_attach(nested.surface, nested.buffer, 0, 0)
    wl.surface_damage(nested.surface, 0, 0, auto_cast cw, auto_cast ch)
    wl.surface_commit(nested.surface)
    wl.display_flush(nested.display)
}

// ─── fd-Callback: Parent-Client in den Server-Loop einklinken ──────────
nested_dispatch :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int {
    context = nested_ctx
    // fd ist lesbar → Hyprland hat Events. Lesen + dispatchen.
    wl.display_dispatch(nested.display)
    return 0
}

// ─── Initialisierung (aus main) ────────────────────────────────────────
nested_init :: proc() -> bool {
    nested_ctx = context
    nested.display = wl.display_connect(nil)   // → $WAYLAND_DISPLAY = Hyprland
    if nested.display == nil {
        fmt.println("[nested] Verbindung zu Hyprland fehlgeschlagen")
        return false
    }
    fmt.println("[nested] mit Hyprland verbunden (als Client)")

    registry := wl.display_get_registry(nested.display)
    wl.registry_add_listener(registry, &nested_registry_listener, nil)
    wl.display_roundtrip(nested.display)

    if nested.compositor == nil || nested.shm == nil || nested.wm_base == nil {
        fmt.println("[nested] Globals unvollständig (compositor/shm/xdg_wm_base)")
        return false
    }

    nested.surface = wl.compositor_create_surface(nested.compositor)
    xdg.wm_base_add_listener(nested.wm_base, &nested_wm_base_listener, nil)
    nested.xdg_surface = xdg.wm_base_get_xdg_surface(nested.wm_base, nested.surface)
    xdg.surface_add_listener(nested.xdg_surface, &nested_surface_listener, nil)
    nested.toplevel = xdg.surface_get_toplevel(nested.xdg_surface)
    xdg.toplevel_set_title(nested.toplevel, "rift (nested)")
    xdg.toplevel_set_app_id(nested.toplevel, "rift")
    wl.surface_commit(nested.surface)   // triggert configure
    wl.display_flush(nested.display)
    fmt.println("[nested] Fenster angefordert, warte auf configure …")
    return true
}

nested_get_fd :: proc() -> c.int {
    return c.int(wl.display_get_fd(nested.display))
}