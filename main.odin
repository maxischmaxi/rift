package main

import "core:fmt"
import "core:os"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  rift — Wayland-Compositor in Odin.
//
//  main() ist der Einstiegspunkt: erstellt die wl_display, registriert die
//  Wayland-Globals, startet das Nested-Backend (rift als Client von Hyprland)
//  und läuft dann im Event-Loop.
//
//  rift ist gleichzeitig:
//    • Wayland-SERVER auf Socket "rift-0" (für rift-Clients)
//    • Wayland-CLIENT von Hyprland (wayland-1, für das Ausgabefenster)
//  Beide Loops sind in einem einzigen wl_event_loop vereint.
// ═══════════════════════════════════════════════════════════════════════════

main :: proc() {
    // Odin-Context für C-Callbacks sichern (Allocator, Logger).
    // proc "c" bekommt keinen Odin-Context → wir restaurieren ihn global.
    ctx = context

    // ── 1. Config laden (nur g_config, nicht g_server) ────────────────
    config_load()

    // ── 2. Display + Socket ────────────────────────────────────────────
    server := Server{display = wls.display_create()}
    g_server = &server

    // ── 2b. Workspaces anlegen (braucht g_server) ────────────────────────
    workspaces_init(DEFAULT_WS_COUNT)
    if server.display == nil {
        fmt.eprintln("rift: wl_display_create fehlgeschlagen")
        os.exit(1)
    }
    if wls.display_add_socket(server.display, "rift-0") != 0 {
        fmt.eprintln("rift: Socket 'rift-0' belegt — läuft schon eine Instanz?")
        os.exit(1)
    }

    // ── 3. Wayland-Globals registrieren ────────────────────────────────
    if !register_globals(&server) || !register_xdg_global(&server) {
        fmt.eprintln("rift: Global-Registrierung fehlgeschlagen")
        os.exit(1)
    }

    // ── 4. Nested-Backend: rift wird Client von Hyprland ───────────────
    if !nested_init() {
        fmt.eprintln("rift: Nested-Backend fehlgeschlagen (weiter ohne Fenster)")
    } else {
        // Parent-Client-fd in den Server-Event-Loop hängen → beide Loops
        // in einem (Server für rift-Clients + Client für Hyprland).
        loop := wls.display_get_event_loop(server.display)
        wls.event_loop_add_fd(loop, nested_get_fd(), wls.WL_EVENT_READABLE, nested_dispatch, nil)
    }

    // ── 5. Autostart-Befehle ausführen ─────────────────────────────────
    config_run_autostart()

    // ── 6. Event-Loop ──────────────────────────────────────────────────
    fmt.println("═══ rift ready ═══")
    fmt.println("  Socket:   rift-0")
    fmt.println("  Starte Clients mit:  WAYLAND_DISPLAY=rift-0 <app>")
    fmt.println("  Beenden:  kill <pid>  oder  Super+Shift+Q")

    wls.display_run(server.display)

    // ── 7. Cleanup ─────────────────────────────────────────────────────
    nested_destroy_buffer()
    wls.display_destroy(server.display)
}