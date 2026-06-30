package kbclient

import wl "../../wlclient"
import xdg "../../wlclient/xdg"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:sys/posix"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Keyboard-Test-Client. Verbindet sich mit rift-0, mappt ein xdg-
//  Fenster (damit rift es fokussieren kann) und loggt alle empfangenen
//  wl_keyboard-Events. Beweist das Input-Forwarding Hyprland→rift→Client.
// ═══════════════════════════════════════════════════════════════════════════

XRGB8888 :: wl.shm_format.xrgb8888
W :: 300
H :: 200

g_ctx: runtime.Context
compositor : ^wl.compositor
shm        : ^wl.shm
seat       : ^wl.seat
wm_base    : ^xdg.wm_base
surface    : ^wl.surface
xdg_surface: ^xdg.surface
toplevel   : ^xdg.toplevel
configured : bool

// ─── Registry ──────────────────────────────────────────────────────────
reg_global :: proc "c" (data: rawptr, reg: ^wl.registry, name: uint, iface: cstring, ver: uint) {
    context = g_ctx
    s := string(iface)
    if s == "wl_compositor" { compositor = cast(^wl.compositor)wl.registry_bind(reg, name, &wl.compositor_interface, 4) }
    else if s == "wl_shm"   { shm = cast(^wl.shm)wl.registry_bind(reg, name, &wl.shm_interface, 1) }
    else if s == "wl_seat"  { seat = cast(^wl.seat)wl.registry_bind(reg, name, &wl.seat_interface, 4) }
    else if s == "xdg_wm_base" { wm_base = cast(^xdg.wm_base)wl.registry_bind(reg, name, &xdg.wm_base_interface, 1) }
}
reg_global_remove :: proc "c" (data: rawptr, reg: ^wl.registry, name: uint) {}
reg_listener: wl.registry_listener = { global = reg_global, global_remove = reg_global_remove }

// ─── xdg: ping + configure ─────────────────────────────────────────────
wm_ping :: proc "c" (data: rawptr, wb: ^xdg.wm_base, serial: uint) { xdg.wm_base_pong(wb, serial) }
wm_listener: xdg.wm_base_listener = { ping = wm_ping }

xsurf_configure :: proc "c" (data: rawptr, xs: ^xdg.surface, serial: uint) {
    context = g_ctx
    xdg.surface_ack_configure(xs, serial)
    configured = true
    draw_and_commit()
}
xsurf_listener: xdg.surface_listener = { configure = xsurf_configure }

// ─── wl_seat: keyboard holen ───────────────────────────────────────────
seat_caps :: proc "c" (data: rawptr, st: ^wl.seat, caps: wl.seat_capability) {
    context = g_ctx
    if u32(caps) & 2 != 0 {  // keyboard
        kb := wl.seat_get_keyboard(st)
        wl.keyboard_add_listener(kb, &kb_listener, nil)
        fmt.println("[kbclient] wl_keyboard gebunden, lausche auf Keys …")
    }
    if u32(caps) & 1 != 0 {  // pointer
        pt := wl.seat_get_pointer(st)
        wl.pointer_add_listener(pt, &ptr_listener, nil)
        fmt.println("[kbclient] wl_pointer gebunden, lausche auf Maus …")
    }
}
seat_name :: proc "c" (data: rawptr, st: ^wl.seat, name: cstring) {}
seat_listener: wl.seat_listener = { capabilities = seat_caps, name = seat_name }

// ─── wl_keyboard: Events loggen (das beweist das Forwarding!) ──────────
kb_keymap :: proc "c" (data: rawptr, kb: ^wl.keyboard, fmt_: wl.keyboard_keymap_format, fd: int, size: uint) {
    context = g_ctx
    fmt.printfln("[kbclient] KEYMAP empfangen (format=%d size=%d fd=%d)", u32(fmt_), size, fd)
    posix.close(posix.FD(fd))  // wir mappen es nicht; nur zeigen dass es ankommt
}
kb_enter :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, surf: ^wl.surface, keys: wl.array) {
    context = g_ctx
    fmt.println("[kbclient] KEYBOARD ENTER — rift hat uns fokussiert!")
}
kb_leave :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, surf: ^wl.surface) {
    context = g_ctx
    fmt.println("[kbclient] keyboard leave")
}
kb_key :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, time: uint, key: uint, state: wl.keyboard_key_state) {
    context = g_ctx
    fmt.printfln("[kbclient] ★ KEY  code=%d  state=%s", key, state)
}
kb_mods :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, d, l, lo, g: uint) {
    context = g_ctx
    if d != 0 || l != 0 || lo != 0 do fmt.printfln("[kbclient] modifiers  dep=%d lat=%d lock=%d grp=%d", d, l, lo, g)
}
kb_repeat :: proc "c" (data: rawptr, kb: ^wl.keyboard, rate: int, delay: int) {
    context = g_ctx
    fmt.printfln("[kbclient] repeat_info rate=%d delay=%d", rate, delay)
}
kb_listener: wl.keyboard_listener = {
    keymap = kb_keymap, enter = kb_enter, leave = kb_leave,
    key = kb_key, modifiers = kb_mods, repeat_info = kb_repeat,
}

