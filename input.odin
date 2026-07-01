package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import wls "./wayland_server"
import wl "./wlclient"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Input-Forwarding (Server-Seite): Keyboard.
//
//  rift-Clients binden wl_keyboard (weil der Seat Capabilities=keyboard
//  meldet). Für jeden Client erzeugen wir eine wl_keyboard-Resource,
//  schicken das Keymap (dup'd fd vom Hyprland-Parent) und reichen
//  Key/Modifiers-Events an das FOKUSSIERTE Fenster weiter.
//
//  Sicherheit: rein passiv. Keine Grabs. Hyprland nicht berührt.
// ═══════════════════════════════════════════════════════════════════════════

WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 :: u32(1)

// Wird aufgerufen, wenn ein rift-Client wl_seat.get_keyboard schickt.
// (Erweitert den bestehenden Handler in server.odin.)
input_seat_get_keyboard :: proc(client: ^wls.wl_client, id: u32, version: c.int) -> ^wls.wl_resource {
    context = ctx
    // Version der Seat-Resource erben — ein v2-Client darf KEINE v4-Events
    // (repeat_info) bekommen, sonst crasht sein libwayland (NULL-Listener-Slot).
    kb := wls.resource_create(client, &wls.keyboard_interface, version, id)
    if kb == nil {
        wls.client_post_no_memory(client)
        return nil
    }
    wls.resource_set_implementation(kb, &keyboard_impl, kb, keyboard_resource_destroy)

    // Keymap vom Hyprland-Parent weiterreichen (frisch dup'd fd pro Client).
    // size-Guard: ohne empfangene Keymap (DRM-Modus, Race beim Start) darf
    // kein fd mit size=0 verschickt werden — Clients mmap'en das und scheitern.
    if nested.kb_keymap_fd >= 0 && nested.kb_keymap_size > 0 {
        fd := posix.dup(posix.FD(nested.kb_keymap_fd))
        if fd >= 0 {
            wls.resource_post_event(kb, wls.WL_KEYBOARD_KEYMAP,
                WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, c.int(fd), nested.kb_keymap_size)
            // libwayland dupliziert den fd beim Marshalling — unser dup muss
            // wieder zu, sonst leakt ein fd pro wl_keyboard-Bind.
            posix.close(fd)
        }
    }
    // Repeat-Info weiterreichen (Event existiert erst ab wl_seat v4).
    if version >= 4 && nested.kb_repeat_rate > 0 {
        wls.resource_post_event(kb, wls.WL_KEYBOARD_REPEAT_INFO,
            c.int(nested.kb_repeat_rate), c.int(nested.kb_repeat_delay))
    }

    append(&g_server.keyboards, kb)
    fmt.println("[input] rift-Client hat wl_keyboard gebunden")
    return kb
}

keyboard_resource_destroy :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    for kb, i in g_server.keyboards {
        if kb == resource {
            ordered_remove(&g_server.keyboards, i)
            break
        }
    }
}

// ─── Hilfsfunktion: Keyboard-Resource des fokussierten Clients finden ───
focused_keyboard :: proc() -> ^wls.wl_resource {
    tl := g_server.focused
    if tl == nil || tl.resource == nil do return nil
    focused_client := wls.resource_get_client(tl.resource)
    for kb in g_server.keyboards {
        if wls.resource_get_client(kb) == focused_client {
            return kb
        }
    }
    return nil
}

// Oberfläche des fokussierten Toplevels als wl_resource (für enter/leave).
focused_surface_resource :: proc() -> ^wls.wl_resource {
    tl := g_server.focused
    if tl == nil || tl.xdg_surface == nil || tl.xdg_surface.surface == nil do return nil
    return tl.xdg_surface.surface.resource
}

// ─── Vom Nested-Backend aufgerufene Forward-Funktionen ──────────────────

// Aktuellen Modifier-Stand an eine Keyboard-Resource schicken (Pflicht nach
// jedem enter — sonst verpasst der Client gehaltene Shift/Ctrl beim Fokuswechsel).
send_modifiers_to :: proc(kb: ^wls.wl_resource) {
    if kb == nil do return
    serial := wls.display_next_serial(g_server.display)
    wls.resource_post_event(kb, wls.WL_KEYBOARD_MODIFIERS, serial,
        g_server.mods_depressed, g_server.mods_latched, g_server.mods_locked, g_server.mods_group)
}

