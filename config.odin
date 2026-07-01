package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:text/regex"
import "core:sys/posix"
import "base:runtime"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Configuration — TOML-basiert, mit Regex-Support für Window-Rules.
//
//  Config-Datei: ~/.config/rift/config.toml
//  Format: minimales TOML (Sections, Strings, Ints, Hex, Bools, Kommentare).
// ═══════════════════════════════════════════════════════════════════════════

// ─── Modifier-Masks ──────────────────────────────────────────────────────
// WM_MOD_SUPER und WM_MOD_ALT in input.odin definiert.
WM_MOD_SHIFT :: u32(0x01)
WM_MOD_CTRL  :: u32(0x04)

// ─── Actions ──────────────────────────────────────────────────────────
Action :: enum {
    ToggleFloating, SwapNext, ResizeH, ResizeV,
    CloseWindow, Exec, Quit, Workspace, MoveToWorkspace, Unknown,
}

Keybind :: struct {
    mods:   u32,
    key:    u32,
    action: Action,
    arg:    string,
}

WindowRule :: struct {
    pattern_re: regex.Regular_Expression,
    floating:   bool,
}

Config :: struct {
    keybinds:       [dynamic]Keybind,
    window_rules:  [dynamic]WindowRule,
    gaps_in:        i32,
    gaps_out:       i32,
    border_size:    i32,
    bg_color:       u32,
    active_border:  u32,
    inactive_border: u32,
    autostart:      [dynamic]string,
    refresh_rate:   u32,   // Wunsch-Hz im DRM-Modus; 0 = höchste Rate des Monitors
    // XKB-Keymap für den DRM-Modus (leer = System-Default/XKB_DEFAULT_*)
    kb_layout:      string,
    kb_variant:     string,
    kb_options:     string,
    kb_model:       string,
    loaded:          bool,
}

g_config: Config

// ═══════════════════════════════════════════════════════════════════════════
//  Lookup-Tabellen (Arrays statt Maps — Odin dev-2026 hat keine Map-Literale)
// ═══════════════════════════════════════════════════════════════════════════

KeyEntry :: struct { name: string, code: u32 }

key_codes: []KeyEntry = {
    {"space", 65},  {"tab", 23},  {"return", 36},  {"enter", 36},
    {"escape", 9},  {"esc", 9},   {"backspace", 22}, {"delete", 119},
    {"insert", 110}, {"home", 102}, {"end", 107},
    {"page_up", 112}, {"page_down", 117},
    {"left", 113},  {"right", 114},  {"up", 111},  {"down", 116},
    {"a", 38},  {"b", 56},  {"c", 54},  {"d", 40},  {"e", 26},
    {"f", 41},  {"g", 42},  {"h", 43},  {"i", 31},  {"j", 44},
    {"k", 45},  {"l", 46},  {"m", 58},  {"n", 57},  {"o", 32},
    {"p", 33},  {"q", 24},  {"r", 27},  {"s", 39},  {"t", 28},
    {"u", 30},  {"v", 55},  {"w", 25},  {"x", 53},  {"y", 29},  {"z", 52},
    {"0", 19},  {"1", 10},  {"2", 11},  {"3", 12},  {"4", 13},
    {"5", 14},  {"6", 15},  {"7", 16},  {"8", 17},  {"9", 18},
    {"f1", 67},  {"f2", 68},  {"f3", 69},  {"f4", 70},  {"f5", 71},
    {"f6", 72},  {"f7", 73},  {"f8", 74},  {"f9", 75},  {"f10", 76},
    {"f11", 77}, {"f12", 78},
    {"bracketleft", 34}, {"[", 34}, {"bracketright", 35}, {"]", 35},
    {"minus", 12}, {"=", 13}, {"equal", 13},
}

mod_entries: []KeyEntry = {
    {"super", WM_MOD_SUPER},  {"win", WM_MOD_SUPER},  {"logo", WM_MOD_SUPER},
    {"alt",   WM_MOD_ALT},    {"meta", WM_MOD_ALT},
    {"ctrl",  WM_MOD_CTRL},   {"control", WM_MOD_CTRL},
    {"shift", WM_MOD_SHIFT},
}

ActionEntry :: struct { name: string, action: Action }
action_entries: []ActionEntry = {
    {"toggle_floating", .ToggleFloating},
    {"swap_next",       .SwapNext},
    {"resize_h",        .ResizeH},
    {"resize_v",        .ResizeV},
    {"close_window",    .CloseWindow},
    {"close",           .CloseWindow},
    {"exec",            .Exec},
    {"quit",            .Quit},
    {"workspace",        .Workspace},
    {"movetoworkspace",  .MoveToWorkspace},
}

lookup_key :: proc(entries: []KeyEntry, name: string) -> (u32, bool) {
    for e in entries {
        if e.name == name do return e.code, true
    }
    return 0, false
}

lookup_action :: proc(name: string) -> (Action, bool) {
    for e in action_entries {
        if e.name == name do return e.action, true
    }
    return .Unknown, false
}

