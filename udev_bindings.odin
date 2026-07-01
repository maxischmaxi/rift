package main

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libudev Bindings für Odin
//
//  libudev: GPU-Discovery, Hotplug-Monitoring, Input-Device-Discovery.
// ═══════════════════════════════════════════════════════════════════════════

foreign import libudev "system:udev"

// ─── Opaque Types ──────────────────────────────────────────────────────────────
Udev :: distinct struct {}
UdevEnumerate :: distinct struct {}
UdevDevice :: distinct struct {}
UdevListEntry :: distinct struct {}
UdevMonitor :: distinct struct {}

// ─── udev core ─────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libudev {
	udev_new   :: proc() -> ^Udev ---
	udev_ref   :: proc(p: ^Udev) -> ^Udev ---
	udev_unref :: proc(udev: ^Udev) -> ^Udev ---
}

// ─── udev_enumerate (Device-Discovery) ─────────────────────────────────────────
@(default_calling_convention = "c")
foreign libudev {
	udev_enumerate_new :: proc(udev: ^Udev) -> ^UdevEnumerate ---
	udev_enumerate_unref :: proc(e: ^UdevEnumerate) -> ^UdevEnumerate ---

	udev_enumerate_add_match_subsystem :: proc(e: ^UdevEnumerate, subsystem: cstring) -> c.int ---
	udev_enumerate_add_match_sysname   :: proc(e: ^UdevEnumerate, sysname: cstring) -> c.int ---
	udev_enumerate_add_match_property  :: proc(e: ^UdevEnumerate, property: cstring, value: cstring) -> c.int ---
	udev_enumerate_add_match_is_initialized :: proc(e: ^UdevEnumerate) -> c.int ---

	udev_enumerate_scan_devices :: proc(e: ^UdevEnumerate) -> c.int ---
	udev_enumerate_get_list_entry :: proc(e: ^UdevEnumerate) -> ^UdevListEntry ---
}

// ─── udev_list_entry (Result-Iteration) ────────────────────────────────────────
@(default_calling_convention = "c")
foreign libudev {
	udev_list_entry_get_next  :: proc(e: ^UdevListEntry) -> ^UdevListEntry ---
	udev_list_entry_get_by_name :: proc(e: ^UdevListEntry, name: cstring) -> ^UdevListEntry ---
	udev_list_entry_get_name  :: proc(e: ^UdevListEntry) -> cstring ---
	udev_list_entry_get_value :: proc(e: ^UdevListEntry) -> cstring ---
}

// ─── udev_device ───────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libudev {
	udev_device_new_from_syspath :: proc(udev: ^Udev, syspath: cstring) -> ^UdevDevice ---
	udev_device_new_from_subsystem_sysname :: proc(udev: ^Udev, subsystem: cstring, sysname: cstring) -> ^UdevDevice ---
	udev_device_ref   :: proc(p: ^UdevDevice) -> ^UdevDevice ---
	udev_device_unref :: proc(p: ^UdevDevice) -> ^UdevDevice ---

	udev_device_get_devnode  :: proc(d: ^UdevDevice) -> cstring ---
	udev_device_get_syspath   :: proc(d: ^UdevDevice) -> cstring ---
	udev_device_get_sysname   :: proc(d: ^UdevDevice) -> cstring ---
	udev_device_get_subsystem :: proc(d: ^UdevDevice) -> cstring ---
	udev_device_get_property_value :: proc(d: ^UdevDevice, key: cstring) -> cstring ---
	udev_device_get_sysattr_value   :: proc(d: ^UdevDevice, attr: cstring) -> cstring ---

	udev_device_get_parent :: proc(d: ^UdevDevice) -> ^UdevDevice ---
	udev_device_get_parent_with_subsystem_devtype :: proc(
		d: ^UdevDevice, subsystem: cstring, devtype: cstring,
	) -> ^UdevDevice ---

	udev_device_get_action :: proc(d: ^UdevDevice) -> cstring ---
}

// ─── udev_monitor (Hotplug-Events) ─────────────────────────────────────────────
UDEV_MONITOR_UDEV :: 1

@(default_calling_convention = "c")
foreign libudev {
	udev_monitor_new_from_netlink :: proc(udev: ^Udev, source: cstring) -> ^UdevMonitor ---
	udev_monitor_unref            :: proc(m: ^UdevMonitor) -> ^UdevMonitor ---

	udev_monitor_filter_add_match_subsystem_devtype :: proc(
		m: ^UdevMonitor, subsystem: cstring, devtype: cstring,
	) -> c.int ---

	udev_monitor_filter_add_match_tag :: proc(m: ^UdevMonitor, tag: cstring) -> c.int ---

	udev_monitor_enable_receiving :: proc(m: ^UdevMonitor) -> c.int ---
	udev_monitor_get_fd            :: proc(m: ^UdevMonitor) -> c.int ---
	udev_monitor_receive_device    :: proc(m: ^UdevMonitor) -> ^UdevDevice ---
}

// ─── Constants ────────────────────────────────────────────────────────────────
UDEV_ACTION_ADD    :: "add"
UDEV_ACTION_REMOVE :: "remove"
UDEV_ACTION_CHANGE :: "change"