// rift-Fenster hat in Hyprland Fokus bekommen (enter) oder verloren (leave).
// Host-Serials werden NICHT weitergereicht — rift-Clients bekommen Serials aus
// rifts eigenem Nummernraum (sonst scheitern set_cursor/grab-Validierungen).
input_keyboard_focus :: proc(gained: bool, host_serial: u32) {
    context = ctx
    kb := focused_keyboard()
    if kb == nil do return
    surf := focused_surface_resource()
    if surf == nil do return
    serial := wls.display_next_serial(g_server.display)
    if gained {
        empty: wls.wl_array = {}   // keine aktuell gedrückten Keys
        wls.resource_post_event(kb, wls.WL_KEYBOARD_ENTER, serial, surf, &empty)
        send_modifiers_to(kb)
        fmt.println("[input] keyboard enter → fokussiertes rift-Fenster")
    } else {
        wls.resource_post_event(kb, wls.WL_KEYBOARD_LEAVE, serial, surf)
        fmt.println("[input] keyboard leave ← rift-Fenster")
    }
}

// Key-Event weiterreichen + Modifier-Status (zusätzlich zum modifiers-Event)
// via Keycode tracken — robust auch wenn der Parent modifiers-Events
// verzögert.  Wayland-Keycodes = evdev + 8:
//   Super_L/R  evdev 125/126 → wl 133/134   (Mod4 = 0x40)
//   Alt_L/R    evdev  56/100 → wl  64/108   (Mod1 = 0x08)
input_keyboard_key :: proc(time: u32, key: u32, state: u32) {
    context = ctx
    // `key` ist der EVDEV-Keycode (Wayland-Wire-Format — beide Backends).
    // Intern (Keybind-Tabelle, Modifier-Tracking) rechnen wir in X11/XKB-
    // Codes: xkb = evdev + 8. An Clients geht IMMER der evdev-Code raus.
    xkb_key := key + 8
    // Modifier-Tracking — XKB-Keycodes:
    // Shift_L/R:  evdev  42/54  → xkb  50/62   (Mod Shift = 0x01)
    // Ctrl_L/R:   evdev  29/97  → xkb  37/105  (Mod Ctrl  = 0x04)
    // Alt_L/R:    evdev  56/100 → xkb  64/108  (Mod Alt    = 0x08)
    // Super_L/R:  evdev 125/126 → xkb 133/134 (Mod Super  = 0x40)
    old_mods := g_server.mods_depressed
    if state == 1 {
        if xkb_key == 133 || xkb_key == 134 { g_server.mods_depressed |= WM_MOD_SUPER }
        if xkb_key ==  64 || xkb_key == 108 { g_server.mods_depressed |= WM_MOD_ALT   }
        if xkb_key ==  50 || xkb_key ==  62 { g_server.mods_depressed |= WM_MOD_SHIFT }
        if xkb_key ==  37 || xkb_key == 105 { g_server.mods_depressed |= WM_MOD_CTRL  }
    } else {
        if xkb_key == 133 || xkb_key == 134 { g_server.mods_depressed &~= WM_MOD_SUPER }
        if xkb_key ==  64 || xkb_key == 108 { g_server.mods_depressed &~= WM_MOD_ALT   }
        if xkb_key ==  50 || xkb_key ==  62 { g_server.mods_depressed &~= WM_MOD_SHIFT }
        if xkb_key ==  37 || xkb_key == 105 { g_server.mods_depressed &~= WM_MOD_CTRL  }
    }
    // Im DRM-Modus liefert kein Parent modifiers-Events → bei Änderung
    // selbst an den Client schicken (die WM_MOD-Masken entsprechen den
    // XKB-Modifier-Masken der Standard-Keymaps: Shift=1, Ctrl=4, Alt=8, Super=64).
    if g_backend_drm && g_server.mods_depressed != old_mods {
        input_keyboard_modifiers(g_server.mods_depressed, 0, 0, 0)
    }
    wm_held := (g_server.mods_depressed & (WM_MOD_SUPER | WM_MOD_ALT)) != 0
    // ── WM-Tastaturkürzel (Super/Alt + Taste): intercepten, nicht weiterleiten ──
    if wm_held && state == 1 {
        // Config-basierte Keybind-Suche — funktioniert AUCH ohne fokussiertes Fenster
        // (z.B. Super+Shift+Q zum Beenden wenn kein Client verbunden ist)
        idx := config_find_keybind(g_server.mods_depressed, xkb_key)
        if idx >= 0 {
            kb := g_config.keybinds[idx]
            focused := g_server.focused  // kann nil sein — dispatch_action muss das handhaben
            append(&g_server.suppressed_keys, key)  // Release ebenfalls schlucken
            dispatch_action(kb.action, kb.arg, focused)
            return
        }
    }
    // Release einer abgefangenen Keybind-Taste: nicht an den Client leiten —
    // der sähe sonst einen unbalancierten Release ohne vorangegangenen Press.
    if state == 0 {
        for sk, i in g_server.suppressed_keys {
            if sk == key {
                unordered_remove(&g_server.suppressed_keys, i)
                return
            }
        }
    }
    // Layer-Surface mit Tastaturfokus (z.B. rofi) hat Vorrang vor dem Fenster
    if g_layer_kb_focus != nil {
        lkb := layer_keyboard(g_layer_kb_focus)
        if lkb != nil {
            serial := wls.display_next_serial(g_server.display)
            wls.resource_post_event(lkb, wls.WL_KEYBOARD_KEY, serial, time, key, state)
            return
        }
    }
    kb := focused_keyboard()
    if kb == nil do return
    serial := wls.display_next_serial(g_server.display)
    wls.resource_post_event(kb, wls.WL_KEYBOARD_KEY, serial, time, key, state)
}

