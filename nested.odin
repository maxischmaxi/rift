package main

import wl "./wlclient"
import xdg "./wlclient/xdg"
import wpx "./wlclient/wp"
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

NESTED_W :: 800   // Default; tatsächliche Größe kommt vom xdg_toplevel.configure
NESTED_H :: 600
XRGB8888 :: wl.shm_format.xrgb8888   // == 1 (Spezialwert, kein FourCC)

Nested :: struct {
    display:       ^wl.display,
    compositor:    ^wl.compositor,
    shm:           ^wl.shm,
    wm_base:       ^xdg.wm_base,
    viewporter:    ^wpx.viewporter,   // wp_viewporter → logische Surface-Größe (korrekte Pointer-Koords)
    viewport:      ^wpx.viewport,
    cursor_theme:  ^wl.cursor_theme,  // libwayland-cursor Theme
    cursor_surface: ^wl.surface,      // Surface für den Cursor
    cursor_buf:    ^wl.buffer,        // Cursor-Bild-Buffer
    cursor_hx:     i32,               // Hotspot
    cursor_hy:     i32,
    frac_mgr:      ^wpx.fractional_scale_manager_v1,
    frac_obj:      ^wpx.fractional_scale_v1,
    output:        ^wl.output,        // wl_output vom Parent (für scale)
    output_scale:  i32,              // Output-Scale (integer, z.B. 2) → configure/scale = logisch
    scale:         f64,             // fractional Scale (z.B. 2.15) — Pointer-Koords / scale = logisch
    buf_scale:     i32,             // integer buffer_scale (wenn kein fractional) — Pointer-Koords / buf_scale = logisch
    surface:       ^wl.surface,     // das Fenster in Hyprland
    xdg_surface:   ^xdg.surface,
    toplevel:      ^xdg.toplevel,
    configured:    bool,
    win_w:         i32,             // tatsächliche Fenstergröße (vom Parent konfiguriert)
    win_h:         i32,
    // Fenster-Buffer (bei Resize neu angelegt)
    buffer:        ^wl.buffer,
    pool:          ^wl.shm_pool,    // gehört zum Buffer
    pixels:        [^]u32,          // mmap'd Fenster-Backing-Store
    buf_w:         i32,             // allozierte Buffer-Größe (für Bounds-Check)
    buf_h:         i32,
    pixels_size:   int,             // für munmap
    // Input (als Hyprland-Client)
    seat:          ^wl.seat,
    keyboard:      ^wl.keyboard,
    pointer:       ^wl.pointer,
    kb_focused:    bool,            // rift-Fenster hat in Hyprland Tastaturfokus
    ptr_focused:   bool,            // rift-Fenster hat in Hyprland Mausfokus
    ptr_x:         f64,             // aktuelle Mauspos im Nested-Fenster
    ptr_y:         f64,
    kb_keymap_fd:  i32,             // dup'd Keymap-fd vom Parent
    kb_keymap_size:u32,
    kb_repeat_rate: i32,
    kb_repeat_delay:i32,
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
    } else if iface == "wl_seat" {
        nested.seat = cast(^wl.seat)wl.registry_bind(registry, name, &wl.seat_interface, 4)
    } else if iface == "wp_viewporter" {
        nested.viewporter = cast(^wpx.viewporter)wl.registry_bind(registry, name, &wpx.viewporter_interface, 1)
    } else if iface == "wl_output" {
        nested.output = cast(^wl.output)wl.registry_bind(registry, name, &wl.output_interface, 2)
    }
}

nested_registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.registry, name: uint) {}

nested_registry_listener: wl.registry_listener = {
    global = nested_registry_global,
    global_remove = nested_registry_global_remove,
}

// ─── wl_seat: Capabilities vom Parent ──────────────────────────────────
// ⚠ SICHERHEIT: rein passiv. Wir fordern NIE einen Grab an.
WL_SEAT_CAP_KEYBOARD :: u32(2)
WL_SEAT_CAP_POINTER  :: u32(1)

