# rift DRM/KMS Backend — Implementierungsplan

## Was ist ein DRM/KMS-Backend?

### Grundkonzept

DRM (Direct Rendering Manager) ist der Linux-Kernel-Subsystem für
Grafikhardware-Zugriff. KMS (Kernel Mode Setting) ist der Teil von DRM,
der für das **Ansteuern von Monitoren** zuständig ist.

Aktuell läuft rift im **Nested-Modus**: rift ist ein Wayland-Client von
Hyprland. Hyprland spricht mit dem Kernel (DRM/KMS), und rift malt in
ein SHM-Buffer, das Hyprland auf den Bildschirm scanout-ed.

Ein **Standalone DRM-Backend** ersetzt Hyprland's Rolle: rift spricht
**direkt** mit dem Kernel, ohne Zwischenhändler.

### Die KMS-Pipeline

```
    rift Prozess
    ┌─────────────────────────────────────────────────────┐
    │  Wayland Server (Socket rift-0)                    │
    │  ├─ xdg-shell clients (foot, alacritty, …)         │
    │  ├─ Tiling-Tree Layout                             │
    │  └─ Compositor (composite_all)                     │
    │       │                                            │
    │       ▼                                            │
    │  DRM Backend                                       │
    │  ├─ DRM Framebuffer (from SHM buffer)              │
    │  ├─ Atomic Commit (modeset + page flip)            │
    │  ├─ Hardware Cursor (cursor plane)                │
    │  └─ libinput (keyboard/pointer events)             │
    │       │                                            │
    └───────┼────────────────────────────────────────────┘
            │
            ▼  (libdrm syscalls → kernel)
    ┌─────────────────────────────────────────────────────┐
    │  Linux Kernel                                       │
    │  ├─ DRM/KMS Subsystem                               │
    │  │  ├─ Connector (HDMI/DP/eDP)                     │
    │  │  ├─ CRTC (Scanout-Engine)                       │
    │  │  ├─ Plane (Primary + Cursor)                     │
    │  │  └─ Framebuffer → Monitor                        │
    │  └─ evdev (libinput liest davon)                   │
    └─────────────────────────────────────────────────────┘
```

### KMS-Objekte

| Objekt | Bedeutung | rift-Analogon |
|---|---|---|
| **Connector** | Physischer Monitor-Anschluss (HDMI, DP, eDP) | `wl_output` (nur virtuell aktuell) |
| **CRTC** | Scanout-Engine — liest Framebuffer, treibt Monitor | Composite-Pipeline |
| **Plane** | Layer im Scanout — Primary (Framebuffer) + Cursor | Compositing + Hardware-Cursor |
| **Framebuffer** | Pixel-Buffer, den der CRTC scanout-ed | SHM-Buffer (aktuell) |
| **Mode** | Auflösung + Refresh-Rate (z.B. 1920×1080@60) | Hardcoded 1920×1080@60 |

### Page Flip

Ein **Page Flip** tauscht den aktuell gescannten Framebuffer gegen einen
neuen aus — synchronisiert zum **VBlank** (Vertical Blank), um Tearing zu
vermeiden. Das ist der Mechanismus für VSync.

```
Frame 1 wird gescannt ──────► VBlank ──────► Frame 2 wird gescannt
                                          │
                                   Page-Flip-Event
                                   (rift kann nächsten Frame rendern)
```

---

## Vergleich: Hyprland/Aquamarine vs. wlroots vs. rift (geplant)

### Hyprland (via Aquamarine)

Aquamarine (~4400 LOC C++) implementiert den DRM-Backend für Hyprland:

```
Aquamarine Architektur:
├─ CDRMBackend           — Hauptklasse, GPU-Discovery (udev), Session (libseat)
├─ SDRMConnector         — Pro Monitor: Connector + CRTC + Planes
├─ CDRMOutput             — Wayland-Output-Interface
├─ CDRMFB                 — DRM Framebuffer (Buffer → KMS import)
├─ CDRMAtomicImpl         — Atomic Modesetting (drmModeAtomicCommit)
├─ CDRMLegacyImpl         — Legacy Modesetting (Fallback, drmModeSetCrtc)
├─ CDRMRenderer           — EGL/GL Renderer (GPU-blit, multi-GPU)
├─ CSession               — Session-Management (libseat/logind, VT-Switch)
├─ CSessionDevice          — Ein DRM-Device (fd, path)
├─ CSwapchain              — Double/Triple-Buffering für Outputs
└─ CGBMAllocator / CDRMDumbAllocator — Buffer-Allocation
```

