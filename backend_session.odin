package main

import "core:fmt"
import "core:sys/posix"
import "base:runtime"
import "core:c"
import "core:strings"


// ═══════════════════════════════════════════════════════════════════════════
//  rift Session Management (libseat + udev + libinput)
//
//  Diese Datei implementiert die "Session" — den Zugang zur Hardware:
//    1. libseat öffnet den Seat (VT, DRM-Master, Input-Devices)
//    2. udev findet DRM-Karten und überwacht Hotplug
//    3. libinput verarbeitet Keyboard/Pointer-Events (nutzt libseat zum Öffnen)
//
//  Im Nested-Modus wird diese Datei NICHT verwendet — stattdessen verbindet
//  sich rift als Wayland-Client zu Hyprland (nested.odin).
//
//  Im Standalone-Modus (DRM-Backend) ist diese Datei der erste Schritt:
//    session_init() → DRM-Master → Modesetting → Page-Flip → Compositing
// ═══════════════════════════════════════════════════════════════════════════

// ─── Session State ──────────────────────────────────────────────────────────────
Session :: struct {
    // libseat
    seat:           ^Libseat,
    seat_name:      string,
    active:         bool,              // Seat aktiv (VT sichtbar)?
    direct:         bool,              // true = direkter Zugriff (kein libseat)

    // udev
    udev:           ^Udev,
    udev_monitor:   ^UdevMonitor,

    // libinput
    libinput:       ^Libinput,

    // DRM
    drm_fd:         c.int,             // DRM device fd (-1 = not opened)
    drm_device_id:  c.int,             // libseat device ID
    drm_path:       string,            // /dev/dri/card0

    // Event sources (für wl_event_loop_add_fd)
    seat_source:    rawptr,            // ^wl_event_source
    udev_source:    rawptr,
    libinput_source: rawptr,
}

g_session: ^Session = nil  // globale Session (im DRM-Modus gesetzt)

// ─── libseat Callbacks ────────────────────────────────────────────────────────
// Diese werden von libseat aufgerufen:
//   enable_seat  → VT ist aktiv, rift darf Hardware nutzen
//   disable_seat → VT-Switch weg, rift muss Hardware freigeben

session_enable_seat :: proc "c" (seat: ^Libseat, userdata: rawptr) {
    context = ctx  // Odin-Context restaurieren (C-Callback!)
    s := g_session
    if s == nil do return
    if s.direct do return  // Direct-Mode: keine VT-Switch-Handling
    s.active = true
    fmt.println("[session] seat aktiviert — rift darf Hardware nutzen")

    // libinput wieder aufnehmen (Geräte wurden beim disable geschlossen)
    if s.libinput != nil {
        if libinput_resume(s.libinput) != 0 {
            fmt.eprintln("[session] WARNUNG: libinput_resume fehlgeschlagen")
        } else {
            fmt.println("[session] libinput resumed")
        }
    }

    // DRM-Master erwerben
    if s.drm_fd >= 0 {
        if drmSetMaster(s.drm_fd) == 0 {
            fmt.println("[session] DRM-Master erworben")
            // VT-Switch Restore: Display neu modesetten
            if g_backend_drm {
                drm_restore_after_vt()
            }
        } else {
            fmt.eprintln("[session] WARNUNG: DRM-Master nicht erhalten (drmSetMaster failed)")
        }
    }
}

session_disable_seat :: proc "c" (seat: ^Libseat, userdata: rawptr) {
    context = ctx  // Odin-Context restaurieren
    s := g_session
    if s == nil do return
    if s.direct do return  // Direct-Mode: keine VT-Switch-Handling
    s.active = false
    fmt.println("[session] seat deaktiviert (VT-Switch) — gebe Hardware frei")

    // DRM-Master abgeben
    if s.drm_fd >= 0 {
        drmDropMaster(s.drm_fd)
    }

    // libinput pausieren — schließt alle Input-fds (der andere VT braucht sie)
    if s.libinput != nil {
        libinput_suspend(s.libinput)
        fmt.println("[session] libinput suspended")
    }

    // libseat muss acknowledged werden!
    libseat_disable_seat(s.seat)
}

