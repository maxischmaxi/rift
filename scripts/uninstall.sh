#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  rift — Uninstall-Script
#
#  Entfernt alle rift-Systemdateien. Die User-Config (~/.config/rift/)
#  wird standardmäßig NICHT gelöscht (kann mit --purge entfernt werden).
#
#  Benutzung:
#    sudo ./scripts/uninstall.sh             # Systemweite Installation entfernen
#    sudo ./scripts/uninstall.sh --purge      # Auch User-Config löschen
#    ./scripts/uninstall.sh --user           # Nur User-Installation entfernen
#    ./scripts/uninstall.sh --user --purge   # User + Config löschen
# ═══════════════════════════════════════════════════════════════════════════

set -e

# --- Defaults -------------------------------------------------------------
PREFIX="/usr/local"
USER_INSTALL=false
PURGE=false

# --- Args parsen ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)  USER_INSTALL=true; shift ;;
        --purge) PURGE=true; shift ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        --help|-h)
            echo " rift — Uninstall-Script"
            echo ""
            echo "Benutzung:"
            echo "  sudo ./scripts/uninstall.sh            # Systemweit entfernen"
            echo "  sudo ./scripts/uninstall.sh --purge    # + User-Config löschen"
            echo "  ./scripts/uninstall.sh --user          # User-Installation entfernen"
            echo "  ./scripts/uninstall.sh --user --purge # + User-Config löschen"
            exit 0 ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
done

# --- Pfade ---------------------------------------------------------------
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
miss() { echo -e "${Y}⊘${R} $1 (nicht gefunden)"; }

# --- Dateien entfernen -----------------------------------------------------
removed=0
rm_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        $SUDO rm -f "$file"
        ok "Entfernt: $file"
        removed=$((removed + 1))
    else
        miss "$file"
    fi
}

echo -e "${B}═══════════════════════════════════════════════════════════════${R}"
echo -e "${B} rift — Uninstall${R}"
echo -e "${B}═══════════════════════════════════════════════════════════════${R}"
echo ""

# --- Binary ----------------------------------------------------------------
info "Entferne Binary..."
rm_if_exists "$BINDIR/rift"

# --- Session-Wrapper -------------------------------------------------------
info "Entferne Session-Wrapper..."
rm_if_exists "$BINDIR/rift-session"

# --- SDDM/wayland-sessions -------------------------------------------------
info "Entferne SDDM-Eintrag..."
rm_if_exists "$SESSIONSDIR/rift.desktop"

# --- Config-Beispiel -------------------------------------------------------
info "Entferne Config-Beispiel..."
rm_if_exists "$SHAREDIR/rift/config.toml.example"

# --- Leere Verzeichnisse aufräumen ----------------------------------------
if [[ -d "$SHAREDIR/rift" ]]; then
    if $SUDO rmdir "$SHAREDIR/rift" 2>/dev/null; then
        ok "Leeres Verzeichnis entfernt: $SHAREDIR/rift"
    fi
fi

# --- User-Config (--purge) ------------------------------------------------
USER_CONF_DIR="$HOME/.config/rift"
USER_CONF="$USER_CONF_DIR/config.toml"

if $PURGE; then
    echo ""
    info "--purge: Entferne User-Config..."
    if [[ -f "$USER_CONF" ]]; then
        rm -f "$USER_CONF"
        ok "Entfernt: $USER_CONF"
        removed=$((removed + 1))
    else
        miss "$USER_CONF"
    fi
    if [[ -d "$USER_CONF_DIR" ]]; then
        rmdir "$USER_CONF_DIR" 2>/dev/null && ok "Leeres Verzeichnis entfernt: $USER_CONF_DIR" || true
    fi
else
    if [[ -f "$USER_CONF" ]]; then
        echo ""
        warn "User-Config nicht gelöscht: $USER_CONF"
        warn "Zum Entfernen:  $0 --purge"
    fi
fi

# --- Zusammenfassung -------------------------------------------------------
echo ""
echo -e "${G}═══════════════════════════════════════════════════════════════${R}"
if [[ $removed -gt 0 ]]; then
    echo -e "${G} rift deinstalliert ($removed Dateien entfernt)${R}"
else
    echo -e "${Y} Nichts zu entfernen gefunden${R}"
fi
echo -e "${G}═══════════════════════════════════════════════════════════════${R}"