Key-Patterns von Aquamarine:
- **udev für GPU-Discovery**: `udev_enumerate_add_match_subsystem("drm")`
- **libseat für Session**: VT-Acquisition, DRM-Master, Input-Device-Access
- **Atomic Modesetting (bevorzugt)**: `drmModeAtomicCommit()` statt `drmModeSetCrtc()`
- **Legacy Fallback**: `drmModeSetCrtc()` wenn Atomic nicht unterstützt
- **Property-basiert**: Jede KMS-Eigenschaft wird per ID gesucht und gesetzt
- **Page-Flip-Events**: `DRM_MODE_PAGE_FLIP_EVENT` → `drmHandleEvent()` → VSync
- **Multi-GPU**: Primärer GPU rendert, sekundärer blittet (mGPU-Rendering)
- **EGL/GBM für GPU-Rendering**: `gbm_surface`, `eglCreateWindowSurface`

### wlroots

wlroots (~2000 LOC C für DRM-Backend):
- Ähnliche Struktur wie Aquamarine (war die Inspiration)
- `backend/drm/atomic.c` — Atomic Commit
- `backend/drm/legacy.c` — Legacy Fallback
- `backend/drm/drm.c` — Hauptlogik
- `backend/drm/renderer.c` — EGL Renderer
- `wlr/seat.c` — Session via libseat oder logind

### rift (geplant)

rift muss das Gleiche tun, aber in **Odin** statt C/C++:

```
rift DRM-Backend (geplant):
├─ backend_drm.odin       — Hauptklasse: GPU-Discovery, KMS-Init, Event-Loop
├─ backend_drm_atomic.odin — Atomic Modesetting (drmModeAtomicCommit)
├─ backend_drm_legacy.odin  — Legacy Fallback (drmModeSetCrtc)
├─ backend_session.odin    — Session (libseat), VT-Switch, DRM-Master
├─ backend_input.odin      — libinput: Keyboard/Pointer/Touch events
├─ backend_drm_bindings.odin — Odin-Bindings für libdrm/libinput/libseat
└─ (Anpassung von server.odin, nested.odin, main.odin)
```

---

## Architektur für rift

### Backend-Abstraktion

rift soll **zwei Backends** unterstützen:

1. **Nested** (existierend): rift als Wayland-Client → `nested.odin`
2. **DRM** (neu): rift spricht direkt zum Kernel → `backend_drm.odin`

Beide Backends implementieren dasselbe Interface:

```odin
Backend :: struct {
    init:     proc() -> bool,
    get_fd:   proc() -> int,              // fd für Event-Loop
    dispatch: proc(),                      // Events verarbeiten
    clear:    proc(color: u32),           // Buffer leeren
    blit:     proc(src, sw, sh, dx, dy, dw, dh: i32),  // Buffer blitten
    commit:   proc(),                      // Frame auf Monitor ausgeben
    present:  proc(src: ^u32, w, h: i32), // Legacy: direkter Blit
    resize:   proc(w, h: i32),            // Buffer-Größe ändern
    cleanup:  proc(),
}
```

### Datenfluss: DRM-Backend

```
1. Client commitet SHM-Buffer
2. surface_commit() → composite_all()
3. composite_all():
   a. backend.clear(bg_color)           — Dumb-Buffer oder GBM-Surface leeren
   b. Für jedes Toplevel:
      backend.blit(client_shm, …)        — CPU-Blit in Scanout-Buffer
   c. backend.commit()                   — DRM Atomic Commit / Page Flip
4. drmHandleEvent() → Page-Flip-Event → Frame-Callback an Clients
5. Repeat (VSync-getrieben)
```

