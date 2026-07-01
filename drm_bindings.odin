package main

import "core:c"

// ═══════════════════════════════════════════════════════════════════════════
//  libdrm / KMS Bindings für Odin
//
//  Bindet libdrm (Direct Rendering Manager) und KMS (Kernel Mode Setting)
//  Funktionen aus <xf86drm.h> und <xf86drmMode.h> an Odin.
//
//  Alle Structs sind 1:1 Übersetzungen der C-Definitionen mit korrektem
//  Padding und Alignment für x86_64.
// ═══════════════════════════════════════════════════════════════════════════

foreign import libdrm "system:drm"

// ═══════════════════════════════════════════════════════════════════════════
//  DRM Core Functions (xf86drm.h)
// ═══════════════════════════════════════════════════════════════════════════

// ─── Device Open/Close ──────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmOpen         :: proc(name: cstring, busid: cstring) -> c.int ---
	drmClose        :: proc(fd: c.int) -> c.int ---
	drmAvailable    :: proc() -> c.int ---
	drmIoctl        :: proc(fd: c.int, request: c.long, arg: rawptr) -> c.int ---
}

// ─── Master / Capabilities ────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmSetMaster  :: proc(fd: c.int) -> c.int ---
	drmDropMaster :: proc(fd: c.int) -> c.int ---
	drmIsMaster   :: proc(fd: c.int) -> c.int ---
	drmGetCap      :: proc(fd: c.int, cap: u64, value: ^u64) -> c.int ---
	drmSetClientCap :: proc(fd: c.int, cap: u64, value: u64) -> c.int ---
}

// ─── Constants ────────────────────────────────────────────────────────────────
DRM_CAP_DUMB_BUFFER          :: 0x1
DRM_CAP_VBLANK_HIGH_CRTC     :: 0x2
DRM_CAP_DUMB_PREFERRED_DEPTH :: 0x3
DRM_CAP_DUMB_PREFER_SHADOW    :: 0x4
DRM_CAP_PRIME                :: 0x5
DRM_CAP_TIMESTAMP_MONOTONIC  :: 0x6
DRM_CAP_ASYNC_PAGE_FLIP      :: 0x7
DRM_CAP_CURSOR_WIDTH         :: 0x8
DRM_CAP_CURSOR_HEIGHT        :: 0x9
DRM_CAP_ADDFB2_MODIFIERS     :: 0x10
DRM_CAP_CRTC_IN_VBLANK_EVENT :: 0x12
DRM_CAP_SYNCOBJ_TIMELINE     :: 0x14

DRM_PRIME_CAP_IMPORT :: 0x1
DRM_PRIME_CAP_EXPORT :: 0x2

DRM_CLIENT_CAP_STEREO_3D       :: 1
DRM_CLIENT_CAP_UNIVERSAL_PLANES :: 2
DRM_CLIENT_CAP_ATOMIC          :: 3
DRM_CLIENT_CAP_ASPECT_RATIO    :: 4

// ─── Event Handling (Page-Flip / VBlank) ────────────────────────────────────
DRM_EVENT_CONTEXT_VERSION :: 4

PageFlipHandler2 :: proc "c" (
	fd:       c.int,
	sequence: c.uint,
	tv_sec:   c.uint,
	tv_usec:  c.uint,
	crtc_id:  c.uint,
	user_data: rawptr,
)

VBlankHandler :: proc "c" (
	fd:       c.int,
	sequence: c.uint,
	tv_sec:   c.uint,
	tv_usec:  c.uint,
	user_data: rawptr,
)

SequenceHandler :: proc "c" (
	fd:        c.int,
	sequence:  u64,
	ns:        u64,
	user_data: u64,
)

// drmEventContext — Version 4 mit page_flip_handler2
DrmEventContext :: struct {
	version:            c.int,
	vblank_handler:     VBlankHandler,
	page_flip_handler:  PageFlipHandler2, // v1 handler (wir nutzen v2)
	page_flip_handler2: PageFlipHandler2,
	sequence_handler:   SequenceHandler,
}

@(default_calling_convention = "c")
foreign libdrm {
	drmHandleEvent :: proc(fd: c.int, evctx: ^DrmEventContext) -> c.int ---
}

// ═══════════════════════════════════════════════════════════════════════════
//  KMS Structs (xf86drmMode.h)
// ═══════════════════════════════════════════════════════════════════════════

