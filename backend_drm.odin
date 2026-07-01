package main

import "core:fmt"
import "core:c"
import "core:strings"
import "core:sys/linux"
import "base:runtime"
import wls "./wayland_server"

// ═══════════════════════════════════════════════════════════════════════════
//  rift DRM/KMS Backend — Standalone Compositing direkt auf Hardware
//
//  Diese Datei implementiert den DRM-Backend: rift spricht direkt mit dem
//  Kernel (via libdrm), ohne Hyprland als Zwischenhändler.
//
//  Pipeline:
//    1. KMS-Ressourcen enumerieren (Connectors, CRTCs, Planes)
//    2. Verbundenen Connector finden + Mode wählen
//    3. CRTC zum Connector zuweisen
//    4. Dumb Buffer (double-buffered) erstellen → mmap für CPU-Compositing
//    5. Initial Modeset (drmModeSetCrtc oder atomic)
//    6. Compositing: clear + blit → back buffer
//    7. Page Flip: back buffer → scanout (VSync via DRM_MODE_PAGE_FLIP_EVENT)
//    8. Page-Flip-Event: front/back swapen → nächsten Frame rendern
//
//  Voraussetzung: session_init() muss erfolgreich gewesen sein (DRM-Master).
// ═══════════════════════════════════════════════════════════════════════════

g_backend_drm: bool = false  // true = DRM backend aktiv, false = nested

// ─── DRM Output (pro Connector) ────────────────────────────────────────────────
DrmOutput :: struct {
    // KMS IDs
    connector_id:  u32,
    crtc_id:       u32,
    plane_id:      u32,       // primary plane

    // Mode
    mode:          DrmModeInfo,
    width:         u32,
    height:        u32,
    refresh:       u32,      // Hz

    // Dumb Buffer (double-buffered)
    fb:            [2]u32,   // DRM framebuffer IDs [front, back]
    handle:        [2]u32,   // GEM handles
    pitch:         [2]u32,   // bytes per row
    size:          [2]u64,   // total buffer size
    pixels:        [2]rawptr, // mmap'd pixel data
    map_offset:   [2]u64,   // mmap offset from DRM_IOCTL_MODE_MAP_DUMB

    // State
    back:          u32,      // index of back buffer (0 or 1)
    page_flip_pending: bool, // true während page flip läuft
    needs_frame:   bool,     // true wenn ein neuer Frame gerendert werden muss
}

g_drm_output: ^DrmOutput = nil

// Beim Init gesicherter CRTC-Zustand (vor unserem ersten Modeset) — wird bei
// Exit UND im Signal-Handler restauriert. Vorab gespeichert, weil im
// Signal-Handler nichts alloziert werden darf.
g_saved_crtc: ^DrmModeCrtc = nil

// CRTC auf den beim Start gesicherten Zustand zurücksetzen (fbcon/Text-Konsole).
// Signal-Handler-sicher: nur ioctls, keine Allokation, kein fmt.
drm_restore_saved_crtc :: proc "contextless" () {
    if g_session == nil || g_session.drm_fd < 0 || g_drm_output == nil do return
    fd := g_session.drm_fd
    conn_id := g_drm_output.connector_id
    if g_saved_crtc != nil && g_saved_crtc.mode_valid != 0 {
        drmModeSetCrtc(fd, g_saved_crtc.crtc_id, g_saved_crtc.buffer_id,
            g_saved_crtc.x, g_saved_crtc.y, &conn_id, 1, &g_saved_crtc.mode)
    } else {
        // Kein brauchbarer Vorzustand (TTY hatte z. B. keinen FB) → CRTC aus.
        drmModeSetCrtc(fd, g_drm_output.crtc_id, 0, 0, 0, &conn_id, 0, nil)
    }
}

