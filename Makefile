# ═══════════════════════════════════════════════════════════════════════════
#  rift — Wayland-Compositor in Odin.
#
#  Build-Stufen:
#   1. wayland-scanner private-code  →  *-protocol.c   (C aus XML generiert)
#   2. cc -c                        →  *-protocol.o   (Interface-Daten kompilieren)
#   3. odin build                   →  rift           (.o's + libwayland linken)
#
#  Nutzung:
#   make            # rift bauen
#   make test       # rift + test-clients bauen
#   make run        # rift starten (läuft nested in Hyprland)
#   make proto      # Protokolle regenerieren (nach Wayland-Update)
#   make check      # odin check -vet (Syntax/Lint)
#   make clean
# ═══════════════════════════════════════════════════════════════════════════

ODIN     := odin
SCANNER  := wayland-scanner
CC       := cc

# Protokoll-XML-Quellen
WAYLAND_XML   := /usr/share/wayland/wayland.xml
XDG_SHELL_XML := /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
WLR_LAYER_XML := protocols/wlr-layer-shell-unstable-v1.xml
INCLUDES      := /usr/include

PROTO_DIR := wayland_server

# Generierte Protokoll-Objekte (werden via foreign import automatisch gelinkt)
WL_PROTO_O    := $(PROTO_DIR)/wayland-protocol.o
XDG_PROTO_O   := $(PROTO_DIR)/xdg-shell-protocol.o
LAYER_PROTO_O := $(PROTO_DIR)/wlr-layer-shell-protocol.o
PROTOS        := $(WL_PROTO_O) $(XDG_PROTO_O) $(LAYER_PROTO_O)

# Linker-Flags
SERVER_LIBS := -lwayland-server
CLIENT_LIBS := -lwayland-client -lwayland-cursor
DRM_LIBS    := -ldrm -linput -lseat -ludev -lxkbcommon
ALL_LIBS    := $(SERVER_LIBS) $(CLIENT_LIBS) $(DRM_LIBS)

.PHONY: all test run standalone proto check clean install uninstall

# ── rift (Compositor) ──────────────────────────────────────────────────
# -o:speed ist Pflicht: das CPU-Compositing (clear/blit-Loops über 33MB
# pro 4K-Frame) ist unoptimiert 5-20x langsamer — spürbar als Framerate.
all: $(PROTOS)
	$(ODIN) build . -out:rift -o:speed -extra-linker-flags:"$(ALL_LIBS)"

# ── test-clients + tools ───────────────────────────────────────────────
test: all
	$(ODIN) build tests/kbclient -out:tests/kbclient/kbclient -extra-linker-flags:"$(CLIENT_LIBS)"
	$(ODIN) build tests/draw_client -out:tests/draw_client/draw_client -extra-linker-flags:"-lwayland-client"
	$(ODIN) build tests/popup_client -out:tests/popup_client/popup_client -extra-linker-flags:"-lwayland-client"
	$(ODIN) build tools/probe -out:tools/probe/probe -extra-linker-flags:"-lwayland-client"

# ── starten ────────────────────────────────────────────────────────────
run: all
	./rift

standalone: all
	./rift --drm

# ── Protokoll-Generierung ──────────────────────────────────────────────
proto: $(PROTOS)

$(WL_PROTO_O): $(WAYLAND_XML)
	@echo "[wayland] scanner → cc"
	$(SCANNER) private-code $(WAYLAND_XML) $(PROTO_DIR)/wayland-protocol.c
	$(CC) -c -I$(INCLUDES) $(PROTO_DIR)/wayland-protocol.c -o $@

$(XDG_PROTO_O): $(XDG_SHELL_XML)
	@echo "[xdg-shell] scanner → cc"
	$(SCANNER) private-code $(XDG_SHELL_XML) $(PROTO_DIR)/xdg-shell-protocol.c
	$(CC) -c -I$(INCLUDES) $(PROTO_DIR)/xdg-shell-protocol.c -o $@

$(LAYER_PROTO_O): $(WLR_LAYER_XML)
	@echo "[layer-shell] scanner → cc"
	$(SCANNER) private-code $(WLR_LAYER_XML) $(PROTO_DIR)/wlr-layer-shell-protocol.c
	$(CC) -c -I$(INCLUDES) $(PROTO_DIR)/wlr-layer-shell-protocol.c -o $@

# ── Syntax-Check ───────────────────────────────────────────────────────
check: $(PROTOS)
	$(ODIN) check . -vet

# ── Install / Uninstall ──────────────────────────────────────────────────
install: all
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

# ── Aufräumen ──────────────────────────────────────────────────────────
clean:
	rm -f rift tests/kbclient/kbclient tests/draw_client/draw_client tools/probe/probe
	rm -f $(PROTO_DIR)/*-protocol.c $(PROTO_DIR)/*-protocol.o
	rm -f /run/user/$(UID)/rift-0 /run/user/$(UID)/rift-0.lock 2>/dev/null || true