// Action dispatch: führt eine Config-Keybind-Action aus.
dispatch_action :: proc(action: Action, arg: string, focused: ^XdgToplevel) {
    context = ctx
    #partial switch action {
    case .ToggleFloating:
        if focused != nil do toggle_floating(focused)
    case .SwapNext:
        if focused == nil do return
        idx := -1
        for t, i in g_server.active_ws.toplevels {
            if t == focused { idx = i; break }
        }
        if idx >= 0 && len(g_server.active_ws.toplevels) > 1 {
            nxt := (idx + 1) % len(g_server.active_ws.toplevels)
            target := g_server.active_ws.toplevels[nxt]
            if target != focused {
                tree_swap(focused, target)
                input_focus_toplevel(target)
                layout_toplevels()
                composite_all()
                fmt.printfln("[wm] KEY swap %q ↔ %q", focused.title, target.title)
            }
        }
    case .ResizeH:
        if focused == nil do return
        dh := f64(parse_hex_or_int(arg))
        wm_resize_focused(focused, dh, 0.0)
    case .ResizeV:
        if focused == nil do return
        dv := f64(parse_hex_or_int(arg))
        wm_resize_focused(focused, 0.0, dv)
    case .CloseWindow:
        if focused != nil && focused.resource != nil {
            wls.resource_post_event(focused.resource, wls.XDG_TOPLEVEL_CLOSE)
            fmt.printfln("[wm] close %q", focused.title)
        }
    case .Exec:
        fmt.printfln("[wm] exec %q", arg)
        bg_cmd := fmt.tprintf("{} &", arg)
        cstr, _ := strings.clone_to_cstring(bg_cmd); posix.system(cstr)
    case .Workspace:
        if arg == "+1" {
            workspace_switch_relative(1)
        } else if arg == "-1" {
            workspace_switch_relative(-1)
        } else {
            ws_id := int(parse_hex_or_int(arg))
            workspace_switch(ws_id)
        }
    case .MoveToWorkspace:
        if focused == nil do return
        ws_id := int(parse_hex_or_int(arg))
        workspace_move_window(focused, ws_id, follow=true)
    case .Quit:
        fmt.println("[wm] quit — rift beendet")
        wls.display_terminate(g_server.display)
    case .Unknown: fallthrough
    case:
        fmt.printfln("[wm] unbekannte Action: {}", action)
    }
}