nested_seat_capabilities :: proc "c" (data: rawptr, seat: ^wl.seat, caps: wl.seat_capability) {
    context = nested_ctx
    if u32(caps) & WL_SEAT_CAP_KEYBOARD != 0 && nested.keyboard == nil {
        nested.keyboard = wl.seat_get_keyboard(nested.seat)
        wl.keyboard_add_listener(nested.keyboard, &nested_keyboard_listener, nil)
        fmt.println("[nested] wl_keyboard vom Parent (Hyprland) geholt")
    }
    if u32(caps) & WL_SEAT_CAP_POINTER != 0 && nested.pointer == nil {
        nested.pointer = wl.seat_get_pointer(nested.seat)
        wl.pointer_add_listener(nested.pointer, &nested_pointer_listener, nil)
        fmt.println("[nested] wl_pointer vom Parent (Hyprland) geholt")
    }
}
nested_seat_name :: proc "c" (data: rawptr, seat: ^wl.seat, name: cstring) {}
nested_seat_listener: wl.seat_listener = {
    capabilities = nested_seat_capabilities,
    name = nested_seat_name,
}

// ─── wl_keyboard: Events vom Parent weiterreichen ─────────────────────
nested_kb_keymap :: proc "c" (data: rawptr, kb: ^wl.keyboard, format: wl.keyboard_keymap_format, fd: int, size: uint) {
    context = nested_ctx
    // fd duplizieren (das Original wird von libwayland-client geschlossen),
    // damit wir es pro rift-Client weiterreichen können.
    nested.kb_keymap_fd = i32(posix.dup(posix.FD(fd)))
    nested.kb_keymap_size = u32(size)
    fmt.printfln("[nested] keymap empfangen (size=%d), fd dup'd", size)
}
nested_kb_enter :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, surface: ^wl.surface, keys: wl.array) {
    context = nested_ctx
    nested.kb_focused = true
    input_keyboard_focus(true, u32(serial))
}
nested_kb_leave :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, surface: ^wl.surface) {
    context = nested_ctx
    nested.kb_focused = false
    input_keyboard_focus(false, u32(serial))
}
nested_kb_key :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, time: uint, key: uint, state: wl.keyboard_key_state) {
    context = nested_ctx
    input_keyboard_key(u32(time), u32(key), u32(state))
}
nested_kb_modifiers :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, depressed, latched, locked, group: uint) {
    context = nested_ctx
    input_keyboard_modifiers(u32(depressed), u32(latched), u32(locked), u32(group))
}
nested_kb_repeat_info :: proc "c" (data: rawptr, kb: ^wl.keyboard, rate: int, delay: int) {
    context = nested_ctx
    nested.kb_repeat_rate = i32(rate)
    nested.kb_repeat_delay = i32(delay)
}
nested_keyboard_listener: wl.keyboard_listener = {
    keymap = nested_kb_keymap,
    enter = nested_kb_enter,
    leave = nested_kb_leave,
    key = nested_kb_key,
    modifiers = nested_kb_modifiers,
    repeat_info = nested_kb_repeat_info,
}

// ─── wl_pointer: Events vom Parent weiterreichen ───────────────────────
// Koordinaten sind surface-local im Nested-Fenster (0..NESTED_W, 0..NESTED_H).
// Wir reichen sie als rift-Kompositor-Koordinaten weiter.
fixed_to_double :: proc(f: wl.fixed_t) -> f64 { return f64(f) / 256.0 }

// wp_fractional_scale_v1: der Parent teilt uns den genauen Scale mit (/120).
nested_frac_preferred_scale :: proc "c" (data: rawptr, fs: ^wpx.fractional_scale_v1, scale: uint) {
    context = nested_ctx
    nested.scale = f64(scale) / 120.0
    fmt.printfln("[nested] fractional preferred_scale = %.3f", nested.scale)
}
nested_frac_listener: wpx.fractional_scale_v1_listener = { preferred_scale = nested_frac_preferred_scale }

// wl_surface: preferred_buffer_scale (integer) — fallback wenn kein fractional
nested_surf_enter :: proc "c" (data: rawptr, surf: ^wl.surface, out: ^wl.output) {}
nested_surf_leave :: proc "c" (data: rawptr, surf: ^wl.surface, out: ^wl.output) {}
nested_surf_pref_scale :: proc "c" (data: rawptr, surf: ^wl.surface, factor: int) {
    context = nested_ctx
    nested.buf_scale = i32(factor)
    wl.surface_set_buffer_scale(nested.surface, factor)
    fmt.printfln("[nested] preferred_buffer_scale = %d", factor)
}
nested_surf_pref_xform :: proc "c" (data: rawptr, surf: ^wl.surface, xform: wl.output_transform) {}
nested_surf_listener: wl.surface_listener = {
    enter = nested_surf_enter, leave = nested_surf_leave,
    preferred_buffer_scale = nested_surf_pref_scale,
    preferred_buffer_transform = nested_surf_pref_xform,
}