// ─── libinput Callbacks (öffnen/schliessen von Input-Devices via libseat) ─────
// libinput ruft open_restricted auf, wenn es ein /dev/input/eventN öffnen will.
// Wir nutzen libseat_open_device dafür, damit die Permissions stimmen.

session_libinput_open :: proc "c" (path: cstring, flags: c.int, userdata: rawptr) -> c.int {
    context = ctx
    s := g_session
    if s == nil do return -1

    if s.direct {
        // Direct mode: open() ohne libseat — ABER mit NONBLOCK + CLOEXEC
        // libinput braucht O_NONBLOCK sonst blockieren manche Input-Geräte
        fd := posix.open(path, {.RDWR, .NONBLOCK, .CLOEXEC})
        if fd < 0 do return -1
        fmt.printfln("[session] libinput open (direct): {} → fd={}", string(path), fd)
        return c.int(fd)
    }

    // libseat mode
    if s.seat == nil do return -1
    fd: c.int = -1
    dev_id := libseat_open_device(s.seat, path, &fd)
    if dev_id < 0 || fd < 0 do return -1
    append(&g_seat_devices, SeatDevice{fd = fd, dev_id = dev_id})
    fmt.printfln("[session] libinput open (libseat): {} → fd={}", string(path), fd)
    return fd
}

// fd → libseat-device_id, damit close_restricted das Gerät über libseat
// schließen kann (sonst hält libseat die Devices bis zum Prozess-Ende).
SeatDevice :: struct { fd: c.int, dev_id: c.int }
g_seat_devices: [dynamic]SeatDevice

session_libinput_close :: proc "c" (fd: c.int, userdata: rawptr) {
    context = ctx
    s := g_session
    if s == nil do return
    if s.direct {
        posix.close(posix.FD(fd))
        return
    }
    for dev, i in g_seat_devices {
        if dev.fd == fd {
            if s.seat != nil do libseat_close_device(s.seat, dev.dev_id)
            unordered_remove(&g_seat_devices, i)
            return
        }
    }
    // unbekannter fd (sollte nicht passieren) — wenigstens schließen
    posix.close(posix.FD(fd))
}

