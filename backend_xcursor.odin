package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "base:runtime"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Xcursor File Reader — lädt System-Cursor-Theme
//  Liest Xcursor-Dateien direkt via os.read_entire_file_from_path.
// ═══════════════════════════════════════════════════════════════════════════

// Helper: LE u32 aus Byte-Slice lesen
read_u32_le :: proc(data: []u8, offset: int) -> u32 {
    return u32(data[offset]) | (u32(data[offset+1]) << 8) | (u32(data[offset+2]) << 16) | (u32(data[offset+3]) << 24)
}

// ─── Cursor-Theme-Pfad finden ────────────────────────────────────────────────
drm_cursor_find_theme :: proc(cursor_name: string) -> string {
    context = ctx

    theme := "default"
    env_theme := string(posix.getenv("XCURSOR_THEME"))
    if env_theme != "" do theme = env_theme

    home := string(posix.getenv("HOME"))

    candidates := []string{
        fmt.tprintf("{}/.icons/{}/cursors/{}", home, theme, cursor_name),
        fmt.tprintf("{}/.local/share/icons/{}/cursors/{}", home, theme, cursor_name),
        fmt.tprintf("/usr/share/icons/{}/cursors/{}", theme, cursor_name),
        fmt.tprintf("/usr/share/icons/default/cursors/{}", cursor_name),
        fmt.tprintf("/usr/share/icons/Adwaita/cursors/{}", cursor_name),
    }

    for path in candidates {
        data, err := os.read_entire_file_from_path(path, context.allocator)
        if err == nil && len(data) > 0 {
            delete(data)
            return path
        }
    }
    return ""
}

// ─── Xcursor-Datei lesen und Pixel-Daten extrahieren ──────────────────────────
drm_cursor_load_xcursor :: proc(
    path: string,
    target_size: u32,
) -> (width: u32, height: u32, xhot: u32, yhot: u32, pixels: []u32, ok: bool) {
    context = ctx

    // Datei komplett einlesen
    data, file_err := os.read_entire_file_from_path(path, context.allocator)
    if file_err != nil || len(data) < 16 {
        fmt.eprintfln("[cursor] kann {} nicht lesen", path)
        return 0, 0, 0, 0, nil, false
    }
    defer delete(data)

    // Magic prüfen
    magic := string(data[:4])
    if magic != "Xcur" {
        fmt.eprintln("[cursor] Falsche Magic")
        return 0, 0, 0, 0, nil, false
    }

    nimages := read_u32_le(data, 12)
    fmt.printfln("[cursor] Xcursor file: {} images", nimages)

    // TOC scannen, beste Größe finden
    best_pos: u32 = 0
    best_diff: u32 = 0xFFFFFFFF

    for i in 0..<int(nimages) {
        base := 16 + i * 12
        if base + 12 > len(data) do break
        subtype := read_u32_le(data, base + 4)
        position := read_u32_le(data, base + 8)

        diff := u32(0)
        if subtype >= target_size {
            diff = subtype - target_size
        } else {
            diff = target_size - subtype
        }
        if diff < best_diff {
            best_diff = diff
            best_pos = position
        }
    }

    if best_pos == 0 {
        fmt.eprintln("[cursor] Kein passendes Image gefunden")
        return 0, 0, 0, 0, nil, false
    }

    // Chunk bei best_pos: 16-byte Header überspringen, dann Image-Daten
    img_offset := int(best_pos) + 16
    if img_offset + 20 > len(data) {
        fmt.eprintln("[cursor] Image-Daten außerhalb der Datei")
        return 0, 0, 0, 0, nil, false
    }

    width = read_u32_le(data, img_offset)
    height = read_u32_le(data, img_offset + 4)
    xhot = read_u32_le(data, img_offset + 8)
    yhot = read_u32_le(data, img_offset + 12)

    fmt.printfln("[cursor] Image: {}x{}, hotspot=({},{})", width, height, xhot, yhot)

    if width == 0 || height == 0 || width > 256 || height > 256 {
        fmt.eprintfln("[cursor] Ungültige Größe: {}x{}", width, height)
        return 0, 0, 0, 0, nil, false
    }

    // Pixel-Daten kopieren
    pixel_offset := img_offset + 20
    pixel_count := int(width * height)
    pixel_bytes := pixel_count * 4
    if pixel_offset + pixel_bytes > len(data) {
        fmt.eprintln("[cursor] Pixel-Daten außerhalb der Datei")
        return 0, 0, 0, 0, nil, false
    }

    // Heap-Allokation für Pixel
    pixels = make([]u32, pixel_count)

    for i in 0..<pixel_count {
        pixels[i] = read_u32_le(data, pixel_offset + i * 4)
    }

    fmt.printfln("[cursor] ✅ Cursor geladen: {}x{}", width, height)
    return width, height, xhot, yhot, pixels, true
}

// ─── System-Cursor in DRM dumb buffer laden ────────────────────────────────────
drm_cursor_load_system :: proc(cur: ^DrmCursor) -> bool {
    context = ctx

    // Cursor-Größe aus env oder default
    target_size := u32(24)
    env_size := string(posix.getenv("XCURSOR_SIZE"))
    if env_size != "" {
        n := 0
        for ch in env_size {
            if ch >= '0' && ch <= '9' { n = n * 10 + int(ch - '0') }
        }
        if n > 0 do target_size = u32(n)
    }

    path := drm_cursor_find_theme("left_ptr")
    if path == "" {
        fmt.eprintln("[cursor] Kein System-Cursor-Theme gefunden")
        return false
    }
    fmt.printfln("[cursor] Theme: {}", path)

    w, h, xh, yh, pixels, ok := drm_cursor_load_xcursor(path, target_size)
    if !ok || pixels == nil {
        fmt.eprintln("[cursor] Xcursor-Lesung fehlgeschlagen")
        return false
    }
    defer delete(pixels)

    // In DRM dumb buffer kopieren
    dst := cast([^]u32)(cur.pixels)
    if dst == nil do return false
    stride := i32(cur.pitch) / 4

    // Buffer transparent (zeilenweise — pitch kann breiter als width sein)
    for y in 0..<i32(cur.height) {
        for x in 0..<i32(cur.width) {
            dst[y * stride + x] = 0x00000000
        }
    }

    // Bild an die BO-Ecke (0,0) — NICHT zentrieren! MoveCursor positioniert
    // die BO-Ecke; ein zentriertes Bild wäre um (bo-img)/2 Pixel versetzt.
    for y in 0..<i32(h) {
        for x in 0..<i32(w) {
            if x < i32(cur.width) && y < i32(cur.height) {
                dst[y * stride + x] = pixels[y * i32(w) + x]
            }
        }
    }

    // Hotspot merken — drm_cursor_move zieht ihn von der Position ab
    cur.hot_x = i32(xh)
    cur.hot_y = i32(yh)

    fmt.printfln("[cursor] ✅ System-Cursor kopiert ({}x{}, hotspot=({},{}))", w, h, xh, yh)
    return true
}