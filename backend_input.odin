package main

import "core:fmt"
import "core:c"
import "base:runtime"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  rift libinput Backend — Keyboard/Pointer direkt vom Kernel
//
//  Diese Datei liest libinput-Events und leitet sie an rift's existierendes
//  Input-System weiter (input_keyboard_key, input_pointer_motion, etc.).
//
//  Im Nested-Modus kommen diese Events von Hyprland via Wayland-Protocol.
//  Im DRM-Modus kommen sie direkt vom Kernel via libinput/evdev.
//
//  Keycode-Mapping:
//    libinput keycodes = Linux evdev keycodes = rift keycodes (keine Konvertierung nötig)
//    BTN_LEFT=272, BTN_RIGHT=273, BTN_MIDDLE=274 (identisch zu Wayland)
//
//  Pointer-Position:
//    libinput liefert RELATIVE Bewegung (dx, dy).
//    rift's input_pointer_motion erwartet ABSOLUTE Koordinaten.
//    → wir akkumulieren dx/dy zu einer absoluten Position.
//    → wir nutzen nested.ptr_x/ptr_y als gemeinsamen Speicher (auch im DRM-Modus).
// ═══════════════════════════════════════════════════════════════════════════

// Input button codes (Linux input.h — identisch zu Wayland)
BTN_LEFT   :: 0x110  // 272
BTN_RIGHT  :: 0x111  // 273
BTN_MIDDLE :: 0x112  // 274

// Wayland axis codes
WL_POINTER_AXIS_VERTICAL_SCROLL   :: 0
WL_POINTER_AXIS_HORIZONTAL_SCROLL :: 1

// ─── Pointer-Position initialisieren (Screen-Center) ───────────────────────────
drm_input_init_pointer :: proc() {
    if g_drm_output != nil {
        nested.ptr_x = f64(g_drm_output.width) / 2.0
        nested.ptr_y = f64(g_drm_output.height) / 2.0
    } else {
        nested.ptr_x = 960.0
        nested.ptr_y = 540.0
    }
    // Im DRM-Modus besitzt rift die Tastatur immer (kein Parent-Compositor,
    // der Fokus vergibt). Ohne dieses Flag würde input_focus_toplevel nie
    // wl_keyboard.enter senden → Clients ignorieren alle Key-Events.
    nested.kb_focused = true
}

// ─── Alle pending libinput-Events verarbeiten ──────────────────────────────────
// Wird aus dem Event-Loop aufgerufen (via session_dispatch_libinput).
drm_input_dispatch :: proc() {
    context = ctx
    if g_session == nil || g_session.libinput == nil do return
    li := g_session.libinput

    // libinput_dispatch muss VOR dem Event-Lesen aufgerufen werden
    libinput_dispatch(li)

    // Alle pending Events lesen und verarbeiten
    for {
        ev := libinput_get_event(li)
        if ev == nil do break  // keine weiteren Events

        ev_type := libinput_event_get_type(ev)

        #partial switch ev_type {
        case .DEVICE_ADDED:
            dev := libinput_event_get_device(ev)
            name := "<unknown>"
            if dev != nil {
                n := libinput_device_get_name(dev)
                if n != nil do name = string(n)
            }
            fmt.printfln("[input] Gerät hinzugefügt: {}", name)

        case .DEVICE_REMOVED:
            dev := libinput_event_get_device(ev)
            name := "<unknown>"
            if dev != nil {
                n := libinput_device_get_name(dev)
                if n != nil do name = string(n)
            }
            fmt.printfln("[input] Gerät entfernt: {}", name)

        case .KEYBOARD_KEY:
            kb_ev := libinput_event_get_keyboard_event(ev)
            if kb_ev != nil {
                key := libinput_event_keyboard_get_key(kb_ev)
                st := libinput_event_keyboard_get_key_state(kb_ev)
                fmt.printfln("[input] KEY: evdev={} state={} xkb={}", key, st, key + 8)
            }
            drm_handle_keyboard_key(ev)

        case .POINTER_MOTION:
            // Kein Log hier — Motion-Events kommen mit bis zu 1000Hz;
            // I/O pro Event macht die Cursor-Bewegung spürbar träge.
            drm_handle_pointer_motion(ev)

        case .POINTER_MOTION_ABSOLUTE:
            drm_handle_pointer_motion_absolute(ev)

        case .POINTER_BUTTON:
            ptr_ev := libinput_event_get_pointer_event(ev)
            if ptr_ev != nil {
                btn := libinput_event_pointer_get_button(ptr_ev)
                st := libinput_event_pointer_get_button_state(ptr_ev)
                fmt.printfln("[input] BUTTON: {} state={}", btn, st)
            }
            drm_handle_pointer_button(ev)

        case .POINTER_AXIS:
            drm_handle_pointer_axis(ev)

        case .POINTER_SCROLL_WHEEL, .POINTER_SCROLL_FINGER, .POINTER_SCROLL_CONTINUOUS:
            drm_handle_pointer_scroll(ev, ev_type)

        case:
            // Ignoriere Touch/Tablet/Gesture Events (später)
        }

        libinput_event_destroy(ev)
    }
}