### Init-Sequenz

```
main()
├─ config_load()
├─ Server erstellen (wl_display, socket)
├─ Workspaces init
│
├─ Backend auswählen:
│  ├─ if WAYLAND_DISPLAY gesetzt → nested_init()  (existierend)
│  └─ else → drm_init()                             (NEU)
│
├─ register_globals()
├─ wl_display_add_socket("rift-0")
├─ Backend in Event-Loop einbinden
├─ autostart
└─ wl_display_run()
```

### Session-Management

rift muss eine "Session" erwerben, um auf Hardware zugreifen zu dürfen:

```
libseat-Flow:
├─ libseat_open_seat() → seat-Handle
├─ libseat_open_device("/dev/dri/card0") → drm-fd (DRM-Master)
├─ libseat_open_device("/dev/input/event0") → evdev-fd (Keyboard)
├─ VT-Switch: SIGUSR1 → libseat_dispatch → restore
└─ libseat_close_seat() → Cleanup
```

---

## Implementierungsplan — Phasen

### Phase 1: Odin-Bindings für libdrm, libinput, libseat, libudev

**Ziel:** Odin kann mit DRM/Input/Seat sprechen.

**Dateien:**
- `drm_bindings.odin` — libdrm C-Function-Bindings (drmOpen, drmModeGetResources, drmModeAtomicCommit, …)
- `input_bindings.odin` — libinput C-Function-Bindings
- `seat_bindings.odin` — libseat C-Function-Bindings
- `udev_bindings.odin` — libudev C-Function-Bindings

**Aufwand:** Mittel (~600 LOC). Viel Tipparbeit für struct-Definitionen.

**Pitfalls:**
- Odin's `foreign` import braucht exakte struct-Sizes
- `drmModeModeInfo` hat padding — muss 1:1 nachgebaut werden
- C-Bitfields (in libinput) gibt es in Odin nicht → manuell maskieren
- libseat's Callback-API braucht `proc "c"` mit context-Restore

**Key-Structs (müssen 1:1 nach Odin übersetzt werden):**
```odin
// Aus xf86drmMode.h
drmModeModeInfo :: struct {
    clock: u32,
    hdisplay, hsync_start, hsync_end, htotal, hskew: u16,
    vdisplay, vsync_start, vsync_end, vtotal, vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,
}

drmModeConnector :: struct {
    connector_id, encoder_id: u32,
    connector_type, connector_type_id: u32,
    connection: u32,  // DRM_MODE_CONNECTED etc.
    mm_width, mm_height: u32,
    subpixel: u32,
    count_modes: i32,
    modes: ^drmModeModeInfo,
    count_props: i32,
    props: ^u32, prop_values: ^u64,
    count_encoders: i32,
    encoders: ^u32,
}
```

### Phase 2: Session-Management (libseat + VT)

**Ziel:** rift bekommt DRM-Master und Input-Device-Access.

**Datei:** `backend_session.odin`

**Schritte:**
1. `libseat_open_seat(callbacks)` → seat-Handle
2. Devices enumerieren via udev: `/dev/dri/card0`, `/dev/input/event*`
3. `libseat_open_device(path)` → fd für DRM und Input
4. VT-Switch: `SIGUSR1` → `libseat_dispatch()` → re-modeset
5. Cleanup: `libseat_close_device()`, `libseat_close_seat()`

**Aufwand:** Mittel (~200 LOC)

**Pitfalls:**
- **libseat kann async sein** — Devices können später aktiviert werden
- **DRM-Master muss vor KMS-Operationen erworben werden** — `drmSetMaster(fd)`
- **VT-Switch während Page-Flip** → Kernel bricht Flip ab, rift muss neu modesetten
- **Permissions**: SDDM gibt den VT frei, aber libseat braucht `seat` group oder logind
- **SIGUSR1**: Alte X11-Convention, aber immer noch aktiv für VT-Handoff

### Phase 3: DRM-Backend — KMS-Init + Modesetting

**Ziel:** rift kann einen Monitor ansteuern (Modesetting + Page Flip).