// Keyboard-Resize: Ratio des Eltern-Splits des fokussierten Fensters anpassen.
// dh/dv je nach Split-Orientierung; Vorzeichen hängt davon ab, ob das
// fokussierte Fenster Kind `a` oder `b` ist (wächst vs. schrumpft).
// Im Floating-Modus: float_geom-Größe anpassen.
wm_resize_focused :: proc(tl: ^XdgToplevel, dh, dv: f64) {
    context = ctx
    if tl.floating {
        // Floating: Größe um 5% der Canvas anpassen
        cwi, chi := canvas_size()   // DRM- und Nested-korrekt
        cw := f64(cwi)
        ch := f64(chi)
        tl.float_geom[2] = i32(clamp(f64(tl.float_geom[2]) + dh*cw*0.1, 50, cw))
        tl.float_geom[3] = i32(clamp(f64(tl.float_geom[3]) + dv*ch*0.1, 50, ch))
        toplevel_send_configure(tl)
        composite_all()
        fmt.printfln("[wm] KEY float resize %q → %dx%d", tl.title, tl.float_geom[2], tl.float_geom[3])
        return
    }
    sp := tree_parent_split(tl)
    if sp == nil do return
    leaf := tree_find_leaf(g_server.active_ws.root, tl)
    if leaf == nil do return
    sign := sp.b == leaf ? -1.0 : 1.0
    if sp.horizontal { sp.ratio = clamp(sp.ratio + sign*dh, 0.1, 0.9) }
    else             { sp.ratio = clamp(sp.ratio + sign*dv, 0.1, 0.9) }
    layout_toplevels()
    composite_all()
    fmt.printfln("[wm] KEY resize %q → ratio %.2f (%s)", tl.title, sp.ratio, sp.horizontal ? "h" : "v")
}

// Modifiers-Event weiterreichen + Super/Alt-Status für WM merken.
WM_MOD_SUPER :: u32(0x40)   // Mod4 (Logo/Windows-Taste)
WM_MOD_ALT   :: u32(0x08)   // Mod1 (Alt) — Test-Fallback im Nested-Modus
input_keyboard_modifiers :: proc(depressed, latched, locked, group: u32) {
    context = ctx
    g_server.mods_depressed = depressed
    g_server.mods_latched = latched
    g_server.mods_locked = locked
    g_server.mods_group = group
    // Layer-Surface mit Tastaturfokus bekommt die Modifiers (statt Fenster)
    kb := g_layer_kb_focus != nil ? layer_keyboard(g_layer_kb_focus) : focused_keyboard()
    if kb == nil do return
    serial := wls.display_next_serial(g_server.display)
    wls.resource_post_event(kb, wls.WL_KEYBOARD_MODIFIERS, serial, depressed, latched, locked, group)
}

// ─── Fokus-Wechsel bei Map/Unmap eines Toplevels ───────────────────────
// Neu gemapptes Fenster wird fokussiert. Falls rift gerade Fokus in
// Hyprland hat, senden wir enter an das neue + leave an das alte Fenster.
input_focus_toplevel :: proc(new_tl: ^XdgToplevel) {
    context = ctx
    old := g_server.focused
    g_server.focused = new_tl
    // ACTIVATED-State beider Fenster hat sich geändert → configure nachschieben
    // (Größe bleibt gleich; toplevel_send_configure erkennt die State-Änderung).
    if old != nil && old != new_tl do toplevel_send_configure(old)
    toplevel_send_configure(new_tl)
    if nested.kb_focused {
        // altem Fenster leave, neuem enter schicken
        if old != nil && old != new_tl {
            old_kb := focused_keyboard_for(old)
            old_surf := surface_res_for(old)
            if old_kb != nil && old_surf != nil {
                wls.resource_post_event(old_kb, wls.WL_KEYBOARD_LEAVE, wls.display_next_serial(g_server.display), old_surf)
            }
        }
        kb := focused_keyboard()
        surf := focused_surface_resource()
        if kb != nil && surf != nil {
            empty: wls.wl_array = {}
            wls.resource_post_event(kb, wls.WL_KEYBOARD_ENTER, wls.display_next_serial(g_server.display), surf, &empty)
            send_modifiers_to(kb)
        }
    }
    // Clipboard: dem neuen Fokus-Client die aktuelle Selection anbieten.
    data_device_offer_selection_to_focus()
    fmt.printfln("[input] Fokus → %q", new_tl.title)
}

// Hilfsfunktionen für ein beliebiges Toplevel (für input_focus_toplevel).
focused_keyboard_for :: proc(tl: ^XdgToplevel) -> ^wls.wl_resource {
    if tl == nil || tl.resource == nil do return nil
    c_ := wls.resource_get_client(tl.resource)
    for kb in g_server.keyboards {
        if wls.resource_get_client(kb) == c_ do return kb
    }
    return nil
}
surface_res_for :: proc(tl: ^XdgToplevel) -> ^wls.wl_resource {
    if tl == nil || tl.xdg_surface == nil || tl.xdg_surface.surface == nil do return nil
    return tl.xdg_surface.surface.resource
}

