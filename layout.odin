package main

import "core:fmt"
import "base:runtime"

// ═══════════════════════════════════════════════════════════════════════════
//  rift Tiling-Layout — Split-Tree (binär, wie Hyprland/i3 dwindle).
//
//  Jeder Node ist entweder ein Leaf (Fenster) oder ein Split (horizontal
//  oder vertikal) mit zwei Kindern + einer Ratio (0.1..0.9).
//    • Neues Fenster  → splittet das fokussierte Leaf (Orientierung nach
//                       Seitenverhältnis: breiter→nebeneinander, sonst stacked).
//    • Move (Super+LMB)   → zwei Leaves swappen (tl-Pointer tauschen).
//    • Resize (Super+RMB) → Ratio des Eltern-Splits ziehen.
//
//  Läuft vollständig in rifts Server-Logik. Berührt Hyprland NICHT.
// ═══════════════════════════════════════════════════════════════════════════

Node_Kind :: enum { Leaf, Split }

Node :: struct {
    kind: Node_Kind,
    // Leaf
    tl: ^XdgToplevel,
    // Split
    horizontal: bool,   // true = links|rechts, false = oben|unten
    ratio: f64,         // Anteil von Kind `a` (0.1..0.9)
    a, b: ^Node,
    parent: ^Node,      // nil am Root
    rect: Rect,         // zugewiesene Fläche (von layout_tree gesetzt)
}

// WM-Interaktions-Modus (Super+Drag).
WM_Mode :: enum { None, Move, Resize }

// Root des Layout-Baums.
g_root: ^Node

// ─── Konstruktion ────────────────────────────────────────────────────────
node_new_leaf :: proc(tl: ^XdgToplevel) -> ^Node {
    n := new(Node)
    n.kind = .Leaf
    n.tl = tl
    return n
}

node_new_split :: proc(a, b: ^Node, horizontal: bool) -> ^Node {
    n := new(Node)
    n.kind = .Split
    n.horizontal = horizontal
    n.ratio = 0.5
    n.a = a; n.b = b
    a.parent = n; b.parent = n
    return n
}

// ─── Layout: weist jedem Leaf sein geom zu (rekursiv) ────────────────────
layout_tree :: proc(n: ^Node, r: Rect) {
    if n == nil do return
    n.rect = r
    if n.kind == .Leaf {
        n.tl.geom = r
        return
    }
    if n.horizontal {
        aw := int(f64(r[2]) * n.ratio)
        layout_tree(n.a, Rect{r[0], r[1], i32(aw), r[3]})
        layout_tree(n.b, Rect{r[0] + i32(aw), r[1], r[2] - i32(aw), r[3]})
    } else {
        ah := int(f64(r[3]) * n.ratio)
        layout_tree(n.a, Rect{r[0], r[1], r[2], i32(ah)})
        layout_tree(n.b, Rect{r[0], r[1] + i32(ah), r[2], r[3] - i32(ah)})
    }
}

// ─── Suche ───────────────────────────────────────────────────────────────
tree_find_leaf :: proc(n: ^Node, tl: ^XdgToplevel) -> ^Node {
    if n == nil do return nil
    if n.kind == .Leaf {
        if n.tl == tl do return n
        return nil
    }
    l := tree_find_leaf(n.a, tl)
    if l != nil do return l
    return tree_find_leaf(n.b, tl)
}

tree_first_leaf :: proc(n: ^Node) -> ^Node {
    if n == nil do return nil
    if n.kind == .Leaf do return n
    l := tree_first_leaf(n.a)
    if l != nil do return l
    return tree_first_leaf(n.b)
}

// ─── Fenster einfügen: splittet das fokussierte Leaf ─────────────────────
tree_add :: proc(tl: ^XdgToplevel) {
    context = ctx
    leaf := node_new_leaf(tl)
    if g_server.active_ws.root == nil {
        g_server.active_ws.root = leaf
        fmt.println("[tree] root = erstes Fenster")
        return
    }
    target := tree_find_leaf(g_server.active_ws.root, g_server.focused)
    if target == nil do target = tree_first_leaf(g_server.active_ws.root)
    // Orientierung nach Seitenverhältnis: breiter als hoch → nebeneinander.
    r := target.tl.geom
    horizontal := r[2] >= r[3]
    orig_parent := target.parent    // VOR node_new_split sichern (das überschreibt a.parent!)
    is_root := orig_parent == nil
    split := node_new_split(target, leaf, horizontal)
    if is_root {
        g_server.active_ws.root = split
        split.parent = nil
    } else {
        p := orig_parent
        if p.a == target { p.a = split } else { p.b = split }
        split.parent = p
    }
    fmt.printfln("[tree] split %s (ratio %.2f)", horizontal ? "horizontal" : "vertikal", split.ratio)
}

// ─── Fenster entfernen (Unmap/Destroy): Eltern-Split kollabiert ───────────
tree_remove :: proc(tl: ^XdgToplevel) {
    context = ctx
    leaf := tree_find_leaf(g_server.active_ws.root, tl)
    if leaf == nil do return
    if leaf.parent == nil {
        g_server.active_ws.root = nil
        free(leaf, ctx.allocator)
        return
    }
    p := leaf.parent
    sibling := p.a == leaf ? p.b : p.a
    if p.parent == nil {
        g_server.active_ws.root = sibling
        sibling.parent = nil
    } else {
        gp := p.parent
        if gp.a == p { gp.a = sibling } else { gp.b = sibling }
        sibling.parent = gp
    }
    free(leaf, ctx.allocator)
    free(p, ctx.allocator)
}

// ─── Move: zwei Leaves swappen (nur tl-Pointer tauschen) ──────────────────
tree_swap :: proc(tl_a, tl_b: ^XdgToplevel) {
    na := tree_find_leaf(g_server.active_ws.root, tl_a)
    nb := tree_find_leaf(g_server.active_ws.root, tl_b)
    if na == nil || nb == nil do return
    tmp := na.tl
    na.tl = nb.tl
    nb.tl = tmp
}

// ─── Resize: Eltern-Split eines Leaves holen ──────────────────────────────
tree_parent_split :: proc(tl: ^XdgToplevel) -> ^Node {
    leaf := tree_find_leaf(g_server.active_ws.root, tl)
    if leaf == nil do return nil
    return leaf.parent
}