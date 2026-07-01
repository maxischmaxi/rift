package main

import "core:fmt"
import "core:os"
import "core:c"
import "base:runtime"

// ─── Foreign imports für C signal functions ──────────────────────────────────
foreign import libc "system:c"

SignalHandler :: proc "c" (sig: c.int)

@(default_calling_convention = "c")
foreign libc {
	signal :: proc(signum: c.int, handler: SignalHandler) -> SignalHandler ---
	raise  :: proc(signum: c.int) -> c.int ---
}

// Signal numbers (Linux)
SIGTERM :: c.int(15)
SIGINT  :: c.int(2)
SIGSEGV :: c.int(11)
SIGABRT :: c.int(6)

// ═══════════════════════════════════════════════════════════════════════════
//  rift Signal Handlers — Crash Recovery & Clean Shutdown
//
//  Ohne Signal-Handler würde ein Crash (SIGSEGV) den DRM-Master nicht
//  freigeben → der Bildschirm bleibt schwarz. Diese Handler stellen
//  sicher dass bei Crash/Exit:
//    1. DRM-Master abgegeben wird (drmDropMaster)
//    2. VT in Text-Modus zurückgesetzt wird (falls standalone)
//    3. libseat Seat geschlossen wird
//
//  Signal-Liste:
//    SIGTERM → clean shutdown (kill rift)
//    SIGINT  → clean shutdown (Ctrl+C)
//    SIGSEGV → emergency cleanup + crash
//    SIGABRT → emergency cleanup + crash
// ═══════════════════════════════════════════════════════════════════════════


// Globaler " shutting down" Flag — verhindert Rekursion im Signal-Handler
g_shutting_down: bool = false

// ─── Emergency Cleanup (bei Crash) ────────────────────────────────────────────
// MÖGLICHST MINIMAL — keine fmt.println, keine Speicherallokation,
// nur die kritischsten Kernel-Calls.
rift_emergency_cleanup :: proc() {
    // 1) CRTC auf den Vor-rift-Zustand (Text-Konsole) — braucht noch Master!
    drm_restore_saved_crtc()
    // 2) VT zurück in den Text-Modus (sonst schwarze, tote Konsole)
    vt_restore_text()
    // 3) DRM-Master abgeben
    if g_session != nil && g_session.drm_fd >= 0 {
        drmDropMaster(g_session.drm_fd)
    }
    // 4) libseat schliessen (gibt VT frei) — nur wenn nicht direct mode
    if g_session != nil && !g_session.direct && g_session.seat != nil {
        libseat_close_seat(g_session.seat)
    }
}

// ─── Signal Handler (C Callback) ────────────────────────────────────────────────
rift_signal_handler :: proc "c" (sig: c.int) {
    context = runtime.default_context()
    if g_shutting_down {
        return
    }
    g_shutting_down = true

    switch sig {
    case SIGTERM, SIGINT:
        // Clean shutdown — KEIN fmt (kann während cleanup crashen)
        rift_emergency_cleanup()
        os.exit(0)

    case SIGSEGV, SIGABRT:
        // Crash: emergency cleanup + re-raise
        rift_emergency_cleanup()
        signal(sig, nil)  // Reset to default
        raise(sig)
        return

    case:
        return
    }
}

// ─── Signal Handler registrieren ──────────────────────────────────────────────
rift_setup_signals :: proc() {
    signal(SIGTERM, rift_signal_handler)
    signal(SIGINT,  rift_signal_handler)
    signal(SIGSEGV, rift_signal_handler)
    signal(SIGABRT, rift_signal_handler)
    fmt.println("[rift] Signal-Handler registriert (SIGTERM, SIGINT, SIGSEGV, SIGABRT)")
}