package main

import "core:fmt"
import "core:os"
import "core:c"
import "core:strings"
import "core:sys/posix"
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

    // ── 0. Command-line args ──────────────────────────────────────────
    use_drm := false
    log_path := ""  // leer = kein log file
    for arg in os.args {
        if arg == "--drm" || arg == "--standalone" {
            use_drm = true
        } else if arg == "--log" {
            log_path = "/tmp/rift.log"  // default
        } else if strings.has_prefix(arg, "--log=") {
            log_path = arg[6:]  // --log=/path/to/file
        } else if arg == "--help" || arg == "-h" {
            fmt.println("rift — Wayland compositor in Odin")
            fmt.println("")
            fmt.println("Usage:")
            fmt.println("  rift              Nested mode (als Client von Hyprland/Sway)")
            fmt.println("  rift --drm        Standalone DRM/KMS mode (direct to hardware)")
            fmt.println("  rift --log         Log to /tmp/rift.log")
            fmt.println("  rift --log=FILE    Log to FILE")
            fmt.println("  rift --help        Diese Hilfe")
            fmt.println("")
            fmt.println("Im nested mode:")
            fmt.println("  WAYLAND_DISPLAY=rift-0 <app>   App mit rift verbinden")
            return
        }
    }

    // ── 0a. Log-File: stdout + stderr umleiten ──────────────────────────
    if log_path != "" {
        c_path, _ := strings.clone_to_cstring(log_path)
        log_fd := posix.open(c_path, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
        if log_fd >= 0 {
            posix.dup2(log_fd, 1)  // stdout
            posix.dup2(log_fd, 2)  // stderr
            posix.close(log_fd)
            fmt.println("=== rift log started ===")
        }
    }

    // ── 0b. Signal-Handler registrieren (für sauberes Cleanup) ───────────────
    rift_setup_signals()

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

    // ── 4. Backend wählen: DRM (standalone) oder Nested (in Hyprland) ──
    if use_drm {
        // ── DRM/KMS Standalone-Modus ────────────────────────────────
        fmt.println("rift: DRM-Modus (standalone)")
        if !session_init() {
            fmt.eprintln("rift: Session-Init fehlgeschlagen — kann nicht standalone laufen")
            fmt.eprintln("rift: Tipp: Starte von TTY oder SDDM, nicht innerhalb von Hyprland")
            os.exit(1)
        }
        // Phase 3: DRM-Backend (Modesetting + Page Flip)
        if !drm_init() {
            fmt.eprintln("rift: DRM-Backend fehlgeschlagen")
            drm_cleanup()      // Dumb Buffers etc. aufräumen
            session_cleanup()   // Session schliessen
            os.exit(1)
        }
        // Keymap für Clients kompilieren (im Nested-Modus liefert sie der Parent)
        drm_keymap_init()
        // VT auf Grafik-Modus (fbcon weg); Restore bei Exit/Crash → KD_TEXT
        vt_enter_graphics()
        // DRM-fd + libseat/udev/libinput fds in Event-Loop einbinden
        loop := wls.display_get_event_loop(server.display)
        wls.event_loop_add_fd(loop, drm_get_fd(), wls.WL_EVENT_READABLE, drm_dispatch, nil)
        seat_fd := session_get_seat_fd()
        if seat_fd >= 0 {
            wls.event_loop_add_fd(loop, seat_fd, wls.WL_EVENT_READABLE, session_dispatch_seat_cb, nil)
        }
        udev_fd := session_get_udev_fd()
        if udev_fd >= 0 {
            wls.event_loop_add_fd(loop, udev_fd, wls.WL_EVENT_READABLE, session_dispatch_udev_cb, nil)
        }
        li_fd := session_get_libinput_fd()
        if li_fd >= 0 {
            wls.event_loop_add_fd(loop, li_fd, wls.WL_EVENT_READABLE, session_dispatch_libinput_cb, nil)
        }
    } else {
        // ── Nested-Backend: rift wird Client von Hyprland ───────────────
        if !nested_init() {
            fmt.eprintln("rift: Nested-Backend fehlgeschlagen (weiter ohne Fenster)")
        } else {
            // Parent-Client-fd in den Server-Event-Loop hängen → beide Loops
            // in einem (Server für rift-Clients + Client für Hyprland).
            loop := wls.display_get_event_loop(server.display)
            wls.event_loop_add_fd(loop, nested_get_fd(), wls.WL_EVENT_READABLE, nested_dispatch, nil)
        }
    }

    // ── 5. Environment für Kindprozesse ─────────────────────────────────
    // exec-Keybinds und Autostart-Apps sollen sich mit rift verbinden,
    // nicht mit dem Parent-Compositor. Erst NACH nested_init setzen —
    // nested braucht das ursprüngliche WAYLAND_DISPLAY für den Connect.
    posix.setenv("WAYLAND_DISPLAY", "rift-0", true)
    // DISPLAY zeigt auf das XWayland einer parallel laufenden Session
    // (Hyprland) — Chromium/Brave & Co. starten standardmäßig als X11-App
    // und würden ihr Fenster DORT öffnen statt in rift. rift hat kein
    // XWayland → DISPLAY für Kinder entfernen und Wayland klar signalisieren.
    posix.unsetenv("DISPLAY")
    posix.setenv("XDG_SESSION_TYPE", "wayland", true)
    posix.setenv("XDG_CURRENT_DESKTOP", "rift", true)
    posix.setenv("MOZ_ENABLE_WAYLAND", "1", true)               // Firefox → Wayland
    posix.setenv("ELECTRON_OZONE_PLATFORM_HINT", "auto", true)  // Electron-Apps → Wayland

    // ── 5b. Autostart-Befehle ausführen ─────────────────────────────────
    config_run_autostart()

    // ── 6. Event-Loop ──────────────────────────────────────────────────
    fmt.println("═══ rift ready ═══")
    fmt.println("  Socket:   rift-0")
    fmt.println("  Starte Clients mit:  WAYLAND_DISPLAY=rift-0 <app>")
    fmt.println("  Beenden:  kill <pid>  oder  Super+Shift+Q")

    wls.display_run(server.display)

    // ── 7. Cleanup ─────────────────────────────────────────────────────
    if use_drm {
        drm_cleanup()
        session_cleanup()
    } else {
        nested_destroy_buffer()
    }
    wls.display_destroy(server.display)
}

// ─── C-Callback Wrapper für Session-Dispatchers ──────────────────────────────────
// wl_event_loop_add_fd braucht proc "c" callbacks, aber session_dispatch_* sind
// normale Odin-Procs → Wrapper mit Context-Restore.

session_dispatch_seat_cb :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int {
    context = ctx
    session_dispatch_seat()
    return 0
}

session_dispatch_udev_cb :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int {
    context = ctx
    session_dispatch_udev()
    return 0
}

session_dispatch_libinput_cb :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int {
    context = ctx
    session_dispatch_libinput()
    return 0
}