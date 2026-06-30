#+build linux
package wp

import wl ".."

// ═══════════════════════════════════════════════════════════════════════════
//  Gemeinsame Re-Exports für package wp.
//  Die odin-wayland Scanner-Dateien nutzen interface/message/fixed_t/proxy
//  als bare names — hier einmalig für das gesamte wp-Package re-exportiert.
// ═══════════════════════════════════════════════════════════════════════════

interface :: wl.interface
message  :: wl.message
fixed_t  :: wl.fixed_t
proxy    :: wl.proxy

generic_c_call        :: wl.generic_c_call
proxy_add_listener    :: wl.proxy_add_listener
proxy_get_user_data   :: wl.proxy_get_user_data
proxy_set_user_data   :: wl.proxy_set_user_data
proxy_marshal_flags   :: wl.proxy_marshal_flags
proxy_get_version     :: wl.proxy_get_version