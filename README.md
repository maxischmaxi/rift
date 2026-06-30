<div align="center">

# rift

**A Wayland compositor and tiling window manager, written in Odin.**

A dynamic tiling compositor in the spirit of Hyprland and i3 — but built from
scratch in a single, memory-safe language with zero C dependencies in the
core logic.

</div>

---

## What is rift?

rift is a **Wayland compositor** that doubles as a **tiling window manager**.
It speaks the Wayland protocol, manages windows, and composites them to a
display — the same job Hyprland does.

Like Hyprland, rift uses a **dynamic split-tree tiling layout**: every new
window splits the focused tile, and the tree auto-collapses when windows
close. You move windows by dragging, resize by pulling split boundaries, and
cycle focus with the keyboard.

Unlike Hyprland, rift is:
- **Written in Odin** — no C, no C++, no build-time code generation in the
  core. The only generated code is the Wayland protocol interface data
  (via `wayland-scanner`, standard for every compositor).
- **Nested-capable** — rift can run *inside* an existing Wayland session as
  a client. It opens a window in your current compositor (Hyprland, Sway,
  GNOME, …) and composites into it. This makes development safe and
  iteration fast: no DRM modesetting, no black screens, no rebooting.
- **Small** — the core is ~1700 lines of Odin across 6 files.

## Features

### Window Management
- **Split-tree tiling** — binary tree layout like Hyprland's dwindle or i3.
  New windows split the focused tile (orientation chosen by aspect ratio).
- **Floating windows** — toggle any window between tiled and floating with
  `Super`+`Space`. Floating windows can be freely moved and resized.
- **Move** — `Super`+left-drag to move windows. Tiled windows swap
  positions; floating windows move freely.
- **Resize** — `Super`+right-drag to resize. Tiled windows adjust the
  split ratio; floating windows resize to any dimensions.
- **Keyboard shortcuts** — `Super`+`Tab` to swap focus, `Super`+arrows to
  resize the focused window, `Super`+`Space` to toggle floating.
- **Click-to-focus** — click any tile to focus it (keyboard + pointer).
- **Auto-retile** — closing a window collapses the tree and reflows.

### Compositor
- **wl_compositor** — surfaces, regions, double-buffered state.
- **wl_shm** — shared-memory buffers (CPU rendering, no GPU required).
- **wl_seat** — keyboard + pointer forwarding with keymap, repeat, focus.
- **wl_output** — virtual output.
- **xdg-shell** — full toplevel lifecycle: configure handshake, title
  tracking, map/unmap, popup resources (no-op).
- **wp_viewporter** — logical coordinate normalization for HiDPI.
- **libwayland-cursor** — hardware cursor rendering (left_ptr theme).

### Rendering
- **Nearest-neighbor scaling** — client buffers are blitted into the output
  at their assigned tile geometry.
- **SHM-only** — no EGL, no GPU, no DRM. Pure CPU compositing via mmap.

## Building

### Prerequisites

```
odin          (dev-2026-06 or later)
wayland-scanner
libwayland-server, libwayland-client, libwayland-cursor  (dev headers)
wayland-protocols
```

On Arch Linux:
```bash
pacman -S odin wayland wayland-protocols
```

### Compile

```bash
make            # build the compositor
make test       # build rift + test clients
make run        # build + run
```

## Running

### Nested mode (recommended for testing)

rift runs as a Wayland client of your current compositor. It opens a window
and composites its own clients into it.

```bash
./rift          # starts rift, opens a window in Hyprland/Sway/…

# in another terminal, connect apps to rift:
WAYLAND_DISPLAY=rift-0 foot
WAYLAND_DISPLAY=rift-0 alacritty
```

Any Wayland app that supports `WAYLAND_DISPLAY` can connect to rift.
rift tiles them automatically.

### Safety in nested mode

- rift is **only a client** of your host compositor — no DRM, no input
  grabs, no hardware access. If rift crashes, only the rift window dies.
- Fixed socket name `rift-0` — never collides with `wayland-1`.
- Links only `libwayland-server`, `libwayland-client`, `libwayland-cursor`.
  No `libdrm`, `libgbm`, `libinput`, or `libseat`.