**Datei:** `backend_drm.odin`

**Schritte:**
1. **GPU finden** (udev enumerate `drm` subsystem, `card0` bis `cardN`)
2. **DRM-Device öffnen** (libseat_open_device)
3. **Capabilities prüfen**:
   - `drmGetCap(DRM_CAP_PRIME)` — Buffer-Import
   - `drmGetCap(DRM_CAP_CRTC_IN_VBLANK_EVENT)` — Page-Flip-Events
   - `drmSetClientCap(DRM_CLIENT_CAP_UNIVERSAL_PLANES)` — alle Planes
   - `drmSetClientCap(DRM_CLIENT_CAP_ATOMIC)` — Atomic Modesetting
4. **Ressourcen enumerieren**:
   - `drmModeGetResources()` → CRTCs, Connectors
   - `drmModeGetPlaneResources()` → Planes
5. **Connectors scannen**:
   - Für jeden verbundenen Connector: Mode wählen, CRTC zuweisen
   - `drmModeGetConnector()` → Modes lesen
6. **Modeset durchführen**:
   - Atomic: `drmModeAtomicAlloc()` → Properties setzen → `drmModeAtomicCommit()`
   - Legacy Fallback: `drmModeSetCrtc()`
7. **Dumb-Buffer erstellen** (für CPU-Rendering):
   - `drmModeCreateDumb()` → `drmModeAddFB()` → `mmap()` → Pixel schreiben
8. **Page Flip**:
   - `drmModeAtomicCommit(PAGE_FLIP_EVENT)` → `drmHandleEvent()` → VSync

**Aufwand:** Hoch (~600-800 LOC)

**Pitfalls:**
- **Atomic Properties sind per ID, nicht per Name**: Jedes Property muss
  via `drmModeObjectGetProperties()` → Name-Suche gefunden werden
- **src_w/src_h sind 16.16 Fixed-Point**: `width << 16`, nicht `width`
- **Mode-Blob**: Atomic muss Mode als Blob-Property gesetzt werden
  (`drmModeCreatePropertyBlob`)
- **Cursor-Plane-Größe**: Hardware-Cursor hat feste Größe (meist 64×64 oder 256×256)
- **Format-Support**: Nicht alle Planes unterstützen alle Formate.
  `drmModeGetPlane()` → `count_formats` prüfen
- **Multiple Connectors/CRTCs**: CRTC muss zum Connector passen
  (`possible_crtcs` Bitmask)
- **Hotplug**: udev-Events für Connector-Connect/Disconnect müssen behandelt werden
- **Atomic Commit kann fehlschlagen**: Test-Commit vor echtem Commit
  (`DRM_MODE_ATOMIC_TEST_ONLY`)
- **Legacy vs. Atomic**: Nicht alle GPUs unterstützen Atomic.
  Fallback auf `drmModeSetCrtc()` implementieren

### Phase 4: libinput-Backend (Keyboard + Pointer)

**Ziel:** rift empfängt Keyboard/Pointer-Events direkt vom Kernel (via libinput).

**Datei:** `backend_input.odin`

**Schritte:**
1. `libinput_udev_create_context()` → libinput-Handle
2. `libinput_get_fd()` → fd in Event-Loop einbinden
3. `libinput_dispatch()` → Events lesen
4. **Keyboard-Events** → `input_keyboard_key(key, state)` (existierend!)
5. **Pointer-Events** → `input_pointer_motion(x, y)` (existierend!)
6. **Seat-Devices**: `libinput_device_get_seat()` → nur eigene Seat-Devices
7. **Keymap**: `libinput_keyboard_get_keymap()` → an Clients weitergeben

**Aufwand:** Mittel (~300 LOC)

**Pitfalls:**
- **libinput braucht udev** — Device-Discovery via `libinput_udev_create_context`
  mit `udev_new()`
- **Keyboard-Keymap**: libinput liefert xkb_keymap, rift braucht aber
  einen fd für `wl_keyboard.keymap` → `xkbcommon` kompilieren und
  `xkb_keymap_get_as_string()` → `memfd_create()` → fd weitergeben
