package main

import "core:fmt"
import "core:os"
import "core:c"
import wls "./wayland_server"

main :: proc() {
    ctx = context   // Odin-Context für C-Callbacks sichern (Allocator, Logger …)
    server := Server{display = wls.display_create()}
    g_server = &server   // global, damit xdg-Handler an display_next_serial kommen
    if server.display == nil {
        fmt.println("wl_display_create fehlgeschlagen")
        os.exit(1)
    }

    // Fester Socket-Name → nie Kollision mit Hyprlands wayland-1.
    if wls.display_add_socket(server.display, "rift-0") != 0 {
        fmt.println("Konnte Wayland-Socket 'rift-0' nicht anlegen")
        os.exit(1)
    }
    fmt.println("Wayland-Socket: rift-0  (fest → keine Berührung mit Hyprland)")

    if !register_globals(&server) {
        fmt.println("Global-Registrierung fehlgeschlagen")
        os.exit(1)
    }

    // xdg-shell (für echte Fenster via xdg_toplevel)
    if !register_xdg_global(&server) {
        fmt.println("xdg_wm_base-Registrierung fehlgeschlagen")
        os.exit(1)
    }

    // ── Nested-Backend: rift wird Client von Hyprland, öffnet ein Fenster ──
    if !nested_init() {
        fmt.println("[init] Nested-Backend fehlgeschlagen (weiter ohne Fenster)")
    } else {
        // Parent-Client-fd in den Server-Event-Loop hängen → beide Loops in einem.
        loop := wls.display_get_event_loop(server.display)
        wls.event_loop_add_fd(loop, nested_get_fd(), wls.WL_EVENT_READABLE, nested_dispatch, nil)
    }

    fmt.println("Compositor läuft. Verbinde mit:  WAYLAND_DISPLAY=rift-0 <client>")
    fmt.println("STRG-C zum Abbruch")
    wls.display_run(server.display)

    wls.display_destroy(server.display)
}