## Keyboard / Mouse Bindings

| Binding | Action |
|---|---|
| `Super` + `Space` | Toggle floating (tiled ↔ floating) |
| `Super` + left-drag | Move window (swap if tiled, drag if floating) |
| `Super` + right-drag | Resize window (split ratio if tiled, free if floating) |
| `Super` + `Tab` | Swap focused window with next |
| `Super` + `←` / `→` | Resize split horizontally |
| `Super` + `↑` / `↓` | Resize split vertically |
| Click | Focus window |

> **Nested-mode note:** Hyprland grabs `Super`+mouse by default
> (`bindm = super, mouse:272`). Inside Hyprland, use **`Alt`** instead of
> `Super` for mouse operations, or use the keyboard shortcuts (which
> rift intercepts before Hyprland sees them). `Super` works fully when
> rift runs standalone (direct DRM backend — not yet implemented).


## Configuration

rift reads  on startup. If no config file exists,
defaults are used. See  for a full sample.

```toml
[keybinds]
"super+space"     = "toggle_floating"
"super+return"    = "exec foot"
"super+q"         = "close_window"

[window_rules]
"gimp"      = "floating=true"
".*float.*" = "floating=true"

[layout]
gaps_in  = 5
gaps_out = 10

[colors]
background       = 0xFF1a1a2a
active_border    = 0xFF7700FF

[autostart]
0 = "waybar"
```

### Window Rules

Window rule patterns are **regex** matched against the window title/app_id.
Use  for wildcard matching, e.g.  matches any window
with "float" in its name.

## Architecture

```
rift/
├── main.odin              Entry point: display, socket, event loop
├── server.odin            Core compositor: Server struct, wl_compositor,
│                          wl_surface, wl_seat, wl_output, compositing
├── xdg.odin               xdg-shell WM: toplevel lifecycle, configure
│                          handshake, title tracking
├── input.odin             Input forwarding: keyboard, pointer, focus,
│                          WM interactions (move/resize)
├── layout.odin            Split-tree tiling: add/remove/swap/resize
├── nested.odin            Nested backend: rift as Hyprland client,
│                          buffer management, cursor, input bridge
├── wayland_server/        libwayland-server bindings (hand-ported)
│   ├── libwayland.odin    C function bindings
│   ├── protocol.odin      Core Wayland protocol (generated vtables)
│   └── xdg_protocol.odin  xdg-shell protocol (generated vtables)
├── wlclient/              libwayland-client bindings (rift-as-client)
│   ├── wayland.odin       Core client protocol
│   ├── util.odin          Protocol type definitions
│   ├── cursor.odin        libwayland-cursor bindings
│   ├── xdg/shell.odin     xdg-shell client protocol
│   └── wp/                Wayland protocols (viewporter, fractional-scale)
├── tests/                 Test clients
│   ├── kbclient/          Keyboard + pointer test client
│   └── draw_client/       Simple checkerboard surface
├── tools/
│   └── probe/             Wayland registry probe
└── Makefile
```

### How it works

rift runs **two Wayland roles in one process**:

1. **Server** on socket `rift-0` — accepts client connections, manages
   surfaces, handles xdg-shell, runs the tiling layout.
2. **Client** of the host compositor (`wayland-1`) — opens a single xdg
   toplevel window and composites all rift-managed windows into it.

The host compositor's file descriptor is hooked into rift's server event
loop via `wl_event_loop_add_fd`, so both roles share one thread and one
loop. Input events from the host (keyboard, pointer) are forwarded to the
focused rift-client. The split-tree layout assigns each window a rectangle;
the compositor blits each client's SHM buffer into its tile.

## Roadmap

- [ ] Standalone backend (DRM/KMS) — run without a host compositor
- [x] Configuration file (TOML: keybinds, window rules, colors, autostart)
- [x] Floating windows (toggle with Super+Space, drag to move/resize)
- [x] Workspaces (10 workspaces, switch with Super+1-9, move with Super+Shift+1-9)
- [ ] GPU rendering (EGL + dmabuf)
- [ ] wlr-protocols (layer-shell, output-management, etc.)

## License

MIT