- **Absolute vs. Relative Pointer**: Tablets/Touchscreens haben absolute
  Koordinaten, Mäuse relative
- **Tastenwiederholung**: libinput liefert keine Repeat-Events →
  rift muss eigenen Timer implementieren (aktuell vom Parent geliefert)
- **Device-Hotplug**: Keyboard/Maus an-/abstecken → Events verarbeiten
- **Modifiers**: libinput liefert `LIBINPUT_KEY_STATE_*` für jede Taste.
  rift muss Modifier-State selbst tracken (XKB oder manuell)

### Phase 5: Hardware-Cursor

**Ziel:** Mauszeiger wird vom Hardware-Cursor-Plane gerendert (kein Software-Cursor).

**Schritte:**
1. Cursor-Plane finden (`drmModeGetPlaneResources` → type=CURSOR)
2. Cursor-Buffer erstellen (`drmModeCreateDumb` → `drmModeAddFB`)
3. Cursor-Bild in Buffer schreiben (von libwayland-cursor oder manuell)
4. `drmModeSetCursor(fd, crtc_id, bo_handle, width, height)`
5. `drmModeMoveCursor(fd, crtc_id, x, y)`
6. Cursor in Atomic-Commit einbinden

**Aufwand:** Mittel (~150 LOC)

**Pitfalls:**
- **Cursor-Größe limitiert**: `DRM_CAP_CURSOR_WIDTH/HEIGHT` → meist 64×64
- **Cursor-Buffer-Format**: ARGB8888 ist Standard, aber nicht garantiert
- **Cursor auf sekundärem Monitor**: Jeder CRTC braucht eigenen Cursor
- **Cursor-Hotspot**: Hardware-Cursor unterstützt Hotspot nicht immer
  → manuell via `drmModeSetCursor2()` (mit hotspot) oder Offset

### Phase 6: Integration in rift's Event-Loop

**Ziel:** DRM und libinput in rift's `wl_event_loop` einbinden.

**Schritte:**
1. `drm_fd` in Event-Loop (`wl_event_loop_add_fd`, wie `nested_dispatch`)
2. `libinput_fd` in Event-Loop
3. `udev_fd` in Event-Loop (für Hotplug)
4. DRM-Event-Handler: `drmHandleEvent()` → Page-Flip-Callback → Frame-Render
5. libinput-Event-Handler: `libinput_dispatch()` → Input-Events

**Aufwand:** Gering (~100 LOC, baut auf existierender Event-Loop-Integration auf)

**Pitfalls:**
- **Re-Entrancy**: Page-Flip-Callback kann neuen Frame triggern, der
  neuen Page-Flip anfordert → Deadlock vermeiden (Flag `is_page_flip_pending`)
- **Event-Loop-Blockierung**: `drmHandleEvent()` blockiert nicht, aber
  muss rechtzeitig aufgerufen werden (Kernel-Event-Queue hat Limit)
- **libinput muss dispatch'd werden VOR dem Lesen** — sonst gibt es
  `libinput_next_event()` Fehler

### Phase 7: Multi-Output (Multi-Monitor)

**Ziel:** rift unterstützt mehrere Monitore.

**Schritte:**
1. Pro Connector: eigenes `wl_output`-Global
2. Pro Output: eigener Dumb-Buffer + eigener CRTC
3. `composite_all()` → pro Output compositen
4. Workspace-Output-Zuweisung (wie Hyprland)
5. Hotplug: udev-Event → Connector-Scan → wl_output hinzufügen/entfernen

**Aufwand:** Mittel (~200 LOC, baut auf Workspace-Infrastruktur auf)

**Pitfalls:**
- **CRTC-Knappheit**: GPU hat limitierte CRTCs (meist 3-6). Wenn mehr
  Monitore als CRTCs angeschlossen → some stay dark
- **Clone-Mode vs. Extend**: rift sollte Extend (wie Hyprland), nicht Clone
- **EDID-basierte Output-Namen**: `DP-1`, `HDMI-A-1`, `eDP-1` statt `rift-0`

### Phase 8: SDDM-Integration (final)

