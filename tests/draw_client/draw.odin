package draw_client

import wl "../../wlclient"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Test-Client — zeichnet ein Schachbrett über wl_shm und committet
//  es an die rift-Surface, mit Frame-Callback-Schleife (bounded).
//  Testet: attach → commit → (rift empfängt Pixel) → frame done → redraw.
// ═══════════════════════════════════════════════════════════════════════════

compositor : ^wl.compositor
shm        : ^wl.shm
surface    : ^wl.surface
global_ctx : runtime.Context
frame_count: int = 0
FRAMES_MAX  :: 4   // nur 4 Frames, dann sauber beenden

// Echter wl_shm-Wert für xrgb8888. ACHTUNG: argb8888=0, xrgb8888=1 sind
// SPEZIALWERTE (keine FourCCs!) laut wayland.xml. Die anderen Formate nutzen FourCC.
XRGB8888 :: wl.shm_format.xrgb8888   // == 1

WIDTH  :: 200
HEIGHT :: 200
STRIDE :: WIDTH * 4   // 32-bit

// ─── Registry: Globals abfangen ────────────────────────────────────────
registry_global :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint, interface: cstring, version: uint) {
    context = global_ctx
    iface := string(interface)
    if iface == "wl_compositor" {
        compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
    } else if iface == "wl_shm" {
        shm = cast(^wl.shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
    }
}
registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

// ─── Frame-Callback: rift feuert done → wir zeichnen neu ───────────────
frame_done :: proc "c" (data: rawptr, cb: ^wl.callback, callback_data: uint) {
    context = global_ctx
    wl.callback_destroy(cb)
    if frame_count >= FRAMES_MAX {
        return   // Schleife beenden
    }
    draw()
}
frame_listener: wl.callback_listener = { done = frame_done }

// ─── Ein Bild zeichnen: shm-Buffer → Schachbrett → attach → commit ───
draw :: proc() {
    context = global_ctx
    frame_count += 1
    fmt.printfln("[client] zeichne Frame %d", frame_count)

    size := STRIDE * HEIGHT
    name := fmt.caprintf("/rift_shm_%v", uintptr(surface))
    fd := posix.shm_open(name, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
    defer posix.close(fd)
    if fd >= 0 { posix.shm_unlink(name) }
    else { fmt.println("[client] shm_open fehlgeschlagen"); return }

    if posix.ftruncate(auto_cast fd, auto_cast size) == .FAIL {
        fmt.println("[client] ftruncate fehlgeschlagen"); return
    }

    data_raw, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
    if err != .NONE { fmt.println("[client] mmap fehlgeschlagen"); return }
    pixels := cast([^]u32)data_raw
    defer linux.munmap(data_raw, uint(size))

    // Schachbrett (10x10 Zellen à 20px)
    cell :: 20
    for y in 0..<HEIGHT {
        for x in 0..<WIDTH {
            idx := y*WIDTH + x
            if ((x / cell) + (y / cell)) % 2 == 0 {
                pixels[idx] = 0xFF303030   // dunkelgrau (ARGB, premul)
            } else {
                pixels[idx] = 0xFFE0E0E0   // hellgrau
            }
        }
    }

    pool := wl.shm_create_pool(shm, auto_cast fd, size)
    buffer := wl.shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, STRIDE, XRGB8888)
    // Pool sofort wegwerfen; Buffer hält eigene Referenz.
    wl.shm_pool_destroy(pool)

    wl.surface_attach(surface, buffer, 0, 0)
    wl.surface_damage(surface, 0, 0, WIDTH, HEIGHT)

    // Frame-Callback für diese Surface anfordern → feuert nach commit (rift).
    cb := wl.surface_frame(surface)
    wl.callback_add_listener(cb, &frame_listener, nil)

    wl.surface_commit(surface)
    // Buffer wird beim release (das rift beim nächsten Commit schickt) freigegeben.
}

// ─── main ──────────────────────────────────────────────────────────────
main :: proc() {
    global_ctx = context
    display := wl.display_connect(nil)   // nutzt $WAYLAND_DISPLAY
    if display == nil { fmt.println("[client] Verbindung fehlgeschlagen"); return }
    fmt.println("[client] verbunden mit Wayland-Display")

    registry := wl.display_get_registry(display)
    listener := wl.registry_listener { global = registry_global, global_remove = registry_global_remove }
    wl.registry_add_listener(registry, &listener, nil)
    wl.display_roundtrip(display)

    if compositor == nil || shm == nil {
        fmt.println("[client] Globals unvollständig (compositor/shm fehlen)")
        return
    }
    fmt.println("[client] wl_compositor + wl_shm gebunden")

    surface = wl.compositor_create_surface(compositor)
    draw()   // Frame 1; danach treiben frame-callbacks die weiteren Frames

    for wl.display_dispatch(display) != 0 {
        if frame_count >= FRAMES_MAX { break }
    }
    fmt.println("[client] fertig, trenne")
    wl.display_disconnect(display)
}