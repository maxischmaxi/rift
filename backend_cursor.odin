package main

import "core:fmt"
import "core:c"
import "core:sys/linux"
import "base:runtime"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Hardware Cursor (DRM Cursor Plane)
//
//  Erstellt einen Hardware-Cursor via DRM: dumb buffer → drmModeSetCursor2.
//  Der Kernel scanout-ed den Cursor auf dem Cursor-Plane (kein Software-Cursor,
//  kein Re-Compositing bei Mausbewegung — nur ein MoveCursor-ioctl).
//
//  Hotspot: Das Cursor-Bild liegt an (0,0) im BO. Der Hotspot (Klickpunkt,
//  z.B. Pfeilspitze) wird beim Bewegen abgezogen: MoveCursor(x-hot_x, y-hot_y).
//  So liegt der Hotspot exakt auf der logischen Pointer-Position.
//
//  Voraussetzung: drm_init() muss erfolgreich gewesen sein (CRTC aktiv).
// ═══════════════════════════════════════════════════════════════════════════

DrmCursor :: struct {
    handle:   u32,       // GEM handle für dumb buffer
    width:    u32,       // Cursor-BO-Breite (DRM_CAP_CURSOR_WIDTH, z.B. 64 oder 256)
    height:   u32,       // Cursor-BO-Höhe  (DRM_CAP_CURSOR_HEIGHT)
    pitch:    u32,
    size:     u64,
    pixels:   rawptr,    // mmap'd ARGB8888 pixel data
    hot_x:    i32,       // Hotspot (Klickpunkt) relativ zur BO-Ecke
    hot_y:    i32,
    visible:  bool,
}

g_drm_cursor: ^DrmCursor = nil

// ─── Cursor initialisieren ──────────────────────────────────────────────────
drm_cursor_init :: proc() -> bool {
    context = ctx
    if g_session == nil || g_session.drm_fd < 0 do return false
    if g_drm_output == nil do return false
    fd := g_session.drm_fd

    // Cursor-Größe vom Kernel abfragen
    cur_w: u64 = 64
    cur_h: u64 = 64
    drmGetCap(fd, DRM_CAP_CURSOR_WIDTH, &cur_w)
    drmGetCap(fd, DRM_CAP_CURSOR_HEIGHT, &cur_h)

    cur := new(DrmCursor)
    cur.width = u32(cur_w)
    cur.height = u32(cur_h)
    cur.visible = true

    fmt.printfln("[cursor] Cursor-Größe: {}x{}", cur.width, cur.height)

    // Dumb buffer für Cursor erstellen (ARGB8888 = 32bpp)
    handle: u32 = 0
    pitch: u32 = 0
    size: u64 = 0
    if drmModeCreateDumbBuffer(fd, cur.width, cur.height, 32, 0, &handle, &pitch, &size) != 0 {
        fmt.eprintln("[cursor] FEHLER: drmModeCreateDumbBuffer fehlgeschlagen")
        free(cur, context.allocator)
        return false
    }
    cur.handle = handle
    cur.pitch = pitch
    cur.size = size

    // mmap
    map_offset: u64 = 0
    if drmModeMapDumbBuffer(fd, handle, &map_offset) != 0 {
        fmt.eprintln("[cursor] FEHLER: drmModeMapDumbBuffer fehlgeschlagen")
        drmModeDestroyDumbBuffer(fd, handle)
        free(cur, context.allocator)
        return false
    }
    cur.pixels, _ = linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, auto_cast fd, i64(map_offset))
    if cur.pixels == nil {
        fmt.eprintln("[cursor] FEHLER: mmap fehlgeschlagen")
        drmModeDestroyDumbBuffer(fd, handle)
        free(cur, context.allocator)
        return false
    }

    // Cursor-Bild laden: System-Theme versuchen, Fallback auf hand-gezeichneten Pfeil
    if !drm_cursor_load_system(cur) {
        fmt.println("[cursor] Fallback: hand-gezeichneter Pfeil")
        drm_cursor_draw_arrow(cur)
    }

    g_drm_cursor = cur

    // Hardware-Cursor auf CRTC setzen — SetCursor2 übergibt den Hotspot
    // (relevant für virtualisierte Treiber), Fallback auf SetCursor.
    if drmModeSetCursor2(fd, g_drm_output.crtc_id, handle,
        cur.width, cur.height, cur.hot_x, cur.hot_y) != 0 {
        if drmModeSetCursor(fd, g_drm_output.crtc_id, handle, cur.width, cur.height) != 0 {
            fmt.eprintln("[cursor] WARNUNG: drmModeSetCursor fehlgeschlagen")
        }
    }

    // Cursor auf aktuelle Pointer-Position setzen (Bildschirmmitte nach Init)
    drm_cursor_move(i32(nested.ptr_x), i32(nested.ptr_y))

    fmt.println("[cursor] ✅ Hardware-Cursor aktiviert")
    return true
}