**Ziel:** rift erscheint in SDDM und läuft standalone.

**Schritte:**
1. `rift.desktop` — `Exec=rift` (kein Wrapper mehr nötig!)
2. VT-Handling: `KDSETMODE(KD_GRAPHICS)`, SIGUSR1 für VT-Switch
3. Environment: `XDG_SESSION_TYPE=wayland` (von SDDM gesetzt)
4. Cleanup bei Exit: `KDSETMODE(KD_TEXT)`, DRM-Master releasen
5. Crash-Recovery: Signal-Handler der VT auf TEXT setzt

**Aufwand:** Gering (~50 LOC in Session-Management, bereits in Phase 2 begonnen)

**Pitfalls:**
- **SDDM gibt VT frei, aber compositor muss KD_GRAPHICS setzen** — sonst
  konkuriert der Kernel-Framebuffer mit DRM-Scanout
- **VT-Switch (Ctrl+Alt+F2)**: Kernel sendet SIGUSR1 → Compositor muss
  DRM-Master releasen → auf SIGUSR2 warten → re-modeset
- **Crash ohne Cleanup**: VT bleibt in KD_GRAPHICS → schwarzer Bildschirm.
  Signal-Handler für SIGSEGV/SIGABRT der VT auf TEXT setzt

---

## Pitfalls — Komplette Liste

### Kritisch (kann zu Blackscreen/Crash führen)

1. **DRM-Master nicht erworben** → alle KMS-Aufrufe schlagen fehl mit -EINVAL
   - Lösung: `drmSetMaster(fd)` nach `libseat_open_device()`

2. **Atomic Commit mit falschen Properties** → -EINVAL oder -ERANGE
   - Lösung: Properties per `drmModeObjectGetProperties()` finden,
     nicht per Name hardcoden

3. **src_w/src_h als 16.16 Fixed-Point** → verzerrtes Bild
   - Lösung: `width << 16`, wie in Aquamarine: `((uint64_t)fb->size.x) << 16`

4. **Page-Flip ohne Event-Flag** → rift weiss nicht, wann VBlank passiert
   - Lösung: `DRM_MODE_PAGE_FLIP_EVENT` in Commit-Flags setzen

5. **VT-Switch ohne DRM-Master-Release** → Kernel tötet Prozess
   - Lösung: SIGUSR1-Handler, `drmDropMaster()`, dann re-acquire

6. **Dumb-Buffer-Format nicht unterstützt** → `drmModeAddFB2` schlägt fehl
   - Lösung: `drmModeGetPlane()` → `count_formats` prüfen, XRGB8888 ist
     fast immer dabei

7. **mmap ohne MAP_SHARED** → Pixel nicht sichtbar auf Scanout
   - Lösung: `mmap(nil, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)`

8. **Atomic Commit ohne ALLOW_MODESET bei Modeset** → -EINVAL
   - Lösung: Bei Mode-Wechsel `DRM_MODE_ATOMIC_ALLOW_MODESET` flag setzen

### Mittel (kann zu komischem Verhalten führen)

9. **libinput fd nicht dispatched vor `libinput_get_event()`** → veraltete Events
   - Lösung: immer `libinput_dispatch()` vor Event-Reading aufrufen

10. **Keyboard-Keymap fd leaked** → fd-Exhaustion bei vielen Client-Connects
    - Lösung: fd pro Client dup'en (wie schon im Nested-Mode gemacht)

11. **Cursor-Buffer zu gross** → `drmModeSetCursor` schlägt fehl
    - Lösung: `DRM_CAP_CURSOR_WIDTH/HEIGHT` abfragen, Cursor skalieren

12. **Hotplug-Event nicht behandelt** → angeschlossener Monitor bleibt dunkel
    - Lösung: udev-Monitor für `drm` subsystem, `SDRM_CONNECTOR` rescan

13. **Tastenwiederholung fehlt** → Clients bekommen keine Repeat-Events
    - Lösung: Eigenen Timer mit `wl_event_loop_add_timer()` implementieren

### Niedrig (Cosmetic / Edge-Case)