// ─── wl_pointer: Events loggen (beweist Pointer-Forwarding) ───────────
ptr_enter :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, surf: ^wl.surface, sx, sy: wl.fixed_t) {
    context = g_ctx
    fmt.printfln("[kbclient] ★ POINTER ENTER  (%.0f, %.0f)", f64(sx)/256.0, f64(sy)/256.0)
}
ptr_leave :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, surf: ^wl.surface) {
    context = g_ctx
    fmt.println("[kbclient] pointer leave")
}
ptr_motion :: proc "c" (data: rawptr, p: ^wl.pointer, time: uint, sx, sy: wl.fixed_t) {
    context = g_ctx
    fmt.printfln("[kbclient]   motion (%.0f, %.0f)", f64(sx)/256.0, f64(sy)/256.0)
}
ptr_button :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, time: uint, button: uint, state: wl.pointer_button_state) {
    context = g_ctx
    fmt.printfln("[kbclient] ★ POINTER BUTTON  btn=%d  state=%s", button, state)
}
ptr_frame :: proc "c" (data: rawptr, p: ^wl.pointer) {}
ptr_listener: wl.pointer_listener = {
    enter = ptr_enter, leave = ptr_leave, motion = ptr_motion,
    button = ptr_button, frame = ptr_frame,
}

// ─── zeichnen: solidfarbenes Fenster ───────────────────────────────────
draw_and_commit :: proc() {
    context = g_ctx
    size := W * H * 4
    nm := fmt.caprintf("/kbc_%v", uintptr(surface))
    fd := posix.shm_open(nm, {.RDWR, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
    defer posix.close(fd)
    if fd >= 0 do posix.shm_unlink(nm)
    posix.ftruncate(auto_cast fd, auto_cast size)
    raw, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, 0)
    if err != .NONE do return
    px := cast([^]u32)raw
    for i in 0..<W*H do px[i] = 0xFF3b82f6   // blau
    linux.munmap(raw, uint(size))
    pool := wl.shm_create_pool(shm, auto_cast fd, size)
    buf := wl.shm_pool_create_buffer(pool, 0, W, H, W*4, XRGB8888)
    wl.shm_pool_destroy(pool)
    wl.surface_attach(surface, buf, 0, 0)
    wl.surface_damage(surface, 0, 0, W, H)
    wl.surface_commit(surface)
}

main :: proc() {
    g_ctx = context
    d := wl.display_connect(nil)
    if d == nil { fmt.println("connect fail"); return }
    fmt.println("[kbclient] verbunden mit rift-0")
    reg := wl.display_get_registry(d)
    wl.registry_add_listener(reg, &reg_listener, nil)
    wl.display_roundtrip(d)

    if compositor == nil || shm == nil || wm_base == nil { fmt.println("globals fehlen"); return }
    if seat != nil {
        wl.seat_add_listener(seat, &seat_listener, nil)
        wl.display_roundtrip(d)   // capabilities + keyboard holen
    }

    surface = wl.compositor_create_surface(compositor)
    xdg.wm_base_add_listener(wm_base, &wm_listener, nil)
    xdg_surface = xdg.wm_base_get_xdg_surface(wm_base, surface)
    xdg.surface_add_listener(xdg_surface, &xsurf_listener, nil)
    toplevel = xdg.surface_get_toplevel(xdg_surface)
    xdg.toplevel_set_title(toplevel, " rift keyboard test")
    wl.surface_commit(surface)   // triggert configure → draw_and_commit

    fmt.println("[kbclient] laeuft. Fokussiere das rift-Fenster und tippe!")
    for wl.display_dispatch(d) != 0 {}
}