// ═══════════════════════════════════════════════════════════════════════════
//  Pointer-Forwarding + Klick-Fokus
// ═══════════════════════════════════════════════════════════════════════════

// rift-Client hat wl_seat.get_pointer geschickt.
input_seat_get_pointer :: proc(client: ^wls.wl_client, id: u32, version: c.int) -> ^wls.wl_resource {
    context = ctx
    ptr := wls.resource_create(client, &wls.pointer_interface, version, id)
    if ptr == nil { wls.client_post_no_memory(client); return nil }
    wls.resource_set_implementation(ptr, &pointer_impl, ptr, pointer_resource_destroy)
    append(&g_server.pointers, ptr)
    fmt.println("[input] rift-Client hat wl_pointer gebunden")
    return ptr
}

// wl_pointer.frame existiert erst ab v5 — an ältere Clients nie senden
// (libwayland-client crasht bei Events ohne Listener-Slot).
pointer_send_frame :: proc(p: ^wls.wl_resource) {
    if p != nil && wls.resource_get_version(p) >= 5 {
        wls.resource_post_event(p, wls.WL_POINTER_FRAME)
    }
}

pointer_resource_destroy :: proc "c" (resource: ^wls.wl_resource) {
    context = ctx
    for p, i in g_server.pointers {
        if p == resource { ordered_remove(&g_server.pointers, i); break }
    }
}

// wl_pointer-Resource eines bestimmten Toplevels (seines Clients) finden.
pointer_resource_for :: proc(tl: ^XdgToplevel) -> ^wls.wl_resource {
    if tl == nil || tl.resource == nil do return nil
    c_ := wls.resource_get_client(tl.resource)
    for p in g_server.pointers {
        if wls.resource_get_client(p) == c_ do return p
    }
    return nil
}

// wl_pointer-Resource für eine beliebige Surface (Toplevel ODER Popup).
pointer_resource_for_surface :: proc(surf: ^Surface) -> ^wls.wl_resource {
    if surf == nil || surf.resource == nil do return nil
    c_ := wls.resource_get_client(surf.resource)
    for p in g_server.pointers {
        if wls.resource_get_client(p) == c_ do return p
    }
    return nil
}

// Surface unter (x,y): Layer top/overlay zuerst (liegen visuell über allem,
// z.B. rofi), dann Popups (oberste zuerst), dann Floating, dann Tiled,
// zuletzt Layer bottom/background.
// tl = zugehöriges Toplevel (bei Popups: Wurzel der Parent-Kette) für Fokus/WM;
// bei Layer-Surfaces nil (kein Fenster-Fokuswechsel durch Layer-Klicks).
target_at :: proc(x, y: f64, out_sx, out_sy: ^f64) -> (surf: ^Surface, tl: ^XdgToplevel) {
    if ls := layer_surface_at(x, y, 2, 3, out_sx, out_sy); ls != nil {
        return ls, nil
    }
    #reverse for p in g_server.popups {
        if !p.mapped do continue
        xs := p.xdg_surface
        if xs == nil || xs.surface == nil do continue
        ax, ay := popup_abs_pos(p)
        if x >= f64(ax) && x < f64(ax + p.rel[2]) && y >= f64(ay) && y < f64(ay + p.rel[3]) {
            wgx, wgy := i32(0), i32(0)
            if xs.has_win_geom { wgx = xs.win_geom[0]; wgy = xs.win_geom[1] }
            out_sx^ = x - f64(ax) + f64(wgx)
            out_sy^ = y - f64(ay) + f64(wgy)
            return xs.surface, popup_root_toplevel(p)
        }
    }
    t := toplevel_at(x, y, out_sx, out_sy)
    if t != nil && t.xdg_surface != nil do return t.xdg_surface.surface, t
    if ls := layer_surface_at(x, y, 0, 1, out_sx, out_sy); ls != nil {
        return ls, nil
    }
    return nil, nil
}