// wl_output: scale vom Parent (integer) — configure-Größe / scale = logisch.
// WICHTIG: libwayland-client nil-checkt Listener NICHT → alle Events brauchen
// (no-op-)Handler, die feuern können (geometry/mode/done/scale).
nested_output_geometry :: proc "c" (data: rawptr, out: ^wl.output, x, y, pw, ph: int, sub: wl.output_subpixel, make, model: cstring, xform: wl.output_transform) {}
nested_output_mode :: proc "c" (data: rawptr, out: ^wl.output, flags: wl.output_mode, w, h, refresh: int) {}
nested_output_done :: proc "c" (data: rawptr, out: ^wl.output) {}
nested_output_scale :: proc "c" (data: rawptr, out: ^wl.output, factor: int) {
    context = nested_ctx
    nested.output_scale = i32(factor)
    fmt.printfln("[nested] output scale = %d", factor)
}
nested_output_listener: wl.output_listener = {
    geometry = nested_output_geometry, mode = nested_output_mode,
    done = nested_output_done, scale = nested_output_scale,
}

// Effektiver Scale für Pointer-Koordinaten-Normalisierung.
nested_ptr_scale :: proc() -> f64 {
    if nested.scale > 1.0 do return nested.scale     // fractional gewinnt
    if nested.buf_scale > 0 do return f64(nested.buf_scale)  // sonst integer
    return 1.0
}

nested_ptr_enter :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, surf: ^wl.surface, sx, sy: wl.fixed_t) {
    context = nested_ctx
    nested.ptr_focused = true
    s := nested_ptr_scale()
    nested.ptr_x = fixed_to_double(sx) / s
    nested.ptr_y = fixed_to_double(sy) / s
    // Cursor über dem rift-Fenster sichtbar machen (sonst versteckt Hyprland ihn).
    if nested.cursor_surface != nil && nested.pointer != nil {
        wl.pointer_set_cursor(nested.pointer, serial, nested.cursor_surface, int(nested.cursor_hx), int(nested.cursor_hy))
    }
    fmt.printfln("[nested] pointer enter (%.0f, %.0f)", nested.ptr_x, nested.ptr_y)
    input_pointer_enter(true, u32(serial))
}
nested_ptr_leave :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, surf: ^wl.surface) {
    context = nested_ctx
    nested.ptr_focused = false
    input_pointer_enter(false, u32(serial))
}
nested_ptr_motion :: proc "c" (data: rawptr, p: ^wl.pointer, time: uint, sx, sy: wl.fixed_t) {
    context = nested_ctx
    s := nested_ptr_scale()
    nested.ptr_x = fixed_to_double(sx) / s
    nested.ptr_y = fixed_to_double(sy) / s
    input_pointer_motion(u32(time), nested.ptr_x, nested.ptr_y)
}
nested_ptr_button :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, time: uint, button: uint, state: wl.pointer_button_state) {
    context = nested_ctx
    fmt.printfln("[nested] pointer button btn=%d state=%s", button, state)
    input_pointer_button(u32(serial), u32(time), u32(button), u32(state))
}
nested_ptr_axis :: proc "c" (data: rawptr, p: ^wl.pointer, time: uint, axis: wl.pointer_axis, value: wl.fixed_t) {
    context = nested_ctx
    input_pointer_axis(u32(time), u32(axis), fixed_to_double(value))
}
nested_ptr_frame :: proc "c" (data: rawptr, p: ^wl.pointer) {
    context = nested_ctx
    input_pointer_frame()
}
nested_ptr_axis_source :: proc "c" (data: rawptr, p: ^wl.pointer, src: wl.pointer_axis_source) {}
nested_ptr_axis_stop :: proc "c" (data: rawptr, p: ^wl.pointer, time: uint, axis: wl.pointer_axis) {}
nested_ptr_axis_discrete :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, disc: int) {}
nested_ptr_axis_value120 :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, v120: int) {}
nested_ptr_axis_rel_dir :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, dir: wl.pointer_axis_relative_direction) {}