// ─── Session initialisieren ──────────────────────────────────────────────────
// Ruft die ganze Kette auf: libseat → udev → libinput → DRM-Device finden
session_init :: proc() -> bool {
    context = ctx
    s := new(Session)
    s.drm_fd = -1
    s.drm_device_id = -1
    s.active = false
    s.direct = false
    g_session = s

    // ── 1. libseat: Seat öffnen ──────────────────────────────────────────────
    listener := LibseatSeatListener{
        enable_seat  = session_enable_seat,
        disable_seat = session_disable_seat,
    }
    s.seat = libseat_open_seat(&listener, nil)
    if s.seat == nil {
        fmt.println("[session] libseat nicht verfügbar — versuche direkten Zugriff")
        // Fallback: direkter Zugriff ohne libseat (für Testing/Entwicklung)
        if !session_init_direct(s) {
            fmt.eprintln("[session] FEHLER: Auch direkter Zugriff fehlgeschlagen")
            fmt.eprintln("[session] Ist libseat installiert? Bist du in der 'seat' Gruppe?")
            fmt.eprintln("[session] Oder: Bist du in der 'video' Gruppe für direkten Zugriff?")
            return false
        }
        return true
    }

    // Pending events dispatchen (enable_seat könnte sofort feuern)
    libseat_dispatch(s.seat, 0)

    seat_name_c := libseat_seat_name(s.seat)
    if seat_name_c != nil {
        s.seat_name = string(seat_name_c)
    } else {
        s.seat_name = "seat0"
    }
    fmt.printfln("[session] seat geöffnet: {}", s.seat_name)

    // ── 2. udev: Context + Monitor für Hotplug ───────────────────────────────
    s.udev = udev_new()
    if s.udev == nil {
        fmt.eprintln("[session] FEHLER: udev_new() fehlgeschlagen")
        session_cleanup()
        return false
    }

    s.udev_monitor = udev_monitor_new_from_netlink(s.udev, "udev")
    if s.udev_monitor == nil {
        fmt.eprintln("[session] FEHLER: udev_monitor_new_from_netlink() fehlgeschlagen")
        session_cleanup()
        return false
    }
    // Nur DRM-Events filtern (Connector-Hotplug)
    udev_monitor_filter_add_match_subsystem_devtype(s.udev_monitor, "drm", nil)
    udev_monitor_enable_receiving(s.udev_monitor)

    // ── 3. libinput: Context für Keyboard/Pointer ────────────────────────────
    li_iface := LibinputInterface{
        open_restricted  = session_libinput_open,
        close_restricted = session_libinput_close,
    }
    s.libinput = libinput_udev_create_context(&li_iface, .ERROR, s.udev)
    if s.libinput == nil {
        fmt.eprintln("[session] FEHLER: libinput_udev_create_context() fehlgeschlagen")
        session_cleanup()
        return false
    }

    if libinput_udev_assign_seat(s.libinput, strings.clone_to_cstring(s.seat_name)) != 0 {
        fmt.eprintln("[session] FEHLER: libinput_udev_assign_seat() fehlgeschlagen")
        session_cleanup()
        return false
    }
    fmt.println("[session] libinput context erstellt + seat zugewiesen")

    // ── 4. DRM-Device finden und öffnen ───────────────────────────────────────
    if !session_find_drm_device(s) {
        fmt.eprintln("[session] FEHLER: Keine DRM-Karte gefunden")
        session_cleanup()
        return false
    }

    fmt.printfln("[session] ✅ Session bereit (seat={}, drm_fd={}, drm={})",
        s.seat_name, s.drm_fd, s.drm_path)
    return true
}

// ─── Direct-Access Fallback (ohne libseat) ──────────────────────────────────────
// Opens DRM and input devices directly via open(). No VT switch handling.
// Used when libseat/seatd is not available (development/testing).
session_init_direct :: proc(s: ^Session) -> bool {
    context = ctx
    s.direct = true
    s.active = true
    s.seat_name = "seat0"
    fmt.println("[session] Direct-Mode: öffne Geräte ohne libseat")

    // udev Context (für libinput und Device-Discovery)
    s.udev = udev_new()
    if s.udev == nil {
        fmt.eprintln("[session] FEHLER: udev_new() fehlgeschlagen")
        return false
    }

    // udev Monitor für Hotplug
    s.udev_monitor = udev_monitor_new_from_netlink(s.udev, "udev")
    if s.udev_monitor != nil {
        udev_monitor_filter_add_match_subsystem_devtype(s.udev_monitor, "drm", nil)
        udev_monitor_enable_receiving(s.udev_monitor)
    }

    // DRM-Device finden und direkt öffnen (VOR libinput, da assign_seat blockieren kann)
    fmt.println("[session] direct: suche DRM-Device...")
    if !session_find_drm_device_direct(s) {
        fmt.eprintln("[session] FEHLER: Keine DRM-Karte gefunden (direct mode)")
        return false
    }

    // libinput Context (nach DRM, damit Modeset nicht blockiert wird)
    // O_NONBLOCK im open-Callback verhindert dass assign_seat blockiert
    li_iface := LibinputInterface{
        open_restricted  = session_libinput_open,
        close_restricted = session_libinput_close,
    }
    s.libinput = libinput_udev_create_context(&li_iface, .ERROR, s.udev)
    if s.libinput == nil {
        fmt.eprintln("[session] WARNUNG: libinput nicht verfügbar — kein Input")
    } else {
        seat_c := strings.clone_to_cstring(s.seat_name)
        fmt.println("[session] direct: weise seat zu...")
        if libinput_udev_assign_seat(s.libinput, seat_c) != 0 {
            fmt.eprintln("[session] WARNUNG: libinput_udev_assign_seat fehlgeschlagen — kein Input")
    fmt.println("[session] cleanup: libinput...")
            libinput_unref(s.libinput)
            s.libinput = nil
        } else {
            fmt.println("[session] libinput context erstellt (direct mode)")
        }
    }

    fmt.printfln("[session] ✅ Direct-Session bereit (drm_fd={}, drm={})",
        s.drm_fd, s.drm_path)
    return true
}

