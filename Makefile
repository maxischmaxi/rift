# ═══════════════════════════════════════════════════════════════════════════
#  rift — Wayland-Compositor in Odin. Build-System
# ═══════════════════════════════════════════════════════════════════════════
#
#  Build-Stufen pro Protokoll:
#   1. wayland-scanner private-code  →  *-protocol.c   (generiert C aus XML)
#   2. cc -c                        →  *-protocol.o   (compiliert die Interface-Daten)
#   3. odin build                   →  rift           (linkt .o's + libwayland)
#
#  Nutzung:
#   make            # alles bauen
#   make run        # bauen + starten (rift läuft, Nested-Fenster in Hyprland)
#   make proto      # alle Protokolle regenerieren (nach Wayland-Update)
#   make clean
# ═══════════════════════════════════════════════════════════════════════════

ODIN     := odin
SCANNER  := wayland-scanner
CC       := cc

# Protokoll-XML-Quellen
WAYLAND_XML  := /usr/share/wayland/wayland.xml
XDG_SHELL_XML := /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
INCLUDES     := /usr/include

PROTO_DIR := wayland_server

# Generierte Protokoll-Objekte (werden via foreign import automatisch gelinkt)
WL_PROTO_C    := $(PROTO_DIR)/wayland-protocol.c
WL_PROTO_O    := $(PROTO_DIR)/wayland-protocol.o
XDG_PROTO_C   := $(PROTO_DIR)/xdg-shell-protocol.c
XDG_PROTO_O   := $(PROTO_DIR)/xdg-shell-protocol.o

PROTOS := $(WL_PROTO_O) $(XDG_PROTO_O)

.PHONY: all run proto clean check

all: $(PROTOS)
	$(ODIN) build . -out:rift -extra-linker-flags:"-lwayland-server -lwayland-client"

# ── Protokoll-Generierung ──────────────────────────────────────────────
proto: $(PROTOS)

$(WL_PROTO_O): $(WAYLAND_XML)
	@echo "[wayland] scanner → cc"
	$(SCANNER) private-code $(WAYLAND_XML) $(WL_PROTO_C)
	$(CC) -c -I$(INCLUDES) $(WL_PROTO_C) -o $(WL_PROTO_O)

$(XDG_PROTO_O): $(XDG_SHELL_XML)
	@echo "[xdg-shell] scanner → cc"
	$(SCANNER) private-code $(XDG_SHELL_XML) $(XDG_PROTO_C)
	$(CC) -c -I$(INCLUDES) $(XDG_PROTO_C) -o $(XDG_PROTO_O)

run: all
	./rift

check: $(PROTOS)
	$(ODIN) check . -vet

clean:
	rm -f rift $(WL_PROTO_C) $(WL_PROTO_O) $(XDG_PROTO_C) $(XDG_PROTO_O)
	rm -f /run/user/$(UID)/rift-0 /run/user/$(UID)/rift-0.lock 2>/dev/null || true