// Toplevel unter (x,y) finden + surface-lokale Koordinaten.
// Rendering ist 1:1 (kein Skalieren mehr): surface-lokal = Canvas-Koordinate
// minus Tile-Origin plus Window-Geometry-Offset (CSD-Schatten).
// Floating-Fenster werden zuerst geprüft (sie liegen oben auf).
toplevel_at :: proc(x, y: f64, out_sx, out_sy: ^f64) -> ^XdgToplevel {
    // Floating/Fullscreen-Fenster zuerst (oben auf dem Stack)
    for tl in g_server.active_ws.toplevels {
        if !(tl.floating || tl.fullscreen) do continue
        g := toplevel_render_geom(tl)
        if x >= f64(g[0]) && x < f64(g[0]+g[2]) && y >= f64(g[1]) && y < f64(g[1]+g[3]) {
            xs := tl.xdg_surface
            wgx, wgy := i32(0), i32(0)
            if xs != nil && xs.has_win_geom { wgx = xs.win_geom[0]; wgy = xs.win_geom[1] }
            out_sx^ = x - f64(g[0]) + f64(wgx)
            out_sy^ = y - f64(g[1]) + f64(wgy)
            return tl
        }
    }
    // Geteilte Fenster
    for tl in g_server.active_ws.toplevels {
        if tl.floating || tl.fullscreen do continue
        g := tl.geom
        if x >= f64(g[0]) && x < f64(g[0]+g[2]) && y >= f64(g[1]) && y < f64(g[1]+g[3]) {
            xs := tl.xdg_surface
            wgx, wgy := i32(0), i32(0)
            if xs != nil && xs.has_win_geom { wgx = xs.win_geom[0]; wgy = xs.win_geom[1] }
            out_sx^ = x - f64(g[0]) + f64(wgx)
            out_sy^ = y - f64(g[1]) + f64(wgy)
            return tl
        }
    }
    return nil
}

// Pointer-Fokus auf neue Surface setzen (leave alte, enter neue).
pointer_focus_set :: proc(serial: u32, new_surf: ^Surface, sx, sy: f64) {
    context = ctx
    if g_server.ptr_focus == new_surf do return
    // alter Surface leave schicken
    if g_server.ptr_focus != nil {
        old := g_server.ptr_focus
        old_ptr := pointer_resource_for_surface(old)
        if old_ptr != nil && old.resource != nil {
            wls.resource_post_event(old_ptr, wls.WL_POINTER_LEAVE, serial, old.resource)
            pointer_send_frame(old_ptr)
        }
    }
    g_server.ptr_focus = new_surf
    if new_surf != nil {
        p := pointer_resource_for_surface(new_surf)
        if p != nil && new_surf.resource != nil {
            wls.resource_post_event(p, wls.WL_POINTER_ENTER, serial, new_surf.resource,
                wls.fixed_from_double(sx), wls.fixed_from_double(sy))
            pointer_send_frame(p)
        }
    }
}

input_pointer_enter :: proc(gained: bool, host_serial: u32) {
    context = ctx
    // Eigene Serial statt Host-Serial (einheitlicher Nummernraum für Clients).
    serial := wls.display_next_serial(g_server.display)
    if gained {
        sx, sy := 0.0, 0.0
        surf, _ := target_at(nested.ptr_x, nested.ptr_y, &sx, &sy)
        pointer_focus_set(serial, surf, sx, sy)
    } else {
        pointer_focus_set(serial, nil, 0, 0)
    }
}