// ─── DRM Mode Info ───────────────────────────────────────────────────────────
DrmModeInfo :: struct {
	clock:          u32,
	hdisplay:       u16,
	hsync_start:    u16,
	hsync_end:      u16,
	htotal:         u16,
	hskew:          u16,
	vdisplay:       u16,
	vsync_start:    u16,
	vsync_end:      u16,
	vtotal:         u16,
	vscan:          u16,
	vrefresh:       u32,
	flags:          u32,
	type_:          u32,  // 'type' is Odin keyword
	name:           [32]u8,
}

// DRM_MODE_FLAG_*
DRM_MODE_FLAG_PHSYNC     :: 1 << 0
DRM_MODE_FLAG_NHSYNC     :: 1 << 1
DRM_MODE_FLAG_PVSYNC     :: 1 << 2
DRM_MODE_FLAG_NVSYNC     :: 1 << 3
DRM_MODE_FLAG_INTERLACE  :: 1 << 4
DRM_MODE_FLAG_DBLSCAN    :: 1 << 5

// DRM_MODE_TYPE_*
DRM_MODE_TYPE_BUILTIN    :: 0x1
DRM_MODE_TYPE_PREFERRED  :: 0x8
DRM_MODE_TYPE_DEFAULT    :: 0x10
DRM_MODE_TYPE_DRIVER     :: 0x40

// ─── DRM Resources ───────────────────────────────────────────────────────────
DrmModeRes :: struct {
	count_fbs:      c.int,
	fbs:            ^u32,
	count_crtcs:    c.int,
	crtcs:          ^u32,
	count_connectors: c.int,
	connectors:     ^u32,
	count_encoders: c.int,
	encoders:       ^u32,
	min_width:      u32,
	max_width:      u32,
	min_height:     u32,
	max_height:     u32,
}

// ─── DRM Connector ──────────────────────────────────────────────────────────────
DRM_MODE_CONNECTED    :: 1
DRM_MODE_DISCONNECTED :: 2
DRM_MODE_UNKNOWNCON   :: 3

DRM_MODE_CONNECTOR_VGA          :: 1
DRM_MODE_CONNECTOR_DVII          :: 2
DRM_MODE_CONNECTOR_DVID          :: 3
DRM_MODE_CONNECTOR_DVIA          :: 4
DRM_MODE_CONNECTOR_Composite     :: 5
DRM_MODE_CONNECTOR_SVIDEO        :: 6
DRM_MODE_CONNECTOR_LVDS          :: 7
DRM_MODE_CONNECTOR_Component     :: 8
DRM_MODE_CONNECTOR_9PinDIN       :: 9
DRM_MODE_CONNECTOR_DisplayPort    :: 10
DRM_MODE_CONNECTOR_HDMIA         :: 11
DRM_MODE_CONNECTOR_HDMIB         :: 12
DRM_MODE_CONNECTOR_TV            :: 13
DRM_MODE_CONNECTOR_eDP           :: 14
DRM_MODE_CONNECTOR_VIRTUAL       :: 15
DRM_MODE_CONNECTOR_DSI           :: 16
DRM_MODE_CONNECTOR_DPI           :: 17

DrmModeConnector :: struct {
	connector_id:      u32,
	encoder_id:        u32,
	connector_type:    u32,
	connector_type_id: u32,
	connection:        u32,
	mmWidth:           u32,
	mmHeight:          u32,
	subpixel:          u32,
	count_modes:       c.int,
	modes:             ^DrmModeInfo,
	count_props:       c.int,
	props:             ^u32,
	prop_values:       ^u64,
	count_encoders:    c.int,
	encoders:          ^u32,
}

// ─── DRM CRTC ──────────────────────────────────────────────────────────────────
DrmModeCrtc :: struct {
	crtc_id:    u32,
	buffer_id:  u32,
	x:          u32,
	y:          u32,
	width:      u32,
	height:     u32,
	mode_valid: c.int,
	mode:       DrmModeInfo,
	gamma_size: c.int,
}

// ─── DRM Encoder ───────────────────────────────────────────────────────────────
DrmModeEncoder :: struct {
	encoder_id:     u32,
	encoder_type:   u32,
	crtc_id:        u32,
	possible_crtcs: u32,
	possible_clones: u32,
}

// ─── DRM Plane ────────────────────────────────────────────────────────────────
DRM_PLANE_TYPE_OVERLAY :: 0
DRM_PLANE_TYPE_PRIMARY :: 1
DRM_PLANE_TYPE_CURSOR  :: 2

DrmModePlane :: struct {
	count_formats:  u32,
	formats:        ^u32,
	plane_id:       u32,
	crtc_id:        u32,
	fb_id:          u32,
	crtc_x:         u32,
	crtc_y:         u32,
	x:              u32,
	y:              u32,
	possible_crtcs: u32,
	gamma_size:     u32,
}

