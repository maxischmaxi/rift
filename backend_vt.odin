package main

import "core:fmt"
import "core:sys/linux"

// ═══════════════════════════════════════════════════════════════════════════
//  VT-Modus (KDSETMODE) — im Standalone-Betrieb den VT auf KD_GRAPHICS
//  stellen (unterdrückt fbcon/Cursor-Blinken über unserem Bild) und bei
//  Exit/Crash zwingend auf KD_TEXT zurück, sonst bleibt die Konsole
//  unbenutzbar (schwarz, kein Echo).
// ═══════════════════════════════════════════════════════════════════════════

KDSETMODE   :: uintptr(0x4B3A)
KD_TEXT     :: uintptr(0x00)
KD_GRAPHICS :: uintptr(0x01)

g_tty_fd: linux.Fd = -1

vt_enter_graphics :: proc() {
    context = ctx
    fd, errno := linux.open("/dev/tty", {.WRONLY})
    if errno != .NONE {
        fmt.printfln("[vt] /dev/tty nicht öffenbar ({}) — KDSETMODE übersprungen", errno)
        return
    }
    g_tty_fd = fd
    if linux.ioctl(g_tty_fd, u32(KDSETMODE), KD_GRAPHICS) < 0 {
        fmt.println("[vt] KDSETMODE(KD_GRAPHICS) fehlgeschlagen (kein VT?) — weiter ohne")
    } else {
        fmt.println("[vt] VT auf KD_GRAPHICS gestellt")
    }
}

// Signal-Handler-sicher: nur ioctl/close, keine Allokation, kein fmt.
vt_restore_text :: proc "contextless" () {
    if g_tty_fd < 0 do return
    linux.ioctl(g_tty_fd, u32(KDSETMODE), KD_TEXT)
    linux.close(g_tty_fd)
    g_tty_fd = -1
}
