package main

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:c/libc"

// ═══════════════════════════════════════════════════════════════════════════
//  DRM-Modus Keymap — Clients brauchen einen wl_keyboard.keymap-fd.
//
//  Kompiliert die Keymap aus der rift-Config ([input] kb_layout etc.,
//  Fallback: System-Defaults/XKB_DEFAULT_*-Env) und legt sie in ein memfd.
//  input_seat_get_keyboard dupliziert den fd pro Client — derselbe
//  Mechanismus wie im Nested-Modus (dort kommt der fd vom Parent).
// ═══════════════════════════════════════════════════════════════════════════

drm_keymap_init :: proc() -> bool {
    context = ctx

    xctx := xkb_context_new(XKB_CONTEXT_NO_FLAGS)
    if xctx == nil {
        fmt.eprintln("[keymap] FEHLER: xkb_context_new fehlgeschlagen")
        return false
    }
    defer xkb_context_unref(xctx)

    layout_c, _  := strings.clone_to_cstring(g_config.kb_layout)
    variant_c, _ := strings.clone_to_cstring(g_config.kb_variant)
    options_c, _ := strings.clone_to_cstring(g_config.kb_options)
    model_c, _   := strings.clone_to_cstring(g_config.kb_model)
    names := XkbRuleNames{
        layout  = layout_c,
        variant = variant_c,
        options = options_c,
        model   = model_c,
    }
    keymap := xkb_keymap_new_from_names(xctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS)
    if keymap == nil {
        fmt.eprintfln("[keymap] WARNUNG: Keymap für layout={} nicht kompilierbar — Fallback auf Default",
            g_config.kb_layout)
        empty := XkbRuleNames{}
        keymap = xkb_keymap_new_from_names(xctx, &empty, XKB_KEYMAP_COMPILE_NO_FLAGS)
        if keymap == nil {
            fmt.eprintln("[keymap] FEHLER: auch Default-Keymap fehlgeschlagen")
            return false
        }
    }
    defer xkb_keymap_unref(keymap)

    str := xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1)
    if str == nil {
        fmt.eprintln("[keymap] FEHLER: keymap_get_as_string fehlgeschlagen")
        return false
    }
    defer libc.free(rawptr(str))

    // wl_keyboard.keymap-Konvention: String inkl. NUL-Terminator
    size := len(string(str)) + 1

    fd, errno := linux.memfd_create("rift-keymap", {.CLOEXEC})
    if errno != .NONE {
        fmt.eprintfln("[keymap] FEHLER: memfd_create: {}", errno)
        return false
    }

    data := ([^]u8)(rawptr(str))[:size]
    written := 0
    for written < size {
        n, werr := linux.write(fd, data[written:])
        if werr != .NONE || n <= 0 {
            fmt.eprintfln("[keymap] FEHLER: write: {}", werr)
            linux.close(fd)
            return false
        }
        written += n
    }

    // In die nested-Struct — input_seat_get_keyboard liest von dort
    // (gemeinsamer Speicher für beide Backends).
    nested.kb_keymap_fd = i32(fd)
    nested.kb_keymap_size = u32(size)
    // Tastenwiederholung: Standardwerte (Clients wiederholen selbst)
    if nested.kb_repeat_rate == 0 {
        nested.kb_repeat_rate = 25
        nested.kb_repeat_delay = 400
    }

    fmt.printfln("[keymap] ✅ Keymap kompiliert (layout={}, {} bytes, memfd={})",
        g_config.kb_layout, size, fd)
    return true
}