// ─── Pfeil-Cursor zeichnen (weiß mit schwarzer Umrandung) ──────────────────────
// 18×26 Pixel an der BO-Ecke (0,0); Hotspot = Pfeilspitze = (0,0).
drm_cursor_draw_arrow :: proc(cur: ^DrmCursor) {
    context = ctx
    pixels := cast([^]u32)(cur.pixels)
    if pixels == nil do return
    stride := i32(cur.pitch) / 4

    // Buffer transparent
    for y in 0..<i32(cur.height) {
        for x in 0..<i32(cur.width) {
            pixels[y * stride + x] = 0x00000000
        }
    }

    BLACK :: u32(0xFF000000)
    WHITE :: u32(0xFFFFFFFF)

    arrow_w := i32(18)

    for y in 0..<i32(min(cur.height, 26)) {
        for x in 0..<i32(min(cur.width, 18)) {
            is_fill := false
            is_border := false

            // Pfeilspitze: Dreieck
            if y <= x && x < arrow_w && y < arrow_w {
                is_fill = true
                if x == 0 || y == 0 || y == x {
                    is_border = true
                }
            }

            // Stiel
            if x >= 11 && x <= 17 && y >= 14 && y < 26 {
                is_fill = true
                if x == 11 || x == 17 || y == 14 || y == 25 {
                    is_border = true
                }
            }

            if is_border {
                pixels[y * stride + x] = BLACK
            } else if is_fill {
                pixels[y * stride + x] = WHITE
            }
        }
    }

    cur.hot_x = 0
    cur.hot_y = 0
}

// ─── Cursor bewegen ────────────────────────────────────────────────────────────
// Ein einziges ioctl — der Kernel verschiebt den Cursor-Plane beim nächsten
// Scanout. Kein Compositing, kein Page Flip nötig.
// MoveCursor positioniert die BO-Ecke → Hotspot abziehen, damit der
// Klickpunkt (Pfeilspitze) auf der logischen Position liegt.
drm_cursor_move :: proc(x, y: i32) {
    if g_drm_cursor == nil || !g_drm_cursor.visible do return
    if g_session == nil || g_session.drm_fd < 0 do return
    if g_drm_output == nil do return

    drmModeMoveCursor(g_session.drm_fd, g_drm_output.crtc_id,
        x - g_drm_cursor.hot_x, y - g_drm_cursor.hot_y)
}

// ─── Cursor sichtbar/unsichtbar ────────────────────────────────────────────────
drm_cursor_set_visible :: proc(visible: bool) {
    if g_drm_cursor == nil do return
    g_drm_cursor.visible = visible
    if g_session == nil || g_session.drm_fd < 0 || g_drm_output == nil do return
    fd := g_session.drm_fd
    if visible {
        drmModeSetCursor2(fd, g_drm_output.crtc_id, g_drm_cursor.handle,
            g_drm_cursor.width, g_drm_cursor.height, g_drm_cursor.hot_x, g_drm_cursor.hot_y)
        drm_cursor_move(i32(nested.ptr_x), i32(nested.ptr_y))
    } else {
        // handle=0 versteckt den Cursor
        drmModeSetCursor(fd, g_drm_output.crtc_id, 0, 0, 0)
    }
}

// ─── Cursor cleanup ─────────────────────────────────────────────────────────────
drm_cursor_cleanup :: proc() {
    context = ctx
    if g_drm_cursor == nil do return
    cur := g_drm_cursor
    if g_session != nil && g_session.drm_fd >= 0 {
        // Cursor verstecken
        if g_drm_output != nil {
            drmModeSetCursor(g_session.drm_fd, g_drm_output.crtc_id, 0, 0, 0)
        }
        // Dumb buffer zerstören
        if cur.pixels != nil {
            linux.munmap(cur.pixels, uint(cur.size))
        }
        if cur.handle != 0 {
            drmModeDestroyDumbBuffer(g_session.drm_fd, cur.handle)
        }
    }
    free(cur, context.allocator)
    g_drm_cursor = nil
    fmt.println("[cursor] cleanup done")
}