DrmModePlaneRes :: struct {
	count_planes: u32,
	planes:        ^u32,
}

// ─── DRM Object Properties ─────────────────────────────────────────────────────
DrmModeObjectProperties :: struct {
	count_props:  u32,
	props:        ^u32,
	prop_values:  ^u64,
}

// ─── DRM Property ──────────────────────────────────────────────────────────────
DRM_MODE_PROP_RANGE     :: 1 << 1
DRM_MODE_PROP_IMMUTABLE :: 1 << 2
DRM_MODE_PROP_ENUM      :: 1 << 3
DRM_MODE_PROP_BLOB      :: 1 << 4
DRM_MODE_PROP_BITMASK   :: 1 << 5

DrmModePropertyRes :: struct {
	prop_id:      u32,
	count_values:  c.int,
	values:       ^u64,
	count_enums:   c.int,
	enums:        ^DrmModePropertyEnum,
	flags:        u32,
	name:         [32]u8,
}

DrmModePropertyEnum :: struct {
	value:      u64,
	name:       [32]u8,
}

// ─── Dumb Buffer (CPU-Rendering) ─────────────────────────────────────────────────
// Die API nimmt individuelle Parameter, nicht Structs.

// ─── Atomic Modesetting ────────────────────────────────────────────────────────
DrmModeAtomicReq :: distinct struct {}

DRM_MODE_ATOMIC_TEST_ONLY    :: 0x0100
DRM_MODE_ATOMIC_NONBLOCK     :: 0x0200
DRM_MODE_ATOMIC_ALLOW_MODESET :: 0x0400

DRM_MODE_PAGE_FLIP_EVENT      :: 0x01
DRM_MODE_PAGE_FLIP_ASYNC      :: 0x02

// Cursor ioctl flags
DRM_MODE_CURSOR_BO   :: 0x01
DRM_MODE_CURSOR_MOVE  :: 0x02

// ─── DRM Formats ────────────────────────────────────────────────────────────────
// DRM fourcc codes — pre-computed from fourcc_code macro
// fourcc_code(a,b,c,d) = a | (b << 8) | (c << 16) | (d << 24)
DRM_FORMAT_XRGB8888 :: 0x34325258  // 'X','R','2','4'
DRM_FORMAT_ARGB8888 :: 0x34325241  // 'A','R','2','4'
DRM_FORMAT_XBGR8888 :: 0x34324258  // 'X','B','2','4'
DRM_FORMAT_ABGR8888 :: 0x34324241  // 'A','B','2','4'

// ═══════════════════════════════════════════════════════════════════════════
//  KMS Function Bindings
// ═══════════════════════════════════════════════════════════════════════════

// ─── Resource Enumeration ─────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeGetResources         :: proc(fd: c.int) -> ^DrmModeRes ---
	drmModeFreeResources         :: proc(ptr: ^DrmModeRes) ---

	drmModeGetConnector         :: proc(fd: c.int, connector_id: u32) -> ^DrmModeConnector ---
	drmModeFreeConnector        :: proc(ptr: ^DrmModeConnector) ---

	drmModeGetCrtc              :: proc(fd: c.int, crtc_id: u32) -> ^DrmModeCrtc ---
	drmModeFreeCrtc             :: proc(ptr: ^DrmModeCrtc) ---

	drmModeGetEncoder           :: proc(fd: c.int, encoder_id: u32) -> ^DrmModeEncoder ---
	drmModeFreeEncoder          :: proc(ptr: ^DrmModeEncoder) ---

	drmModeGetPlaneResources    :: proc(fd: c.int) -> ^DrmModePlaneRes ---
	drmModeFreePlaneResources   :: proc(ptr: ^DrmModePlaneRes) ---

	drmModeGetPlane             :: proc(fd: c.int, plane_id: u32) -> ^DrmModePlane ---
	drmModeFreePlane            :: proc(ptr: ^DrmModePlane) ---

	drmModeFreeModeInfo         :: proc(ptr: ^DrmModeInfo) ---

	// ── KMS check ──────────────────────────────────────────────────────────
	drmIsKMS                   :: proc(fd: c.int) -> c.int ---
}

// ─── Object Properties ─────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeObjectGetProperties  :: proc(fd: c.int, object_id: u32, object_type: u32) -> ^DrmModeObjectProperties ---
	drmModeFreeObjectProperties :: proc(ptr: ^DrmModeObjectProperties) ---

	drmModeGetProperty          :: proc(fd: c.int, property_id: u32) -> ^DrmModePropertyRes ---
	drmModeFreeProperty         :: proc(ptr: ^DrmModePropertyRes) ---
}