// ─── DRM-Device direkt öffnen (ohne libseat) ───────────────────────────────────
session_find_drm_device_direct :: proc(s: ^Session) -> bool {
    context = ctx

    enumerate := udev_enumerate_new(s.udev)
    if enumerate == nil do return false
    defer udev_enumerate_unref(enumerate)

    udev_enumerate_add_match_subsystem(enumerate, "drm")
    udev_enumerate_add_match_sysname(enumerate, "card[0-9]*")
    udev_enumerate_add_match_property(enumerate, "DEVTYPE", "drm_minor")
    if udev_enumerate_scan_devices(enumerate) != 0 do return false

    entry := udev_enumerate_get_list_entry(enumerate)
    for entry != nil {
        syspath := udev_list_entry_get_name(entry)
        if syspath == nil { entry = udev_list_entry_get_next(entry); continue }
        device := udev_device_new_from_syspath(s.udev, syspath)
        if device == nil { entry = udev_list_entry_get_next(entry); continue }
        devnode := udev_device_get_devnode(device)
        if devnode == nil {
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }

        // Direkt öffnen mit posix.open
        path_c := strings.clone_to_cstring(string(devnode))
        fd := posix.open(path_c, {.RDWR})
        if fd < 0 {
            fmt.printfln("[session] kann {} nicht öffnen", string(devnode))
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }
        fd_int := c.int(fd)

        // KMS-Check
        if drmIsKMS(fd_int) == 0 {
            fmt.printfln("[session] {} ist kein KMS-Device", string(devnode))
            posix.close(fd)
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }

        // boot_vga Check (primäre GPU bevorzugen)
        pci := udev_device_get_parent_with_subsystem_devtype(device, "pci", nil)
        boot_vga := false
        if pci != nil {
            id := udev_device_get_sysattr_value(pci, "boot_vga")
            if id != nil && string(id) == "1" do boot_vga = true
        }

        s.drm_fd = fd_int
        s.drm_path = string(devnode)
        udev_device_unref(device)

        fmt.printfln("[session] DRM-Device direkt geöffnet: {} (fd={}, boot_vga={})",
            s.drm_path, s.drm_fd, boot_vga)

        // DRM-Master
        if drmSetMaster(s.drm_fd) != 0 {
            fmt.eprintln("[session] WARNUNG: drmSetMaster fehlgeschlagen im direct mode")
        }

        // Capabilities
        cap: u64 = 0
        if drmGetCap(s.drm_fd, DRM_CAP_DUMB_BUFFER, &cap) == 0 && cap != 0 {
            fmt.println("[session] DRM_CAP_DUMB_BUFFER: ✅")
        } else {
            fmt.eprintln("[session] FEHLER: DUMB_BUFFER nicht unterstützt")
            return false
        }
        drmSetClientCap(s.drm_fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)
        // drmSetClientCap(s.drm_fd, DRM_CLIENT_CAP_ATOMIC, 1)  — Legacy mode, kein Atomic
        return true
    }
    return false
}