14. **Gamma/LUT nicht unterstützt** → Night-Light-Tools funktionieren nicht
    - (später: `wlr-gamma-control-v1`)

15. **HDR/Metadata Properties** → aktuell nicht relevant für rift
    - (überspringen in Phase 1)

16. **Multi-GPU** → rift soll erst mal single-GPU
    - (später: mGPU-Blit wie Aquamarine)

---

## Dependencies

| Library | Zweck | rift-Datei | Installiert? |
|---|---|---|---|
| `libdrm` | DRM/KMS API | `drm_bindings.odin` | ✅ |
| `libgbm` | Buffer-Allocation (GPU) | `drm_bindings.odin` | ✅ |
| `libinput` | Input-Events | `input_bindings.odin` | ✅ |
| `libseat` | Session/Seat-Management | `seat_bindings.odin` | ✅ |
| `libudev` | Device-Discovery/Hotplug | `udev_bindings.odin` | ✅ |
| `libxkbcommon` | Keymap-Generierung | `input_bindings.odin` | ✅ (via Hyprland) |

### Linker-Flags (neu)

```makefile
DRM_LIBS := -ldrm -lgbm -linput -lseat -ludev -lxkbcommon
```

### Neue .o-Dateien

Keine — im Gegensatz zu wayland-server braucht libdrm keine
`wayland-scanner`-generierten Objekte. Die C-Header werden via
`foreign import` direkt von Odin gebunden.

---

## Aufwandsschätzung

| Phase | LOC (neu) | Aufwand | Risiko |
|---|---|---|---|
| 1. Bindings | ~600 | Mittel | Niedrig (Tipparbeit) |
| 2. Session | ~200 | Mittel | Mittel (libseat-API) |
| 3. KMS-Init + Modeset | ~800 | Hoch | Hoch (viele Edge-Cases) |
| 4. libinput | ~300 | Mittel | Mittel (xkbcommon) |
| 5. Hardware-Cursor | ~150 | Mittel | Niedrig |
| 6. Event-Loop-Integration | ~100 | Gering | Niedrig |
| 7. Multi-Output | ~200 | Mittel | Mittel |
| 8. SDDM-Final | ~50 | Gering | Niedrig |
| **Total** | **~2400** | **Hoch** | |

---

## Empfohlene Reihenfolge

```
Phase 1 (Bindings) ────────────────────────────────────► Phase 2 (Session)
    │                                                        │
    ▼                                                        ▼
Phase 3 (KMS-Init) ──────► Phase 6 (Event-Loop) ──► Phase 4 (libinput)
    │                                                        │
    ▼                                                        ▼
Phase 5 (Cursor) ──────────────────────────────────────► Phase 8 (SDDM)
    │
    ▼
Phase 7 (Multi-Output) [optional, später]
```

**Empfehlung:** Phase 1+2+3+6 zuerst → rift kann einen Monitor ansteuern
(Modeset + Page Flip + CPU-Rendering). Dann Phase 4+5 → Input + Cursor.
Phase 7+8 sind Polish.

---

## Testing-Strategie

### Ohne Hardware-Wechsel (in Hyprland-Session)

DRM-Backend kann **nicht** in Hyprland getestet werden (Hyprland hält
den DRM-Master). Testen braucht einen VT-Switch.

### Testing im TTY

1. `Ctrl+Alt+F3` → TTY 3
2. `rift` starten → sollte Modeset durchführen, Bildschirm wird schwarz
   dann rift-Compositing zeigen
3. `WAYLAND_DISPLAY=rift-0 foot` (anderes TTY oder SSH) → Fenster erscheint
4. `Ctrl+Alt+F1` → zurück zu Hyprland

### Safety-Net

- **Signal-Handler**: SIGSEGV → `drmDropMaster()` + `KDSETMODE(KD_TEXT)`
  → VT wird wieder normal, kein Blackscreen
- **Timer**: Nach 10 Sekunden ohne Page-Flip → automatisch KD_TEXT
- **Fallback**: Wenn DRM-Init fehlschlägt → Fehlermeldung + Exit (kein Crash)