// ─── Modesetting (Legacy) ─────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeSetCrtc :: proc(
		fd: c.int, crtc_id: u32,
		buffer_id: u32,
		x: u32, y: u32,
		connectors: ^u32, count: c.int,
		mode: ^DrmModeInfo,
	) -> c.int ---

	drmModeSetCursor :: proc(
		fd: c.int, crtc_id: u32,
		bo_handle: u32,
		width: u32, height: u32,
	) -> c.int ---

	drmModeSetCursor2 :: proc(
		fd: c.int, crtc_id: u32,
		bo_handle: u32,
		width: u32, height: u32,
		hot_x: i32, hot_y: i32,
	) -> c.int ---

	drmModeMoveCursor :: proc(
		fd: c.int, crtc_id: u32,
		x: i32, y: i32,
	) -> c.int ---

	drmModePageFlip :: proc(
		fd: c.int, crtc_id: u32,
		fb_id: u32,
		flags: u32,
		user_data: rawptr,
	) -> c.int ---
}

// ─── Dumb Buffer ─────────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeCreateDumbBuffer  :: proc(fd: c.int, width, height, bpp, flags: u32, handle, pitch: ^u32, size: ^u64) -> c.int ---
	drmModeMapDumbBuffer      :: proc(fd: c.int, handle: u32, offset: ^u64) -> c.int ---
	drmModeDestroyDumbBuffer  :: proc(fd: c.int, handle: u32) -> c.int ---
}

// ─── Framebuffer ──────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeAddFB  :: proc(fd: c.int, width, height: u32, pitch: u32, bpp: u32, depth: u32, handle: u32, fb_id: ^u32) -> c.int ---
	drmModeAddFB2 :: proc(fd: c.int, width, height: u32, format: u32, handles: ^u32, pitches: ^u32, offsets: ^u32, fb_id: ^u32, flags: u32) -> c.int ---
	drmModeRmFB   :: proc(fd: c.int, fb_id: u32) -> c.int ---
}

// ─── Property Blob ──────────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeCreatePropertyBlob  :: proc(fd: c.int, data: rawptr, length: u32, blob_id: ^u32) -> c.int ---
	drmModeDestroyPropertyBlob :: proc(fd: c.int, blob_id: u32) -> c.int ---
}

// ─── Atomic Modesetting ────────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeAtomicAlloc        :: proc() -> ^DrmModeAtomicReq ---
	drmModeAtomicFree         :: proc(req: ^DrmModeAtomicReq) ---
	drmModeAtomicAddProperty  :: proc(req: ^DrmModeAtomicReq, object_id: u32, property_id: u32, value: u64) -> c.int ---
	drmModeAtomicCommit       :: proc(fd: c.int, req: ^DrmModeAtomicReq, flags: u32, user_data: rawptr) -> c.int ---
	drmModeAtomicGetCursor    :: proc(req: ^DrmModeAtomicReq) -> c.int ---
	drmModeAtomicSetCursor    :: proc(req: ^DrmModeAtomicReq, cursor: c.int) ---
}

// ─── Connector Property ──────────────────────────────────────────────────────
@(default_calling_convention = "c")
foreign libdrm {
	drmModeConnectorSetProperty :: proc(fd: c.int, connector_id: u32, property_id: u32, value: u64) -> c.int ---
}

// ═══════════════════════════════════════════════════════════════════════════
//  Helper Procedures (Odin-Native)
// ═══════════════════════════════════════════════════════════════════════════

// ─── Property per Name finden ──────────────────────────────────────────────────
drm_find_property :: proc(
	fd: c.int,
	object_id: u32,
	object_type: u32,
	name: string,
) -> (prop_id: u32, value: u64, ok: bool) {
	props := drmModeObjectGetProperties(fd, object_id, object_type)
	if props == nil do return 0, 0, false
	defer drmModeFreeObjectProperties(props)

	prop_ids := cast([^]u32) rawptr(props.props)
	prop_vals := cast([^]u64) rawptr(props.prop_values)

	for i in 0..<props.count_props {
		prop := drmModeGetProperty(fd, prop_ids[i])
		if prop == nil do continue
		c_len := 0
		for c_len < 31 && prop.name[c_len] != 0 do c_len += 1
		prop_name := string(prop.name[:c_len])
		if prop_name == name {
			prop_id = prop.prop_id
			value = prop_vals[i]
			drmModeFreeProperty(prop)
			return prop_id, value, true
		}
		drmModeFreeProperty(prop)
	}
	return 0, 0, false
}

// ─── DRM Primary Minor Name (für udev) ─────────────────────────────────────────
DRM_PRIMARY_MINOR_NAME :: "card"