// ═══════════════════════════════════════════════════════════════════════════
//  Config laden
// ═══════════════════════════════════════════════════════════════════════════

config_default :: proc() {
    context = ctx
    clear(&g_config.keybinds)
    clear(&g_config.window_rules)
    clear(&g_config.autostart)
    g_config.gaps_in  = 0
    g_config.gaps_out = 0
    g_config.border_size = 0
    g_config.bg_color      = 0xFF1a1a2a
    g_config.active_border   = 0xFF7700FF
    g_config.inactive_border = 0xFF333344
    g_config.refresh_rate    = 0  // 0 = so viel Hz wie der Monitor hergibt

    default_binds := []string{ "super+space", "super+tab",
        "super+left", "super+right", "super+up", "super+down" }
    default_actions := []string{ "toggle_floating", "swap_next",
        "resize_h -0.05", "resize_h 0.05", "resize_v -0.05", "resize_v 0.05" }
        // Workspace-Keybinds (super+1..9 = workspace, super+shift+1..9 = movetoworkspace)
    for n in 1..<10 {
        ws_key := fmt.tprintf("super+{}", n)
        ws_act := fmt.tprintf("workspace {}", n)
        kb := parse_keybind(ws_key, ws_act)
        if kb.action != .Unknown do append(&g_config.keybinds, kb)

        mv_key := fmt.tprintf("super+shift+{}", n)
        mv_act := fmt.tprintf("movetoworkspace {}", n)
        kb2 := parse_keybind(mv_key, mv_act)
        if kb2.action != .Unknown do append(&g_config.keybinds, kb2)
    }
    // Super+[ und Super+] für voriger/nächster Workspace
    kb3 := parse_keybind("super+bracketleft", "workspace -1")
    if kb3.action != .Unknown do append(&g_config.keybinds, kb3)
    kb4 := parse_keybind("super+bracketright", "workspace +1")
    if kb4.action != .Unknown do append(&g_config.keybinds, kb4)
    for i in 0..<len(default_binds) {
        kb := parse_keybind(default_binds[i], default_actions[i])
        if kb.action != .Unknown do append(&g_config.keybinds, kb)
    }
    g_config.loaded = true
}

config_load :: proc() {
    context = ctx
    config_default()

    // Config-Pfad: $XDG_CONFIG_HOME/rift/config.toml oder ~/.config/rift/config.toml
    config_path := ""
    xdg := string(posix.getenv("XDG_CONFIG_HOME"))
    if len(xdg) > 0 {
        config_path = fmt.tprintf("{}/rift/config.toml", xdg)
    } else {
        home := string(posix.getenv("HOME"))
        if len(home) > 0 {
            config_path = fmt.tprintf("{}/.config/rift/config.toml", home)
        }
    }
    if len(config_path) == 0 {
        fmt.println("[config] keine Config-Datei gefunden — nutze Defaults")
        return
    }

    data, err := os.read_entire_file_from_path(config_path, context.allocator)
    if err != nil {
        fmt.printfln("[config] keine Config-Datei unter {} — nutze Defaults", config_path)
        return
    }
    fmt.printfln("[config] lade {}", config_path)
    config_parse(string(data))
}

config_parse :: proc(data: string) {
    context = ctx
    section: string = ""
    for raw_line in strings.split(data, "\n") {
        line := strings.trim_space(raw_line)
        if len(line) == 0 do continue
        if line[0] == '#' do continue

        if line[0] == '[' {
            end := strings.index(line, "]")
            if end > 0 {
                section = strings.trim_space(line[1:end])
            }
            continue
        }

        eq := strings.index(line, "=")
        if eq < 0 do continue
        key := strings.trim_space(line[:eq])
        val := strings.trim_space(line[eq+1:])
        key = unquote(key)

        switch section {
        case "keybinds":
            kb := parse_keybind(key, val)
            if kb.action != .Unknown do append(&g_config.keybinds, kb)
        case "window_rules":
            wr := parse_window_rule(key, val)
            append(&g_config.window_rules, wr)
        case "layout":
            parse_layout(key, val)
        case "monitor":
            parse_monitor(key, val)
        case "input":
            parse_input(key, val)
        case "colors":
            parse_color(key, val)
        case "autostart":
            v := unquote(val)
            append(&g_config.autostart, strings.clone(v))
        case:
            fmt.printfln("[config] unbekannte Section: %q", section)
        }
    }
    fmt.printfln("[config] {} Keybinds, {} Window-Rules, {} Autostart",
        len(g_config.keybinds), len(g_config.window_rules), len(g_config.autostart))
}

// ─── Hilfsfunktionen ───────────────────────────────────────────────────

unquote :: proc(s: string) -> string {
    if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"') do return s[1:len(s)-1]
    if len(s) >= 2 && (s[0] == '\'' && s[len(s)-1] == '\'') do return s[1:len(s)-1]
    return s
}

