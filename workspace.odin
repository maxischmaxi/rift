package main

import "core:fmt"
import "base:runtime"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Workspaces — wie Hyprland: N Workspaces, jeder mit eigenem Tiling-Baum.
//
//  • Super+1..9  → zu Workspace N springen
//  • Super+Shift+1..9 → fokussiertes Fenster zu Workspace N verschieben
//  • Super+]/[   → nächster/voriger Workspace
//
//  Multi-Monitor: Jeder Output hat seine eigene active_workspace. Workspaces
//  sind nicht an Monitore gebunden — sie erscheinen auf dem Output, der sie
//  anfordert (wie Hyprland). In Nested-Modus gibt es einen Output.
// ═══════════════════════════════════════════════════════════════════════════

DEFAULT_WS_COUNT :: 10  // Standard-Anzahl Workspaces (1-10)

Workspace :: struct {
    id:          int,                          // 1, 2, 3, ...
    root:        ^Node,                        // Tiling-Baum (nil = leer)
    toplevels:   [dynamic]^XdgToplevel,        // Fenster auf diesem Workspace
    name:        string,                       // optionaler Name
}

// ─── Workspaces initialisieren ─────────────────────────────────────────
workspaces_init :: proc(count: int) {
    context = ctx
    for i in 0..<count {
        ws := new(Workspace)
        ws.id = i + 1
        append(&g_server.workspaces, ws)
    }
    g_server.active_ws = g_server.workspaces[0]
    fmt.printfln("[ws] {} Workspaces initialisiert (1-{})", count, count)
}

// ─── Workspace nach ID holen ────────────────────────────────────────────
workspace_get :: proc(id: int) -> ^Workspace {
    for ws in g_server.workspaces {
        if ws.id == id do return ws
    }
    return nil
}

// ─── Aktiven Workspace wechseln ─────────────────────────────────────────
workspace_switch :: proc(id: int) {
    context = ctx
    target := workspace_get(id)
    if target == nil || target == g_server.active_ws do return
    old := g_server.active_ws
    g_server.active_ws = target
    fmt.printfln("[ws] switch: {} → {} ({}→{} Fenster)",
        old.id, target.id, len(old.toplevels), len(target.toplevels))
    // Fokus aufräumen: wenn das fokussierte Fenster nicht auf dem neuen WS ist
    if g_server.focused != nil {
        on_new := false
        for tl in target.toplevels {
            if tl == g_server.focused { on_new = true; break }
        }
        if !on_new do g_server.focused = nil
    }
    // Neuen WS fokussieren: erstes Fenster oder nil
    if g_server.focused == nil && len(target.toplevels) > 0 {
        g_server.focused = target.toplevels[0]
    }
    g_server.ptr_focus = nil  // Pointer-Fokus beim WS-Wechsel zurücksetzen
    layout_toplevels()
    composite_all()
    // Keyboard-Fokus neu senden
    if g_server.focused != nil && nested.kb_focused {
        input_focus_toplevel(g_server.focused)
    }
}

// ─── Nächster/voriger Workspace ─────────────────────────────────────────
workspace_switch_relative :: proc(delta: int) {
    context = ctx
    if len(g_server.workspaces) == 0 do return
    cur := 0
    for ws, i in g_server.workspaces {
        if ws == g_server.active_ws { cur = i; break }
    }
    nxt := (cur + delta) % len(g_server.workspaces)
    if nxt < 0 do nxt += len(g_server.workspaces)
    workspace_switch(g_server.workspaces[nxt].id)
}

// ─── Fenster auf anderen Workspace verschieben ──────────────────────────
workspace_move_window :: proc(tl: ^XdgToplevel, target_id: int, follow: bool) {
    context = ctx
    target := workspace_get(target_id)
    if target == nil do return
    old_ws := g_server.active_ws
    if target == old_ws do return  // schon auf dem Workspace
    // Aus altem Workspace entfernen
    for t, i in old_ws.toplevels {
        if t == tl {
            ordered_remove(&old_ws.toplevels, i)
            break
        }
    }
    tree_remove(tl)  // aus altem Tiling-Baum
    // In neuen Workspace einfügen
    append(&target.toplevels, tl)
    // In den Tiling-Baum des Ziel-Workspaces einfügen
    if target.root == nil {
        leaf := node_new_leaf(tl)
        target.root = leaf
    } else {
        // tree_add nutzt g_server.active_ws.root — wir müssen temporär den
        // aktiven WS setzen, falls target nicht aktiv ist
        was_active := g_server.active_ws
        g_server.active_ws = target
        tree_add(tl)
        g_server.active_ws = was_active
    }
    fmt.printfln("[ws] move %q → Workspace {}", tl.title, target_id)
    // Fokus aufräumen wenn das verschobene Fenster fokussiert war
    if g_server.focused == tl do g_server.focused = nil
    if tl.xdg_surface != nil && g_server.ptr_focus == tl.xdg_surface.surface {
        g_server.ptr_focus = nil
    }
    if g_server.wm_tl == tl { g_server.wm_tl = nil; g_server.wm_mode = .None; g_server.wm_split = nil }
    if follow {
        workspace_switch(target_id)
    } else {
        layout_toplevels()
        composite_all()
    }
}