nested_pointer_listener: wl.pointer_listener = {
    enter = nested_ptr_enter, leave = nested_ptr_leave, motion = nested_ptr_motion,
    button = nested_ptr_button, axis = nested_ptr_axis, frame = nested_ptr_frame,
    axis_source = nested_ptr_axis_source, axis_stop = nested_ptr_axis_stop,
    axis_discrete = nested_ptr_axis_discrete, axis_value120 = nested_ptr_axis_value120,
    axis_relative_direction = nested_ptr_axis_rel_dir,
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
    // Viewport auf logische Größe pinnen → Hyprland liefert Pointer-Koords 0..win_w.
    if nested.viewport != nil {
        wpx.viewport_set_destination(nested.viewport, int(nested.win_w), int(nested.win_h))
    }
    // Buffer bei Größenänderung neu erzeugen (sonst Overflow in nested_clear).
    if nested.buffer == nil || nested.buf_w != nested.win_w || nested.buf_h != nested.win_h {
        if nested.buffer != nil do nested_destroy_buffer()
        nested_create_buffer()
    }
    if nested.buffer != nil {
        wl.surface_attach(nested.surface, nested.buffer, 0, 0)
        wl.surface_damage(nested.surface, 0, 0, int(nested.win_w), int(nested.win_h))
        wl.surface_commit(nested.surface)
        nested.configured = true
        fmt.println("[nested] Fenster konfiguriert + erstes Bild committet")
    }
}
nested_surface_listener: xdg.surface_listener = { configure = nested_surface_configure }

// ─── Fenster-Buffer anlegen (einmal, feste 200x200) ────────────────────
nested_create_buffer :: proc() {
    context = nested_ctx
    if nested.win_w <= 0 do nested.win_w = NESTED_W
    if nested.win_h <= 0 do nested.win_h = NESTED_H
    size := int(nested.win_w) * int(nested.win_h) * 4
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
    nested.pool = pool
    nested.buffer = wl.shm_pool_create_buffer(pool, 0, int(nested.win_w), int(nested.win_h), int(nested.win_w)*4, XRGB8888)
    nested.buf_w = nested.win_w
    nested.buf_h = nested.win_h
    nested.pixels_size = size
    // Pool nicht zerstören — der Buffer referenziert ihn. Wird am Ende mitfreigegeben.
    fmt.printfln("[nested] Fenster-Buffer %dx%d angelegt", nested.win_w, nested.win_h)
}

// Buffer freigeben (bei Resize oder Shutdown).
nested_destroy_buffer :: proc() {
    context = nested_ctx
    if nested.buffer != nil { wl.buffer_destroy(nested.buffer); nested.buffer = nil }
    if nested.pool   != nil { wl.shm_pool_destroy(nested.pool);   nested.pool   = nil }
    if nested.pixels != nil {
        linux.munmap(cast(rawptr)nested.pixels, uint(nested.pixels_size))
        nested.pixels = nil
    }
    nested.buf_w = 0
    nested.buf_h = 0
}

// xdg_toplevel.configure: der Parent sagt uns die Fenstergröße.
nested_toplevel_configure :: proc "c" (data: rawptr, tl: ^xdg.toplevel, w, h: int, states: wl.array) {
    context = nested_ctx
    if w > 0 do nested.win_w = i32(w) / (nested.output_scale if nested.output_scale > 0 else 1)
    if h > 0 do nested.win_h = i32(h) / (nested.output_scale if nested.output_scale > 0 else 1)
    fmt.printfln("[nested] toplevel.configure phys %dx%d → logisch %dx%d", w, h, nested.win_w, nested.win_h)
}
nested_toplevel_close :: proc "c" (data: rawptr, tl: ^xdg.toplevel) {}
nested_toplevel_listener: xdg.toplevel_listener = {
    configure = nested_toplevel_configure,
    close = nested_toplevel_close,
}

// ─── Composite-Helfer für mehrere Toplevels ────────────────────────────
// nested_clear: Fenster-Buffer mit Farbe füllen (Hintergrund).
nested_clear :: proc(color: u32) {
    context = nested_ctx
    if nested.pixels == nil do return
    // Bounds = allozierte Buffer-Größe (buf_w/buf_h), nicht win_w/win_h —
    // sonst Overflow wenn der Parent resize hat aber der Buffer noch nicht
    // neu erzeugt wurde.
    w := nested.buf_w; h := nested.buf_h
    if w <= 0 do w = nested.win_w
    if h <= 0 do h = nested.win_h
    if w <= 0 || h <= 0 do return
    for i in 0..<int(w)*int(h) do nested.pixels[i] = color
}

// nested_blit_scaled: Quelle skaliert in Fenster-Buffer an (dx,dy,dw,dh) blitten.
// Nearest-Neighbor-Skalierung (einfach, reicht für den Anfang).
nested_blit_scaled :: proc(src: [^]u32, src_w, src_h: i32, dx, dy, dw, dh: i32) {
    context = nested_ctx
    if nested.pixels == nil || dw <= 0 || dh <= 0 || src_w <= 0 || src_h <= 0 do return
    ww := int(nested.buf_w)   // Stride = allozierte Breite
    if ww <= 0 do ww = int(nested.win_w)
    for y in 0..<dh {
        sy := y * src_h / dh
        for x in 0..<dw {
            sx := x * src_w / dw
            nested.pixels[int(dy+y)*ww + int(dx+x)] = src[int(sy)*int(src_w) + int(sx)]
        }
    }
}