// ─── Keyboard Key Event ──────────────────────────────────────────────────────────
drm_handle_keyboard_key :: proc(ev: ^LibinputEvent) {
    context = ctx
    kb_ev := libinput_event_get_keyboard_event(ev)
    if kb_ev == nil do return

    key := libinput_event_keyboard_get_key(kb_ev)         // Linux evdev keycode
    state := libinput_event_keyboard_get_key_state(kb_ev)  // PRESSED=1, RELEASED=0
    time_us := libinput_event_keyboard_get_time(kb_ev)    // Mikrosekunden
    time_ms := u32(time_us / 1000)                          // → Millisekunden

    // EVDEV-Keycode unverändert weiterreichen — das ist das Wayland-Wire-
    // Format (Clients rechnen selbst +8 für XKB). Das interne Keybind-
    // Matching macht den +8-Offset in input_keyboard_key.
    input_keyboard_key(time_ms, key, u32(state))
}

// ─── Pointer Relative Motion ───────────────────────────────────────────────────
drm_handle_pointer_motion :: proc(ev: ^LibinputEvent) {
    context = ctx
    ptr_ev := libinput_event_get_pointer_event(ev)
    if ptr_ev == nil do return

    dx := libinput_event_pointer_get_dx(ptr_ev)
    dy := libinput_event_pointer_get_dy(ptr_ev)
    time_us := libinput_event_pointer_get_time(ptr_ev)
    time_ms := u32(time_us / 1000)

    // Relative → Absolute: Position akkumulieren und clampen
    nested.ptr_x += dx
    nested.ptr_y += dy

    // An Bildschirmränder clampen
    if g_drm_output != nil {
        if nested.ptr_x < 0 do nested.ptr_x = 0
        if nested.ptr_y < 0 do nested.ptr_y = 0
        if nested.ptr_x >= f64(g_drm_output.width) do nested.ptr_x = f64(g_drm_output.width - 1)
        if nested.ptr_y >= f64(g_drm_output.height) do nested.ptr_y = f64(g_drm_output.height - 1)
    }

    // An rift's Input-System weiterleiten (mit absoluter Position)
    input_pointer_motion(time_ms, nested.ptr_x, nested.ptr_y)

    // Hardware-Cursor bewegen (ein ioctl, kein Re-Compositing)
    drm_cursor_move(i32(nested.ptr_x), i32(nested.ptr_y))
}