// ─── Page-Flip Handler (C Callback) ───────────────────────────────────────────
// Wird von drmHandleEvent() aufgerufen wenn ein Page Flip abgeschlossen ist (VBlank).
drm_page_flip_handler :: proc "c" (
    fd:       c.int,
    sequence: c.uint,
    tv_sec:   c.uint,
    tv_usec:  c.uint,
    crtc_id:  c.uint,
    user_data: rawptr,
) {
    context = ctx  // Odin-Context restaurieren (C-Callback!)
    if g_drm_output == nil do return
    g_drm_output.page_flip_pending = false
    drm_watchdog_arm(0)   // Flip kam an → Watchdog entschärfen
    // Front und Back swapen — der ehemalige Back ist jetzt Front (wird gescannt)
    g_drm_output.back = 1 - g_drm_output.back
    // Frame wurde präsentiert → Frame-Callbacks der Clients feuern (throttlet
    // sie auf die Monitor-Rate; Event-Zeit statt Wallclock).
    ms := u32(tv_sec) * 1000 + u32(tv_usec) / 1000
    frame_cbs_fire_pending(ms)
    // Nächsten Frame rendern falls nötig
    if g_drm_output.needs_frame {
        g_drm_output.needs_frame = false
        composite_all()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  DRM Backend Init
// ═══════════════════════════════════════════════════════════════════════════

drm_init :: proc() -> bool {
    context = ctx
    if g_session == nil || g_session.drm_fd < 0 {
        fmt.eprintln("[drm] FEHLER: Keine Session/DRM-fd — session_init() zuerst!")
        return false
    }
    fd := g_session.drm_fd

    // ── 1. KMS-Ressourcen enumerieren ────────────────────────────────────────
    res := drmModeGetResources(fd)
    if res == nil {
        fmt.eprintln("[drm] FEHLER: drmModeGetResources() fehlgeschlagen")
        return false
    }
    defer drmModeFreeResources(res)

    fmt.printfln("[drm] {} CRTCs, {} Connectors, {} Encoder gefunden",
        res.count_crtcs, res.count_connectors, res.count_encoders)

    // ── 2. Verbundenen Connector finden ──────────────────────────────────────
    out := new(DrmOutput)
    g_drm_output = out

    best_mode: DrmModeInfo
    found_connector := false
    best_connector_id: u32 = 0
    best_crtc_id: u32 = 0
    best_crtc_index: i32 = -1

    conn_ids := cast([^]u32)(res.connectors)
    for ci in 0..<res.count_connectors {
        conn := drmModeGetConnector(fd, conn_ids[ci])
        if conn == nil do continue
        defer drmModeFreeConnector(conn)

        if conn.connection != DRM_MODE_CONNECTED {
            fmt.printfln("[drm] Connector {} nicht verbunden", conn.connector_id)
            continue
        }
        if conn.count_modes == 0 {
            fmt.printfln("[drm] Connector {} hat keine Modes", conn.connector_id)
            continue
        }

        // Connector-Typ für Name
        conn_type := "Unknown"
        switch conn.connector_type {
        case DRM_MODE_CONNECTOR_HDMIA: conn_type = "HDMI-A"
        case DRM_MODE_CONNECTOR_HDMIB: conn_type = "HDMI-B"
        case DRM_MODE_CONNECTOR_DisplayPort: conn_type = "DP"
        case DRM_MODE_CONNECTOR_eDP: conn_type = "eDP"
        case DRM_MODE_CONNECTOR_VGA: conn_type = "VGA"
        case DRM_MODE_CONNECTOR_DVII: conn_type = "DVI-I"
        case DRM_MODE_CONNECTOR_DVID: conn_type = "DVI-D"
        case: conn_type = "Other"
        }
        fmt.printfln("[drm] {}-{} verbunden, {} Modes",
            conn_type, conn.connector_type_id, conn.count_modes)

        // Besten Mode finden: höchste Auflösung, darunter höchste Refresh-Rate.
        // Dem EDID-Preferred-Mode NICHT blind vertrauen — der ist oft nur 60Hz,
        // obwohl der Monitor mehr kann (z.B. 4K@165). Mit [monitor]
        // refresh_rate in der Config wird stattdessen die Rate gewählt, die
        // dem Wunschwert am nächsten liegt.
        mode_idx := c.int(0)
        mode_arr := cast([^]DrmModeInfo)(conn.modes)
        want_hz := g_config.refresh_rate
        for mi in 1..<conn.count_modes {
            m := mode_arr[mi]
            b := mode_arr[mode_idx]
            area := int(m.hdisplay) * int(m.vdisplay)
            barea := int(b.hdisplay) * int(b.vdisplay)
            if area != barea {
                if area > barea do mode_idx = mi
                continue
            }
            if want_hz > 0 {
                if abs(int(m.vrefresh) - int(want_hz)) < abs(int(b.vrefresh) - int(want_hz)) {
                    mode_idx = mi
                }
            } else if m.vrefresh > b.vrefresh {
                mode_idx = mi
            }
        }
        best_mode = mode_arr[mode_idx]
        best_connector_id = conn.connector_id

        // Encoder finden → CRTC finden
        enc := drmModeGetEncoder(fd, conn.encoder_id)
        crtc_ids := cast([^]u32)(res.crtcs)  // declared here for fallback too
        if enc != nil {
            // CRTC aus possible_crtcs Bitmask wählen
            for cri in 0..<res.count_crtcs {
                if (enc.possible_crtcs & (u32(1) << u32(cri))) != 0 {
                    best_crtc_id = crtc_ids[cri]
                    best_crtc_index = cri
                    break
                }
            }
            drmModeFreeEncoder(enc)
        }

        if best_crtc_id == 0 {
            // Fallback: ersten CRTC versuchen
            if res.count_crtcs > 0 {
                best_crtc_id = crtc_ids[0]
                best_crtc_index = 0
            }
        }

        if best_crtc_id != 0 {
            found_connector = true
            break
        }
    }

    if !found_connector || best_crtc_id == 0 {
        fmt.eprintln("[drm] FEHLER: Kein verbundener Connector mit CRTC gefunden")
        return false
    }

    out.connector_id = best_connector_id
    out.crtc_id = best_crtc_id
    out.mode = best_mode
    out.width = u32(best_mode.hdisplay)
    out.height = u32(best_mode.vdisplay)
    out.refresh = best_mode.vrefresh

    fmt.printfln("[drm] Mode gewählt: {}x{}@{}Hz",
        out.width, out.height, out.refresh)
    fmt.printfln("[drm] Connector: {}, CRTC: {}", out.connector_id, out.crtc_id)

    // Aktuellen CRTC-Zustand sichern, BEVOR wir modesetten — beim Exit/Crash
    // wird er restauriert, sonst bleibt der TTY schwarz (kein fbcon mehr).
    // Muss hier (nicht im Signal-Handler) passieren: drmModeGetCrtc alloziert.
    g_saved_crtc = drmModeGetCrtc(fd, out.crtc_id)

    // ── 3. Primary Plane finden ───────────────────────────────────────────────
    plane_res := drmModeGetPlaneResources(fd)
    if plane_res != nil {
        plane_ids := cast([^]u32)(plane_res.planes)
        for pi in 0..<plane_res.count_planes {
            plane := drmModeGetPlane(fd, plane_ids[pi])
            if plane == nil do continue
            // Prüfen ob dieser Plane zum CRTC passt (possible_crtcs Bitmask)
            if best_crtc_index >= 0 && (plane.possible_crtcs & (u32(1) << u32(best_crtc_index))) != 0 {
                out.plane_id = plane.plane_id
                drmModeFreePlane(plane)
                break
            }
            drmModeFreePlane(plane)
        }
        drmModeFreePlaneResources(plane_res)
    }

    // ── 4. Dumb Buffer (double-buffered) erstellen ──────────────────────────────
    for buf in 0..<2 {
        handle: u32 = 0
        pitch: u32 = 0
        size: u64 = 0
        if drmModeCreateDumbBuffer(fd, out.width, out.height, 32, 0, &handle, &pitch, &size) != 0 {
            fmt.eprintfln("[drm] FEHLER: drmModeCreateDumbBuffer[{}] fehlgeschlagen", buf)
            return false
        }
        out.handle[buf] = handle
        out.pitch[buf] = pitch
        out.size[buf]  = size
        fmt.printfln("[drm] Dumb buffer[{}]: {}x{} pitch={} size={} handle={}",
            buf, out.width, out.height, out.pitch[buf], out.size[buf], out.handle[buf])

        // Als DRM Framebuffer registrieren (drmModeAddFB2 mit XRGB8888 Format)
        handles := [4]u32{out.handle[buf], 0, 0, 0}
        pitches := [4]u32{out.pitch[buf], 0, 0, 0}
        offsets := [4]u32{0, 0, 0, 0}
        fb_id: u32 = 0
        if drmModeAddFB2(fd, out.width, out.height, DRM_FORMAT_XRGB8888, &handles[0], &pitches[0], &offsets[0], &fb_id, 0) != 0 {
            fmt.eprintfln("[drm] FEHLER: drmModeAddFB2[{}] fehlgeschlagen — versuche drmModeAddFB", buf)
            // Fallback: altes drmModeAddFB API
            if drmModeAddFB(fd, out.width, out.height, out.pitch[buf], 32, 24, out.handle[buf], &fb_id) != 0 {
                fmt.eprintfln("[drm] FEHLER: auch drmModeAddFB[{}] fehlgeschlagen", buf)
                return false
            }
        }
        out.fb[buf] = fb_id

        // mmap für CPU-Compositing
        map_offset: u64 = 0
        if drmModeMapDumbBuffer(fd, out.handle[buf], &map_offset) != 0 {
            fmt.eprintfln("[drm] FEHLER: drmModeMapDumbBuffer[{}] fehlgeschlagen", buf)
            return false
        }
        out.map_offset[buf] = map_offset
        out.pixels[buf] = mmap_dumb(fd, map_offset, out.size[buf])
        if out.pixels[buf] == nil {
            fmt.eprintfln("[drm] FEHLER: mmap[{}] fehlgeschlagen", buf)
            return false
        }
        fmt.printfln("[drm] Buffer[{}] mmap'd at {}", buf, out.pixels[buf])
    }

    out.back = 1  // back buffer ist index 1, front ist 0
    out.page_flip_pending = false
    out.needs_frame = false

    // ── 5. Initial Modeset ──────────────────────────────────────────────────────
    // Front Buffer (index 0) an CRTC binden + Mode setzen
    conn_id := out.connector_id
    if drmModeSetCrtc(fd, out.crtc_id, out.fb[0], 0, 0, &conn_id, 1, &out.mode) != 0 {
        fmt.eprintln("[drm] FEHLER: drmModeSetCrtc() fehlgeschlagen (initial modeset)")
        return false
    }
    fmt.println("[drm] ✅ Initial modeset erfolgreich — Bildschirm aktiv")

    // Back buffer mit Hintergrundfarbe füllen
    drm_clear(g_config.bg_color)

    // Ersten Frame präsentieren (page flip von front→back)
    if drmModePageFlip(fd, out.crtc_id, out.fb[out.back], DRM_MODE_PAGE_FLIP_EVENT, nil) != 0 {
        fmt.eprintln("[drm] WARNUNG: erster PageFlip fehlgeschlagen — versuche direkten modeset")
        // Fallback: direkter modeset auf back buffer
        if drmModeSetCrtc(fd, out.crtc_id, out.fb[out.back], 0, 0, &conn_id, 1, &out.mode) != 0 {
            fmt.eprintln("[drm] FEHLER: auch direkter modeset fehlgeschlagen")
        }
        // front/back syncen
        out.back = 0
    } else {
        out.page_flip_pending = true
        fmt.println("[drm] ✅ Erster PageFlip eingereicht")
    }

    g_backend_drm = true
    drm_input_init_pointer()  // Pointer-Position auf Screen-Center setzen
    drm_cursor_init()         // Hardware-Cursor aktivieren
    fmt.printfln("[drm] ✅ DRM-Backend bereit: {}x{}@{}Hz (double-buffered)",
        out.width, out.height, out.refresh)
    return true
}

// ─── mmap helper für dumb buffer ──────────────────────────────────────────────
mmap_dumb :: proc(fd: c.int, offset: u64, size: u64) -> rawptr {
    result, err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, i64(offset))
    if err != .NONE do return nil
    return result
}

// ═══════════════════════════════════════════════════════════════════════════
//  Compositing Interface (gleiche API wie nested backend)
// ═══════════════════════════════════════════════════════════════════════════

// ─── Buffer leeren (Hintergrundfarbe) ──────────────────────────────────────────
// Musterzeile im normalen RAM als memcpy-Quelle für drm_clear. Aus dem
// WC-gemappten Dumb-Buffer selbst zu lesen wäre extrem langsam (uncached).
g_clear_row: []u32

drm_clear :: proc(color: u32) {
    if g_drm_output == nil do return
    out := g_drm_output
    pixels := cast([^]u32)(out.pixels[out.back])
    if pixels == nil do return
    w := int(out.width)
    if len(g_clear_row) < w {
        delete(g_clear_row)
        g_clear_row = make([]u32, w)
        g_clear_row[0] = color ~ 0xFFFFFFFF   // erzwingt Erstbefüllung unten
    }
    if g_clear_row[0] != color {
        for i in 0..<w do g_clear_row[i] = color
    }
    // Zeilenweise über den pitch — bei manchen Auflösungen ist pitch > width*4
    stride := int(out.pitch[out.back]) / 4
    row_bytes := w * 4
    for y in 0..<int(out.height) {
        runtime.mem_copy_non_overlapping(rawptr(pixels[y * stride:]), raw_data(g_clear_row), row_bytes)
    }
}

// ─── Skalierten Blit (Client-Buffer → Dumb-Buffer) ──────────────────────────────
// Identisch zu nested_blit_scaled — nearest-neighbor CPU blit.
drm_blit_scaled :: proc(
    src: [^]u32, sw, sh: i32,
    dx, dy, dw, dh: i32,
) {
    if g_drm_output == nil do return
    out := g_drm_output
    dst := cast([^]u32)(out.pixels[out.back])
    if dst == nil || src == nil do return
    dstride := i32(out.pitch[out.back]) / 4  // pitch in bytes → pixels

    if dw <= 0 || dh <= 0 do return
    sx_ratio := f64(sw) / f64(dw)
    sy_ratio := f64(sh) / f64(dh)

    for y in 0..<dh {
        src_y := i32(f64(y) * sy_ratio)
        if src_y >= sh do src_y = sh - 1
        for x in 0..<dw {
            src_x := i32(f64(x) * sx_ratio)
            if src_x >= sw do src_x = sw - 1
            dx2 := dx + x
            dy2 := dy + y
            if dx2 >= 0 && dx2 < i32(out.width) && dy2 >= 0 && dy2 < i32(out.height) {
                dst[dy2 * dstride + dx2] = src[src_y * sw + src_x]
            }
        }
    }
}

// ─── 1:1-Blit mit Clipping (Pendant zu nested_blit_clipped) ─────────────────────
drm_blit_clipped :: proc(src: [^]u32, src_w, src_h: i32, src_stride: i32, dst_x, dst_y: i32, clip: Rect) {
    if g_drm_output == nil do return
    out := g_drm_output
    dst := cast([^]u32)(out.pixels[out.back])
    if dst == nil || src == nil || src_w <= 0 || src_h <= 0 do return
    dstride := int(out.pitch[out.back]) / 4
    ww := int(out.width)
    hh := int(out.height)
    sstride := int(src_stride) if src_stride > 0 else int(src_w)
    x0 := max(int(dst_x), int(clip[0]), 0)
    y0 := max(int(dst_y), int(clip[1]), 0)
    x1 := min(int(dst_x) + int(src_w), int(clip[0] + clip[2]), ww)
    y1 := min(int(dst_y) + int(src_h), int(clip[1] + clip[3]), hh)
    if x0 >= x1 || y0 >= y1 do return
    // Zeilenweises memcpy statt Pixel-Loop: der Dumb-Buffer ist write-combined
    // gemappt — sequentielle SIMD-Writes sind hier um Größenordnungen schneller
    // als einzelne u32-Stores (Kern der Firefox-Framerate bei 4K).
    row_bytes := (x1 - x0) * 4
    for py in y0..<y1 {
        drow := py * dstride
        srow := (py - int(dst_y)) * sstride - int(dst_x)
        runtime.mem_copy_non_overlapping(rawptr(dst[drow + x0:]), rawptr(src[srow + x0:]), row_bytes)
    }
}

// ─── PageFlip-Watchdog ─────────────────────────────────────────────────────────
// Geht ein Flip-Event verloren (Treiber-Edge-Case, VT-Switch-Race), bliebe
// page_flip_pending für immer true → eingefrorener Schirm. Der Watchdog-Timer
// wird bei jedem Flip gestellt und vom Flip-Event wieder entschärft.
g_flip_watchdog: ^wls.wl_event_source = nil
DRM_FLIP_TIMEOUT_MS :: 1000

drm_flip_watchdog_fired :: proc "c" (data: rawptr) -> c.int {
    context = ctx
    if g_drm_output != nil && g_drm_output.page_flip_pending {
        fmt.eprintln("[drm] WATCHDOG: PageFlip-Event verloren — Flip-State zurückgesetzt")
        g_drm_output.page_flip_pending = false
        composite_all()
    }
    return 0
}

drm_watchdog_arm :: proc(ms: c.int) {
    context = ctx
    if g_flip_watchdog == nil {
        if g_server == nil || g_server.display == nil do return
        loop := wls.display_get_event_loop(g_server.display)
        g_flip_watchdog = wls.event_loop_add_timer(loop, drm_flip_watchdog_fired, nil)
        if g_flip_watchdog == nil do return
    }
    wls.event_source_timer_update(g_flip_watchdog, ms)   // 0 = disarm
}

// ─── Frame präsentieren (Page Flip) ──────────────────────────────────────────────
drm_commit :: proc() {
    if g_drm_output == nil do return
    out := g_drm_output
    if g_session == nil || g_session.drm_fd < 0 do return
    fd := g_session.drm_fd

    // Wenn noch ein Page Flip läuft → Frame als "needs frame" markieren
    if out.page_flip_pending {
        out.needs_frame = true
        return
    }

    // Page Flip: back buffer → scanout (non-blocking, mit Event)
    ret := drmModePageFlip(fd, out.crtc_id, out.fb[out.back],
        DRM_MODE_PAGE_FLIP_EVENT, nil)
    if ret != 0 {
        fmt.eprintfln("[drm] WARNUNG: drmModePageFlip fehlgeschlagen (errno={})", ret)
        return
    }
    out.page_flip_pending = true
    out.needs_frame = false
    drm_watchdog_arm(DRM_FLIP_TIMEOUT_MS)
}

// ─── DRM Events verarbeiten (Page-Flip-Events) ──────────────────────────────────
// Diese Funktion wird aus dem Event-Loop aufgerufen wenn der DRM-fd lesbar ist.
drm_dispatch :: proc "c" (fd: c.int, mask: u32, data: rawptr) -> c.int {
    context = ctx
    // Nur den v2-Handler setzen — v1 hat eine andere Signatur (ohne crtc_id);
    // dieselbe proc als v1 zu registrieren würde bei einem v1-Aufruf die
    // Argumente verschieben. Mit version=4 + handler2 nutzt libdrm immer v2.
    ev: DrmEventContext = {
        version = DRM_EVENT_CONTEXT_VERSION,
        page_flip_handler2 = drm_page_flip_handler,
    }
    drmHandleEvent(fd, &ev)
    return 0
}

// ─── Output-Größe für Layout ──────────────────────────────────────────────────
drm_get_output_size :: proc(w: ^int, h: ^int) {
    if g_drm_output == nil {
        w^ = 1920
        h^ = 1080
        return
    }
    w^ = int(g_drm_output.width)
    h^ = int(g_drm_output.height)
}

// ─── DRM fd für Event-Loop ──────────────────────────────────────────────────────
drm_get_fd :: proc() -> c.int {
    if g_session == nil do return -1
    return g_session.drm_fd
}

// ─── Legacy Present (Single-Surface, ohne Compositing) ──────────────────────────
drm_present :: proc(src: [^]u32, w, h: i32) {
    if g_drm_output == nil do return
    out := g_drm_output
    dst := cast([^]u32)(out.pixels[out.back])
    if dst == nil || src == nil do return
    dstride := i32(out.pitch[out.back]) / 4
    // 1:1 Copy (clipped)
    copy_w := min(w, i32(out.width))
    copy_h := min(h, i32(out.height))
    for y in 0..<copy_h {
        for x in 0..<copy_w {
            dst[y * dstride + x] = src[y * w + x]
        }
    }
    drm_commit()
}

// ─── Cleanup ──────────────────────────────────────────────────────────────────────
drm_cleanup :: proc() {
    context = ctx
    if g_drm_output == nil do return
    out := g_drm_output
    // Erst Cursor cleanup (nur wenn cursor initialisiert wurde)
    if g_drm_cursor != nil {
        drm_cursor_cleanup()
    }
    // CRTC auf den Vor-rift-Zustand zurücksetzen (Text-Konsole), statt ihn
    // zu deaktivieren — sonst bleibt der TTY nach dem Beenden schwarz.
    drm_restore_saved_crtc()
    if g_saved_crtc != nil {
        drmModeFreeCrtc(g_saved_crtc)
        g_saved_crtc = nil
    }
    // Dumb Buffer zerstören (nur wenn mmap'd)
    for buf in 0..<2 {
        if out.pixels[buf] != nil {
            linux.munmap(out.pixels[buf], uint(out.size[buf]))
            out.pixels[buf] = nil
        }
        if out.fb[buf] != 0 && g_session != nil && g_session.drm_fd >= 0 {
            drmModeRmFB(g_session.drm_fd, out.fb[buf])
            out.fb[buf] = 0
        }
        if out.handle[buf] != 0 && g_session != nil && g_session.drm_fd >= 0 {
            drmModeDestroyDumbBuffer(g_session.drm_fd, out.handle[buf])
            out.handle[buf] = 0
        }
    }
    free(out, context.allocator)
    g_drm_output = nil
    g_backend_drm = false
    vt_restore_text()
    fmt.println("[drm] cleanup done")
}

// ═══════════════════════════════════════════════════════════════════════════
//  VT-Switch Restore — nach Rückkehr vom VT-Switch
//  Kernel hat den Display-State verloren → neu modesetten
// ═══════════════════════════════════════════════════════════════════════════

drm_restore_after_vt :: proc() {
    context = ctx
    if g_drm_output == nil do return
    if g_session == nil || g_session.drm_fd < 0 do return
    out := g_drm_output
    fd := g_session.drm_fd

    fmt.println("[drm] VT-Switch Restore — neu modesetten")

    // 1. Stale Page-Flip-State löschen (Pending flips aus der alten Session sind verloren)
    out.page_flip_pending = false
    out.needs_frame = false

    // 2. Re-Modeset mit aktuellem Mode und Front-Buffer (nicht dem Back-Buffer —
    //    composite_all rendert gleich in den Back und flippt darauf)
    conn_id := out.connector_id
    if drmModeSetCrtc(fd, out.crtc_id, out.fb[1 - out.back], 0, 0, &conn_id, 1, &out.mode) != 0 {
        fmt.eprintln("[drm] WARNUNG: Re-Modeset nach VT-Switch fehlgeschlagen")
    } else {
        fmt.println("[drm] ✅ Re-Modeset erfolgreich — Display wiederhergestellt")
    }

    // 3. Cursor neu setzen (Kernel hat Cursor-Plane zurückgesetzt)
    if g_drm_cursor != nil && g_drm_cursor.visible {
        if drmModeSetCursor2(fd, out.crtc_id, g_drm_cursor.handle,
            g_drm_cursor.width, g_drm_cursor.height,
            g_drm_cursor.hot_x, g_drm_cursor.hot_y) != 0 {
            drmModeSetCursor(fd, out.crtc_id, g_drm_cursor.handle,
                g_drm_cursor.width, g_drm_cursor.height)
        }
        drm_cursor_move(i32(nested.ptr_x), i32(nested.ptr_y))
    }

    // 4. Ersten Frame rendern
    composite_all()
}