package probe
import wl "../../wlclient"
import "core:fmt"
import "base:runtime"
gctx: runtime.Context
rg :: proc "c" (d: rawptr, r: ^wl.registry, name: uint, iface: cstring, ver: uint) {
    context = gctx; fmt.printfln("  %-40s v%d", string(iface), ver)
}
rg_rm :: proc "c" (d: rawptr, r: ^wl.registry, name: uint) {}
main :: proc() {
    gctx = context
    d := wl.display_connect(nil)
    if d == nil { fmt.println("no display"); return }
    r := wl.display_get_registry(d)
    l := wl.registry_listener{ global = rg, global_remove = rg_rm }
    wl.registry_add_listener(r, &l, nil)
    wl.display_roundtrip(d)
}