input_pointer_motion :: proc(time: u32, x, y: f64) {
    context = ctx
    // ── WM-Interaktion läuft? (Super/Alt + Drag) ──
    if g_server.wm_mode == .Move {
        tl := g_server.wm_tl
        if tl != nil && tl.floating {
            // Floating-Move: Fenster folgt dem Cursor (Delta von Startposition)
            dx := i32(x - g_server.wm_start_x)
            dy := i32(y - g_server.wm_start_y)
            tl.float_geom[0] = g_server.wm_start_gx + dx
            tl.float_geom[1] = g_server.wm_start_gy + dy
            composite_all()
        }
        // Geteilte Move: nur Cursor verfolgen; Swap passiert beim Loslassen
        return
    } else if g_server.wm_mode == .Resize {
        tl := g_server.wm_tl
        if tl != nil && tl.floating {
            // Floating-Resize: Größe folgt dem Cursor (Delta von Startgröße)
            dx := i32(x - g_server.wm_start_x)
            dy := i32(y - g_server.wm_start_y)
            tl.float_geom[2] = max(50, g_server.wm_start_gw + dx)
            tl.float_geom[3] = max(50, g_server.wm_start_gh + dy)
            toplevel_send_configure(tl)
            composite_all()
        } else if g_server.wm_split != nil {
            // Geteilte Resize: Split-Ratio ziehen
            sp := g_server.wm_split
            if sp.horizontal {
                sp.ratio = clamp(g_server.wm_start_ratio + (x - g_server.wm_start_x) / f64(sp.rect[2]), 0.1, 0.9)
            } else {
                sp.ratio = clamp(g_server.wm_start_ratio + (y - g_server.wm_start_y) / f64(sp.rect[3]), 0.1, 0.9)
            }
            layout_toplevels()
            composite_all()
        }
        return
    }
    sx, sy := 0.0, 0.0
    surf, _ := target_at(x, y, &sx, &sy)
    if surf != g_server.ptr_focus {
        pointer_focus_set(wls.display_next_serial(g_server.display), surf, sx, sy)
    } else if surf != nil {
        p := pointer_resource_for_surface(surf)
        if p != nil {
            wls.resource_post_event(p, wls.WL_POINTER_MOTION, time,
                wls.fixed_from_double(sx), wls.fixed_from_double(sy))
            pointer_send_frame(p)
        }
    }
}

input_pointer_button :: proc(serial, time, button, state: u32) {
    context = ctx
    wm_held := (g_server.mods_depressed & (WM_MOD_SUPER | WM_MOD_ALT)) != 0
    if wm_held {
        // ── WM-Operationen intercepten (nicht an Client weiterleiten) ──
        if button == 272 {       // BTN_LEFT → Move
            if state == 1 {
                sx, sy := 0.0, 0.0
                tl := toplevel_at(nested.ptr_x, nested.ptr_y, &sx, &sy)
                if tl != nil {
                    g_server.wm_mode = .Move
                    g_server.wm_tl = tl
                    if tl != g_server.focused do input_focus_toplevel(tl)
                    if tl.floating {
                        // Floating-Move: Start-Position sichern
                        g_server.wm_start_gx = tl.float_geom[0]
                        g_server.wm_start_gy = tl.float_geom[1]
                        g_server.wm_start_x = nested.ptr_x
                        g_server.wm_start_y = nested.ptr_y
                        fmt.printfln("[wm] FLOAT MOVE start → %q", tl.title)
                    } else {
                        fmt.printfln("[wm] MOVE start → %q", tl.title)
                    }
                }
            } else {              // released
                if g_server.wm_mode == .Move && g_server.wm_tl != nil {
                    if g_server.wm_tl.floating {
                        // Floating-Move endet: Fenster ist schon an neuer Position
                        fmt.printfln("[wm] FLOAT MOVE end → %q at %d,%d", g_server.wm_tl.title, g_server.wm_tl.float_geom[0], g_server.wm_tl.float_geom[1])
                    } else {
                        // Geteilte Move: Swap mit Fenster unter Cursor
                        sx, sy := 0.0, 0.0
                        target := toplevel_at(nested.ptr_x, nested.ptr_y, &sx, &sy)
                        if target != nil && target != g_server.wm_tl {
                            tree_swap(g_server.wm_tl, target)
                            layout_toplevels()
                            composite_all()
                            fmt.printfln("[wm] MOVE swap %q ↔ %q", g_server.wm_tl.title, target.title)
                        }
                    }
                    g_server.wm_mode = .None
                    g_server.wm_tl = nil
                }
            }
            return
        } else if button == 273 {  // BTN_RIGHT → Resize
            if state == 1 {
                sx, sy := 0.0, 0.0
                tl := toplevel_at(nested.ptr_x, nested.ptr_y, &sx, &sy)
                if tl != nil {
                    if tl.floating {
                        // Floating-Resize: Start-Größe sichern
                        g_server.wm_mode = .Resize
                        g_server.wm_tl = tl
                        g_server.wm_start_gw = tl.float_geom[2]
                        g_server.wm_start_gh = tl.float_geom[3]
                        g_server.wm_start_x = nested.ptr_x
                        g_server.wm_start_y = nested.ptr_y
                        if tl != g_server.focused do input_focus_toplevel(tl)
                        fmt.printfln("[wm] FLOAT RESIZE start → %q (%dx%d)", tl.title, tl.float_geom[2], tl.float_geom[3])
                    } else {
                        // Geteilte Resize: Split-Ratio ziehen
                        sp := tree_parent_split(tl)
                        if sp != nil {
                            g_server.wm_mode = .Resize
                            g_server.wm_tl = tl
                            g_server.wm_split = sp
                            g_server.wm_start_ratio = sp.ratio
                            g_server.wm_start_x = nested.ptr_x
                            g_server.wm_start_y = nested.ptr_y
                            if tl != g_server.focused do input_focus_toplevel(tl)
                            fmt.printfln("[wm] RESIZE start → %q (split %s)", tl.title, sp.horizontal ? "h" : "v")
                        }
                    }
                }
            } else {              // released
                if g_server.wm_mode == .Resize {
                    if g_server.wm_tl != nil && g_server.wm_tl.floating {
                        fmt.printfln("[wm] FLOAT RESIZE end → %q (%dx%d)", g_server.wm_tl.title, g_server.wm_tl.float_geom[2], g_server.wm_tl.float_geom[3])
                    } else if g_server.wm_split != nil {
                        fmt.printfln("[wm] RESIZE end (ratio %.2f)", g_server.wm_split.ratio)
                    }
                    g_server.wm_mode = .None
                    g_server.wm_tl = nil
                    g_server.wm_split = nil
                }
            }
            return
        }
    }
    // ── Normaler Klick (kein WM-Modifier): Dismissal + Fokus + weiterleiten ──
    surf := g_server.ptr_focus
    // Außenklick: offene grabbed Popups schließen, wenn der Klick NICHT auf
    // einem Popup landet (Klick daneben oder ins Leere).
    if state == 1 {
        on_popup := surf != nil && surf.xdg != nil && surf.xdg.popup != nil
        if !on_popup && popup_dismiss_grabbed() {
            composite_all()
        }
    }
    if surf == nil do return
    if state == 1 && surf.xdg != nil && surf.xdg.toplevel != nil && surf.xdg.toplevel != g_server.focused {
        input_focus_toplevel(surf.xdg.toplevel)
    }
    p := pointer_resource_for_surface(surf)
    if p != nil {
        wls.resource_post_event(p, wls.WL_POINTER_BUTTON, serial, time, button, state)
        pointer_send_frame(p)
        if state == 1 do fmt.printfln("[input] click btn %d (mods=0x%x)", button, g_server.mods_depressed)
    }
}

