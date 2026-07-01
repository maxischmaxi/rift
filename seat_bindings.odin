package main

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libseat Bindings für Odin
//
//  libseat verwaltet Session/Seat-Zugriff: DRM-Master, Input-Device-Access,
//  VT-Switching. Wird von Compositors verwendet, um Hardware zu öffnen,
//  ohne root zu sein.
// ═══════════════════════════════════════════════════════════════════════════

foreign import libseat "system:seat"

// ─── Opaque Types ──────────────────────────────────────────────────────────────
Libseat :: distinct struct {}

// ─── Seat Listener (Callbacks) ────────────────────────────────────────────────
LibseatEnableSeat  :: proc "c" (seat: ^Libseat, userdata: rawptr)
LibseatDisableSeat :: proc "c" (seat: ^Libseat, userdata: rawptr)

LibseatSeatListener :: struct {
	enable_seat:  LibseatEnableSeat,  // proc type, not pointer
	disable_seat: LibseatDisableSeat,
}

// ─── Functions ─────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libseat {
	libseat_open_seat    :: proc(listener: ^LibseatSeatListener, userdata: rawptr) -> ^Libseat ---
	libseat_close_seat   :: proc(seat: ^Libseat) -> c.int ---
	libseat_disable_seat :: proc(seat: ^Libseat) -> c.int ---

	libseat_open_device  :: proc(seat: ^Libseat, path: cstring, fd: ^c.int) -> c.int ---
	libseat_close_device :: proc(seat: ^Libseat, device_id: c.int) -> c.int ---

	libseat_seat_name      :: proc(seat: ^Libseat) -> cstring ---
	libseat_switch_session :: proc(seat: ^Libseat, session: c.int) -> c.int ---

	libseat_get_fd    :: proc(seat: ^Libseat) -> c.int ---
	libseat_dispatch  :: proc(seat: ^Libseat, timeout: c.int) -> c.int ---
}