parse_hex_or_int :: proc(s: string) -> i64 {
    if len(s) >= 3 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
        val := i64(0)
        for i in 2..<len(s) {
            c := s[i]; val *= 16
            if c >= '0' && c <= '9' { val += i64(c - '0') }
            else if c >= 'a' && c <= 'f' { val += i64(c - 'a' + 10) }
            else if c >= 'A' && c <= 'F' { val += i64(c - 'A' + 10) }
        }
        return val
    }
    val := i64(0); neg := false; i := 0
    if i < len(s) && s[i] == '-' { neg = true; i += 1 }
    for i < len(s) {
        if s[i] < '0' || s[i] > '9' do break
        val = val * 10 + i64(s[i] - '0'); i += 1
    }
    if neg do val = -val
    return val
}

parse_bool :: proc(s: string) -> bool {
    return s == "true" || s == "1" || s == "yes"
}

parse_keybind :: proc(key_str, action_str: string) -> Keybind {
    context = ctx
    kb := Keybind{action = .Unknown}
    parts := strings.split(key_str, "+")
    mods := u32(0); key_code := u32(0)
    for part in parts {
        p := strings.trim_space(part)
        p = strings.to_lower(p)
        if mc, ok := lookup_key(mod_entries, p); ok {
            mods |= mc
        } else if kc, ok := lookup_key(key_codes, p); ok {
            key_code = kc
        } else {
            fmt.printfln("[config] unbekannter Key: %q in %q", p, key_str)
            return kb
        }
    }
    if key_code == 0 {
        fmt.printfln("[config] kein Key in %q", key_str)
        return kb
    }
    act_str := unquote(action_str)
    action_name := act_str; arg := ""
    sp := strings.index(act_str, " ")
    if sp >= 0 {
        action_name = act_str[:sp]
        arg = strings.trim_space(act_str[sp+1:])
    }
    action, ok := lookup_action(action_name)
    if !ok {
        fmt.printfln("[config] unbekannte Action: %q", action_name)
        return kb
    }
    kb.mods = mods; kb.key = key_code; kb.action = action
    kb.arg = strings.clone(arg)
    return kb
}

parse_window_rule :: proc(pattern, props_str: string) -> WindowRule {
    context = ctx
    wr := WindowRule{}
    re, err := regex.create(pattern)
    if err != nil {
        fmt.printfln("[config] Regex-Fehler für %q: {}", pattern, err)
        return wr
    }
    wr.pattern_re = re
        props_clean := unquote(props_str)
    for prop in strings.split(props_clean, ",") {
        p := strings.trim_space(prop)
        eq := strings.index(p, "=")
        if eq < 0 do continue
        pname := strings.trim_space(p[:eq])
        pval := strings.trim_space(p[eq+1:])
        switch pname {
        case "floating": wr.floating = parse_bool(pval)
        case: fmt.printfln("[config] unbekannte Window-Rule-Property: %q", pname)
        }
    }
    return wr
}

parse_layout :: proc(key, val: string) {
    switch key {
    case "gaps_in":     g_config.gaps_in    = i32(parse_hex_or_int(val))
    case "gaps_out":    g_config.gaps_out   = i32(parse_hex_or_int(val))
    case "border_size": g_config.border_size = i32(parse_hex_or_int(val))
    case: fmt.printfln("[config] unbekanntes Layout-Setting: %q", key)
    }
}

parse_monitor :: proc(key, val: string) {
    switch key {
    case "refresh_rate": g_config.refresh_rate = u32(parse_hex_or_int(val))
    case: fmt.printfln("[config] unbekanntes Monitor-Setting: %q", key)
    }
}

parse_input :: proc(key, val: string) {
    context = ctx
    v := strings.clone(unquote(val))
    switch key {
    case "kb_layout":  g_config.kb_layout  = v
    case "kb_variant": g_config.kb_variant = v
    case "kb_options": g_config.kb_options = v
    case "kb_model":   g_config.kb_model   = v
    case: fmt.printfln("[config] unbekanntes Input-Setting: %q", key)
    }
}

parse_color :: proc(key, val: string) {
    c := u32(parse_hex_or_int(val))
    switch key {
    case "background":        g_config.bg_color        = c
    case "active_border":      g_config.active_border   = c
    case "inactive_border":    g_config.inactive_border = c
    case: fmt.printfln("[config] unbekannte Color-Option: %q", key)
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Lookup (von input.odin aufgerufen)
// ═══════════════════════════════════════════════════════════════════════════

config_find_keybind :: proc(mods: u32, key: u32) -> int {
    for kb, i in g_config.keybinds {
        if kb.mods == mods && kb.key == key do return i
    }
    return -1
}

config_match_window_rule :: proc(app_class: string) -> ^WindowRule {
    context = ctx
    if len(app_class) == 0 do return nil
    for i in 0..<len(g_config.window_rules) {
        wr := &g_config.window_rules[i]
        _, ok := regex.match(wr.pattern_re, app_class)
        if ok do return wr
    }
    return nil
}

config_run_autostart :: proc() {
    context = ctx
    for cmd in g_config.autostart {
        fmt.printfln("[config] autostart: {}", cmd)
        bg := fmt.tprintf("{} &", cmd)
        cstr, _ := strings.clone_to_cstring(bg); posix.system(cstr)
    }
}