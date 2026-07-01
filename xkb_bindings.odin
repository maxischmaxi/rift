package main

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libxkbcommon Bindings — Keymap-Erzeugung für den DRM-Modus
//
//  Im Nested-Modus liefert der Parent-Compositor die Keymap (fd).
//  Im DRM-Modus müssen wir sie selbst kompilieren: RMLVO-Namen →
//  xkb_keymap → Text-Dump → memfd (Clients bekommen dup'd fds).
// ═══════════════════════════════════════════════════════════════════════════

foreign import libxkbcommon "system:xkbcommon"

XkbContext :: distinct struct {}
XkbKeymap  :: distinct struct {}

// RMLVO: Rules, Model, Layout, Variant, Options.
// NULL/leer = System-Default (bzw. XKB_DEFAULT_* Umgebungsvariablen).
XkbRuleNames :: struct {
    rules:   cstring,
    model:   cstring,
    layout:  cstring,
    variant: cstring,
    options: cstring,
}

XKB_CONTEXT_NO_FLAGS        :: c.int(0)
XKB_KEYMAP_COMPILE_NO_FLAGS :: c.int(0)
XKB_KEYMAP_FORMAT_TEXT_V1   :: c.int(1)

@(default_calling_convention = "c")
foreign libxkbcommon {
    xkb_context_new           :: proc(flags: c.int) -> ^XkbContext ---
    xkb_context_unref         :: proc(xctx: ^XkbContext) ---
    xkb_keymap_new_from_names :: proc(xctx: ^XkbContext, names: ^XkbRuleNames, flags: c.int) -> ^XkbKeymap ---
    xkb_keymap_unref          :: proc(keymap: ^XkbKeymap) ---
    // Rückgabe ist malloc'd — mit libc free() freigeben.
    xkb_keymap_get_as_string  :: proc(keymap: ^XkbKeymap, format: c.int) -> cstring ---
}