input_pointer_axis :: proc(time, axis: u32, value: f64) {
    surf := g_server.ptr_focus
    if surf == nil do return
    p := pointer_resource_for_surface(surf)
    if p == nil do return
    wls.resource_post_event(p, wls.WL_POINTER_AXIS, time, axis, wls.fixed_from_double(value))
    pointer_send_frame(p)
}

input_pointer_frame :: proc() {
    surf := g_server.ptr_focus
    if surf == nil do return
    p := pointer_resource_for_surface(surf)
    if p != nil do pointer_send_frame(p)
}

// ═══════════════════════════════════════════════════════════════════════════
//  Floating-Modus: Tiled ↔ Floating umschalten.
//  Super+Space schaltet das fokussierte Fenster um.
// ═══════════════════════════════════════════════════════════════════════════

toggle_floating :: proc(tl: ^XdgToplevel) {
    context = ctx
    tl.floating = !tl.floating
    if tl.floating {
        // Aus Tiling-Baum entfernen, Default-Geometrie: aktuelle Position beibehalten,
        // Größe = aktuelle geom (falls vorhanden) oder 800x600.
        tree_remove(tl)
        w, h := tl.geom[2], tl.geom[3]
        if w <= 0 do w = 800
        if h <= 0 do h = 600
        // Zentrieren auf Canvas (oder aktuelle Position falls sinnvoll)
        cw, ch := canvas_size()   // DRM- und Nested-korrekt
        x := tl.geom[0]; y := tl.geom[1]
        if x < 0 || x + w > i32(cw) do x = i32(cw - int(w)) / 2
        if y < 0 || y + h > i32(ch) do y = i32(ch - int(h)) / 2
        tl.float_geom = {x, y, w, h}
        fmt.printfln("[wm] FLOAT ON → %q (%d,%d %dx%d)", tl.title, x, y, w, h)
    } else {
        // Zurück in den Tiling-Baum
        tree_add(tl)
        fmt.printfln("[wm] FLOAT OFF → %q (tiled)", tl.title)
    }
    layout_toplevels()
    composite_all()
}