// nested_commit_window: fertigen Fenster-Buffer an Hyprland schicken.
nested_commit_window :: proc() {
    context = nested_ctx
    if !nested.configured || nested.buffer == nil do return
    wl.surface_attach(nested.surface, nested.buffer, 0, 0)
    wl.surface_damage(nested.surface, 0, 0, int(nested.win_w), int(nested.win_h))
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

    // wl_seat: Listener anmelden + Roundtrip, damit capabilities+keyboard ankommen.
    if nested.seat != nil {
        wl.seat_add_listener(nested.seat, &nested_seat_listener, nil)
        wl.display_roundtrip(nested.display)
    } else {
        fmt.println("[nested] kein wl_seat vom Parent — Input-Forwarding deaktiviert")
    }
    // wl_output: scale holen (vor configure, damit wir logisch rechnen).
    if nested.output != nil {
        wl.output_add_listener(nested.output, &nested_output_listener, nil)
        wl.display_roundtrip(nested.display)
    }

    nested.surface = wl.compositor_create_surface(nested.compositor)
    if nested.viewporter != nil {
        nested.viewport = wpx.viewporter_get_viewport(nested.viewporter, nested.surface)
    }
    // Hinweis: wp_fractional_scale UND preferred_buffer_scale sind mutually exclusive.
    // Wir nutzen hier preferred_buffer_scale (integer), also KEIN fractional_scale binden.
    // (fractional_scale-Code bleibt für später, falls ein Output fractional nutzt.)
    wl.surface_add_listener(nested.surface, &nested_surf_listener, nil)
    xdg.wm_base_add_listener(nested.wm_base, &nested_wm_base_listener, nil)
    nested.xdg_surface = xdg.wm_base_get_xdg_surface(nested.wm_base, nested.surface)
    xdg.surface_add_listener(nested.xdg_surface, &nested_surface_listener, nil)
    nested.toplevel = xdg.surface_get_toplevel(nested.xdg_surface)
    xdg.toplevel_add_listener(nested.toplevel, &nested_toplevel_listener, nil)
    xdg.toplevel_set_title(nested.toplevel, "rift (nested)")
    xdg.toplevel_set_app_id(nested.toplevel, "rift")
    nested_init_cursor()   // Cursor-Theme + -Surface für set_cursor
    wl.surface_commit(nested.surface)   // triggert configure
    wl.display_flush(nested.display)
    fmt.println("[nested] Fenster angefordert, warte auf configure …")
    return true
}

nested_get_fd :: proc() -> c.int {
    return c.int(wl.display_get_fd(nested.display))
}

// ─── Cursor-Setup (libwayland-cursor) ──────────────────────────────────
// Lädt ein Cursor-Theme, holt den "left_ptr"-Pfeil, erzeugt ein Cursor-
// Surface mit dem Bild. Bei pointer.enter rufen wir set_cursor, damit der
// Cursor über dem rift-Fenster sichtbar ist (sonst versteckt Hyprland ihn).
nested_init_cursor :: proc() {
    context = nested_ctx
    if nested.shm == nil || nested.compositor == nil do return
    nested.cursor_theme = wl.cursor_theme_load(nil, 32, nested.shm)
    if nested.cursor_theme == nil { fmt.println("[nested] cursor_theme_load fehlgeschlagen"); return }
    c := wl.cursor_theme_get_cursor(nested.cursor_theme, "left_ptr")
    if c == nil { fmt.println("[nested] cursor 'left_ptr' nicht gefunden"); return }
    if c.image_count == 0 do return
    img := c.images[0]   // ^cursor_image (Pointer — get_buffer will ihn so)
    nested.cursor_buf = wl.cursor_image_get_buffer(img)
    nested.cursor_hx = i32(img.hotspot_x)
    nested.cursor_hy = i32(img.hotspot_y)
    nested.cursor_surface = wl.compositor_create_surface(nested.compositor)
    wl.surface_attach(nested.cursor_surface, nested.cursor_buf, 0, 0)
    wl.surface_commit(nested.cursor_surface)
    fmt.printfln("[nested] cursor geladen: %dx%d hotspot (%d,%d)", img.width, img.height, nested.cursor_hx, nested.cursor_hy)
}