// ─── Pointer Absolute Motion (Tablet/Touchscreen) ──────────────────────────────
drm_handle_pointer_motion_absolute :: proc(ev: ^LibinputEvent) {
    context = ctx
    ptr_ev := libinput_event_get_pointer_event(ev)
    if ptr_ev == nil do return

    ax := libinput_event_pointer_get_absolute_x(ptr_ev)
    ay := libinput_event_pointer_get_absolute_y(ptr_ev)
    time_us := libinput_event_pointer_get_time(ptr_ev)
    time_ms := u32(time_us / 1000)

    // libinput gibt absolute Koordinaten in mm → auf Pixel mappen
    // Für jetzt: direkt verwenden (später mit mm_width/height skalieren)
    nested.ptr_x = ax
    nested.ptr_y = ay

    // An Bildschirmränder clampen
    if g_drm_output != nil {
        if nested.ptr_x < 0 do nested.ptr_x = 0
        if nested.ptr_y < 0 do nested.ptr_y = 0
        if nested.ptr_x >= f64(g_drm_output.width) do nested.ptr_x = f64(g_drm_output.width - 1)
        if nested.ptr_y >= f64(g_drm_output.height) do nested.ptr_y = f64(g_drm_output.height - 1)
    }

    input_pointer_motion(time_ms, nested.ptr_x, nested.ptr_y)

    // Hardware-Cursor bewegen
    drm_cursor_move(i32(nested.ptr_x), i32(nested.ptr_y))
}

// ─── Pointer Button Event ───────────────────────────────────────────────────────
drm_handle_pointer_button :: proc(ev: ^LibinputEvent) {
    context = ctx
    ptr_ev := libinput_event_get_pointer_event(ev)
    if ptr_ev == nil do return

    button := libinput_event_pointer_get_button(ptr_ev)        // Linux button code
    state := libinput_event_pointer_get_button_state(ptr_ev)  // PRESSED=1, RELEASED=0
    time_us := libinput_event_pointer_get_time(ptr_ev)
    time_ms := u32(time_us / 1000)

    // Echte Serial vergeben — Clients (GTK/Firefox) referenzieren Button-
    // Serials bei Folgeaktionen (Popup-Grabs, DnD, interaktives Move/Resize);
    // serial=0 lässt diese Pfade stillschweigend scheitern.
    serial := wls.display_next_serial(g_server.display)

    // An rift's Input-System weiterleiten
    // input_pointer_button nutzt nested.ptr_x/ptr_y für Hit-Testing
    input_pointer_button(serial, time_ms, button, u32(state))
}

// ─── Pointer Axis (Scroll Wheel, Legacy API) ──────────────────────────────────────
drm_handle_pointer_axis :: proc(ev: ^LibinputEvent) {
    context = ctx
    ptr_ev := libinput_event_get_pointer_event(ev)
    if ptr_ev == nil do return

    time_us := libinput_event_pointer_get_time(ptr_ev)
    time_ms := u32(time_us / 1000)

    // Beide Achsen prüfen (vertikal und horizontal)
    v_val := libinput_event_pointer_get_axis_value(ptr_ev, .SCROLL_VERTICAL)
    if v_val != 0.0 {
        input_pointer_axis(time_ms, 0, v_val)  // WL_POINTER_AXIS_VERTICAL_SCROLL
    }
    h_val := libinput_event_pointer_get_axis_value(ptr_ev, .SCROLL_HORIZONTAL)
    if h_val != 0.0 {
        input_pointer_axis(time_ms, 1, h_val)  // WL_POINTER_AXIS_HORIZONTAL_SCROLL
    }

    // Frame-Event senden
    input_pointer_frame()
}

// ─── Pointer Scroll (Neue libinput API: SCROLL_WHEEL/FINGER/CONTINUOUS) ──────────
drm_handle_pointer_scroll :: proc(ev: ^LibinputEvent, ev_type: LibinputEventType) {
    context = ctx
    ptr_ev := libinput_event_get_pointer_event(ev)
    if ptr_ev == nil do return

    time_us := libinput_event_pointer_get_time(ptr_ev)
    time_ms := u32(time_us / 1000)

    // Vertikales und horizontales Scroll verarbeiten
    axes := [2]LibinputPointerAxis{ .SCROLL_VERTICAL, .SCROLL_HORIZONTAL }
    for axis in axes {
        value := libinput_event_pointer_get_axis_value(ptr_ev, axis)
        if value != 0.0 {
            input_pointer_axis(time_ms, u32(axis), value)
        }
    }

    // Frame-Event senden (Wayland Protokoll: nach Axis-Events folgt ein Frame)
    input_pointer_frame()
}