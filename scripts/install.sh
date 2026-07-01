#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  rift — Install-Script
#
#  Installiert:
#    • rift binary              → $PREFIX/bin/rift
#    • rift-session wrapper     → $PREFIX/bin/rift-session
#    • SDDM/wayland-sessions    → $PREFIX/share/wayland-sessions/rift.desktop
#    • config.toml.example      → $PREFIX/share/rift/config.toml.example
#    • default config (wenn keine da) → ~/.config/rift/config.toml
#
#  Benutzung:
#    sudo ./scripts/install.sh                 # /usr/local (default)
#    sudo PREFIX=/usr ./scripts/install.sh     # /usr
#    ./scripts/install.sh --user               # ~/.local (kein sudo)
# ═══════════════════════════════════════════════════════════════════════════

set -e

# --- Defaults -------------------------------------------------------------
PREFIX="/usr/local"
USER_INSTALL=false

# --- Args parsen ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)  USER_INSTALL=true; shift ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        PREFIX=*)  PREFIX="${1#PREFIX=}"; shift ;;
        --help|-h)
            echo " rift — Install-Script"
            echo ""
            echo "Benutzung:"
            echo "  sudo ./scripts/install.sh                  # Systemweit (/usr/local)"
            echo "  sudo ./scripts/install.sh --prefix=/usr    # Systemweit (/usr)"
            echo "  ./scripts/install.sh --user                # Nur für aktuellen User (~/.local)"
            exit 0 ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
done

# --- Bei --user: Pfade anpassen -------------------------------------------
if $USER_INSTALL; then
    PREFIX="$HOME/.local"
    BINDIR="$PREFIX/bin"
    SHAREDIR="$PREFIX/share"
    SESSIONSDIR="$HOME/.local/share/wayland-sessions"
    SUDO=""
else
    BINDIR="$PREFIX/bin"
    SHAREDIR="$PREFIX/share"
    SESSIONSDIR="$PREFIX/share/wayland-sessions"
    SUDO="sudo"
fi

# --- Farben ---------------------------------------------------------------
G="\033[32m"; Y="\033[33m"; B="\033[34m"; R="\033[0m"
ok()   { echo -e "${G}✓${R} $1"; }
info() { echo -e "${B}→${R} $1"; }
warn() { echo -e "${Y}⚠${R} $1"; }

# --- rift bauen falls nicht vorhanden ------------------------------------
cd "$(dirname "$0")/.."

if [[ ! -f rift ]]; then
    info "Baue rift..."
    make
    ok "rift gebaut"
fi

# --- 1. Binary installieren ------------------------------------------------
info "Installiere rift → $BINDIR/rift"
$SUDO mkdir -p "$BINDIR"
$SUDO install -m755 rift "$BINDIR/rift"
ok "Binary: $BINDIR/rift"

# --- 2. Session-Wrapper installieren --------------------------------------
info "Installiere rift-session → $BINDIR/rift-session"
$SUDO install -m755 assets/rift-session "$BINDIR/rift-session"
ok "Session-Wrapper: $BINDIR/rift-session"

# --- 3. SDDM/wayland-sessions .desktop -------------------------------------
info "Installiere rift.desktop → $SESSIONSDIR/"
$SUDO mkdir -p "$SESSIONSDIR"
$SUDO install -m644 assets/rift.desktop "$SESSIONSDIR/rift.desktop"
ok "Session-Eintrag: $SESSIONSDIR/rift.desktop"

# --- 4. Config-Beispiel -----------------------------------------------------
info "Installiere config.toml.example → $SHAREDIR/rift/"
$SUDO mkdir -p "$SHAREDIR/rift"
$SUDO install -m644 config.toml.example "$SHAREDIR/rift/config.toml.example"
ok "Config-Beispiel: $SHAREDIR/rift/config.toml.example"

# --- 5. User-Config anlegen (wenn keine da) --------------------------------
USER_CONF_DIR="$HOME/.config/rift"
USER_CONF="$USER_CONF_DIR/config.toml"
if [[ ! -f "$USER_CONF" ]]; then
    info "Lege default config an → $USER_CONF"
    mkdir -p "$USER_CONF_DIR"
    cp config.toml.example "$USER_CONF"
    ok "Default config: $USER_CONF"
else
    warn "Config bereits vorhanden: $USER_CONF (überschrieben wird nichts)"
fi

# --- 6. Abhängigkeits-Check ------------------------------------------------
echo ""
info "Prüfe optionale Abhängigkeiten für Standalone-Session (SDDM)..."

if command -v cage >/dev/null 2>&1; then
    ok "cage gefunden — rift kann als SDDM-Session laufen"
elif command -v sway >/dev/null 2>&1; then
    ok "sway gefunden — rift kann als SDDM-Session laufen (sway als Host)"
else
    warn "Weder cage noch sway gefunden."
    warn "Für SDDM-Session:  sudo pacman -S cage  (empfohlen, minimal)"
    warn "Ost:               sudo pacman -S sway"
fi

# --- Zusammenfassung -------------------------------------------------------
echo ""
echo -e "${G}═══════════════════════════════════════════════════════════════${R}"
echo -e "${G} rift installiert!${R}"
echo -e "${G}═══════════════════════════════════════════════════════════════${R}"
echo ""
echo "Installiert:"
echo "  Binary:        $BINDIR/rift"
echo "  Session:       $BINDIR/rift-session"
echo "  SDDM-Eintrag:  $SESSIONSDIR/rift.desktop"
echo "  Config-Bsp:    $SHAREDIR/rift/config.toml.example"
echo "  User-Config:   $USER_CONF"
echo ""
echo "Nutzung:"
if ! $USER_INSTALL; then
    echo "  rift                  # Direkt starten (nested in aktuellem Compositor)"
    echo "  rift-session          # Session-Wrapper (für SDDM oder standalone)"
    echo ""
    echo "SDDM: Nach Ab- und Anmelden sollte 'rift' in der Session-Auswahl erscheinen."
    echo "      rift läuft dann via cage (oder sway) als Host-Compositor."
fi
echo ""
echo "Config anpassen:  $EDITOR $USER_CONF 2>/dev/null || vim $USER_CONF"