// ─── DRM-Device via udev finden ─────────────────────────────────────────────────
session_find_drm_device :: proc(s: ^Session) -> bool {
    context = ctx

    // udev: DRM-Karten enumerieren
    enumerate := udev_enumerate_new(s.udev)
    if enumerate == nil do return false
    defer udev_enumerate_unref(enumerate)

    udev_enumerate_add_match_subsystem(enumerate, "drm")
    udev_enumerate_add_match_sysname(enumerate, "card[0-9]*")
    udev_enumerate_add_match_property(enumerate, "DEVTYPE", "drm_minor")
    if udev_enumerate_scan_devices(enumerate) != 0 {
        fmt.eprintln("[session] udev: scan_devices fehlgeschlagen")
        return false
    }

    entry := udev_enumerate_get_list_entry(enumerate)
    best_device: ^UdevDevice = nil
    is_boot_vga: bool = false

    for entry != nil {
        syspath := udev_list_entry_get_name(entry)
        if syspath == nil { entry = udev_list_entry_get_next(entry); continue }

        device := udev_device_new_from_syspath(s.udev, syspath)
        if device == nil { entry = udev_list_entry_get_next(entry); continue }

        devnode := udev_device_get_devnode(device)
        if devnode == nil {
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }

        // Prüfen ob Boot-VGA (primäre GPU)
        pci := udev_device_get_parent_with_subsystem_devtype(device, "pci", nil)
        boot_vga := false
        if pci != nil {
            id := udev_device_get_sysattr_value(pci, "boot_vga")
            if id != nil && string(id) == "1" {
                boot_vga = true
            }
        }

        // Device via libseat öffnen
        fd: c.int = -1
        dev_id := libseat_open_device(s.seat, devnode, &fd)
        if dev_id < 0 || fd < 0 {
            fmt.printfln("[session] udev: kann {} nicht öffnen", string(devnode))
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }

        // Ist es ein KMS-Device?
        if drmIsKMS(fd) == 0 {
            fmt.printfln("[session] udev: {} ist kein KMS-Device", string(devnode))
            libseat_close_device(s.seat, dev_id)
            udev_device_unref(device)
            entry = udev_list_entry_get_next(entry)
            continue
        }

        if boot_vga || best_device == nil {
            // Bessere Wahl (boot_vga hat Vorrang)
            if best_device != nil {
                // Altes Device schliessen
                libseat_close_device(s.seat, s.drm_device_id)
                udev_device_unref(best_device)
            }
            best_device = device
            is_boot_vga = boot_vga
            s.drm_fd = fd
            s.drm_device_id = dev_id
            s.drm_path = string(devnode)
        } else {
            libseat_close_device(s.seat, dev_id)
            udev_device_unref(device)
        }

        entry = udev_list_entry_get_next(entry)
    }

    if best_device != nil {
        udev_device_unref(best_device)
    }

    if s.drm_fd < 0 {
        return false
    }

    fmt.printfln("[session] DRM-Device gefunden: {} (fd={}, boot_vga={})",
        s.drm_path, s.drm_fd, is_boot_vga)

    // DRM-Master erwerben
    if drmSetMaster(s.drm_fd) != 0 {
        fmt.eprintln("[session] WARNUNG: drmSetMaster() fehlgeschlagen — versuche trotzdem")
    }

    // Capabilities prüfen
    cap: u64 = 0
    if drmGetCap(s.drm_fd, DRM_CAP_DUMB_BUFFER, &cap) == 0 && cap != 0 {
        fmt.println("[session] DRM_CAP_DUMB_BUFFER: unterstützt ✅")
    } else {
        fmt.eprintln("[session] FEHLER: DRM_CAP_DUMB_BUFFER nicht unterstützt")
        return false
    }

    if drmGetCap(s.drm_fd, DRM_CAP_CRTC_IN_VBLANK_EVENT, &cap) == 0 && cap != 0 {
        fmt.println("[session] DRM_CAP_CRTC_IN_VBLANK_EVENT: unterstützt ✅")
    } else {
        fmt.eprintln("[session] WARNUNG: DRM_CAP_CRTC_IN_VBLANK_EVENT nicht unterstützt")
    }

    // Universal Planes aktivieren
    drmSetClientCap(s.drm_fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)

    // Atomic Modesetting NICHT aktivieren — wir nutzen Legacy API
    // (drmModeSetCrtc, drmModePageFlip, drmModeSetCursor)
    // Atomic kann Legacy-Cursor auf manchen Treibern (amdgpu) stillschalten

    return true
}

// ─── Event-Dispatch: libseat events verarbeiten ──────────────────────────────
session_dispatch_seat :: proc() {
    if g_session == nil do return
    if g_session.direct do return  // Direct-Mode: kein libseat
    if g_session.seat == nil do return
    libseat_dispatch(g_session.seat, 0)
}

// ─── Event-Dispatch: udev hotplug events ───────────────────────────────────────
session_dispatch_udev :: proc() {
    if g_session == nil || g_session.udev_monitor == nil do return
    device := udev_monitor_receive_device(g_session.udev_monitor)
    if device == nil do return
    defer udev_device_unref(device)

    action := udev_device_get_action(device)
    if action == nil do return
    action_s := string(action)

    if action_s == "add" || action_s == "change" || action_s == "remove" {
        sysname := udev_device_get_sysname(device)
        devnode := udev_device_get_devnode(device)
        fmt.printfln("[session] udev hotplug: {} {} ({})",
            action_s,
            sysname != nil ? string(sysname) : "?",
            devnode != nil ? string(devnode) : "?")
        // TODO: Connector rescan auslösen (Phase 3)
    }
}

// ─── Event-Dispatch: libinput events ──────────────────────────────────────────
session_dispatch_libinput :: proc() {
    if g_session == nil || g_session.libinput == nil do return
    drm_input_dispatch()
}

// ─── FDs für Event-Loop ───────────────────────────────────────────────────────
session_get_seat_fd :: proc() -> c.int {
    if g_session == nil do return -1
    if g_session.direct do return -1  // Direct-Mode: kein libseat fd
    if g_session.seat == nil do return -1
    return libseat_get_fd(g_session.seat)
}

session_get_udev_fd :: proc() -> c.int {
    if g_session == nil || g_session.udev_monitor == nil do return -1
    return udev_monitor_get_fd(g_session.udev_monitor)
}

session_get_libinput_fd :: proc() -> c.int {
    if g_session == nil || g_session.libinput == nil do return -1
    return libinput_get_fd(g_session.libinput)
}

// ─── Cleanup ────────────────────────────────────────────────────────────────────
session_cleanup :: proc() {
    context = ctx
    s := g_session
    if s == nil do return

    fmt.println("[session] cleanup...")
    fmt.println("[session] cleanup: DRM-Master abgeben...")

    // DRM-Master abgeben
    if s.drm_fd >= 0 {
        drmDropMaster(s.drm_fd)
        if s.direct {
            // Direct mode: fd direkt schliessen
            posix.close(posix.FD(s.drm_fd))
        } else if s.seat != nil {
            libseat_close_device(s.seat, s.drm_device_id)
        }
        s.drm_fd = -1
    }

    // libinput — skip unref (segfaults during cleanup, OS reclaims fds)
    fmt.println("[session] cleanup: libinput...")
    s.libinput = nil

    // udev
    if s.udev_monitor != nil {
    fmt.println("[session] cleanup: udev...")
        udev_monitor_unref(s.udev_monitor)
        s.udev_monitor = nil
    }
    if s.udev != nil {
        udev_unref(s.udev)
        s.udev = nil
    }

    // libseat
    if !s.direct && s.seat != nil {
    fmt.println("[session] cleanup: libseat...")
        libseat_close_seat(s.seat)
        s.seat = nil
    }

    fmt.println("[session] cleanup: free...")
    g_session = nil  // ← VOR free() auf nil setzen (Signal-Handler Sicherheit)
    free(s, context.allocator)
    fmt.println("[session] cleanup done")
}