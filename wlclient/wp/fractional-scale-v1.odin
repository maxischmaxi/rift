#+build linux
package wp
import wl ".."

@(private)
fractional_scale_v1_types := []^interface {
	nil,
	&fractional_scale_v1_interface,
	&wl.surface_interface,
}
/* A global interface for requesting surfaces to use fractional scales. */
fractional_scale_manager_v1 :: struct {}
fractional_scale_manager_v1_set_user_data :: proc "contextless" (fractional_scale_manager_v1_: ^fractional_scale_manager_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)fractional_scale_manager_v1_, user_data)
}

fractional_scale_manager_v1_get_user_data :: proc "contextless" (fractional_scale_manager_v1_: ^fractional_scale_manager_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)fractional_scale_manager_v1_)
}

/* Informs the server that the client will not be using this protocol
        object anymore. This does not affect any other objects,
        wp_fractional_scale_v1 objects included. */
FRACTIONAL_SCALE_MANAGER_V1_DESTROY :: 0
fractional_scale_manager_v1_destroy :: proc "contextless" (fractional_scale_manager_v1_: ^fractional_scale_manager_v1) {
	proxy_marshal_flags(cast(^proxy)fractional_scale_manager_v1_, FRACTIONAL_SCALE_MANAGER_V1_DESTROY, nil, proxy_get_version(cast(^proxy)fractional_scale_manager_v1_), 1)
}

/* Create an add-on object for the the wl_surface to let the compositor
        request fractional scales. If the given wl_surface already has a
        wp_fractional_scale_v1 object associated, the fractional_scale_exists
        protocol error is raised. */
FRACTIONAL_SCALE_MANAGER_V1_GET_FRACTIONAL_SCALE :: 1
fractional_scale_manager_v1_get_fractional_scale :: proc "contextless" (fractional_scale_manager_v1_: ^fractional_scale_manager_v1, surface_: ^wl.surface) -> ^fractional_scale_v1 {
	ret := proxy_marshal_flags(cast(^proxy)fractional_scale_manager_v1_, FRACTIONAL_SCALE_MANAGER_V1_GET_FRACTIONAL_SCALE, &fractional_scale_v1_interface, proxy_get_version(cast(^proxy)fractional_scale_manager_v1_), 0, nil, surface_)
	return cast(^fractional_scale_v1)ret
}

/*  */
fractional_scale_manager_v1_error :: enum {
	fractional_scale_exists = 0,
}
@(private)
fractional_scale_manager_v1_requests := []message {
	{"destroy", "", raw_data(fractional_scale_v1_types)[0:]},
	{"get_fractional_scale", "no", raw_data(fractional_scale_v1_types)[1:]},
}

fractional_scale_manager_v1_interface : interface

/* An additional interface to a wl_surface object which allows the compositor
      to inform the client of the preferred scale. */
fractional_scale_v1 :: struct {}
fractional_scale_v1_set_user_data :: proc "contextless" (fractional_scale_v1_: ^fractional_scale_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)fractional_scale_v1_, user_data)
}

fractional_scale_v1_get_user_data :: proc "contextless" (fractional_scale_v1_: ^fractional_scale_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)fractional_scale_v1_)
}

/* Destroy the fractional scale object. When this object is destroyed,
        preferred_scale events will no longer be sent. */
FRACTIONAL_SCALE_V1_DESTROY :: 0
fractional_scale_v1_destroy :: proc "contextless" (fractional_scale_v1_: ^fractional_scale_v1) {
	proxy_marshal_flags(cast(^proxy)fractional_scale_v1_, FRACTIONAL_SCALE_V1_DESTROY, nil, proxy_get_version(cast(^proxy)fractional_scale_v1_), 1)
}

fractional_scale_v1_listener :: struct {
/* Notification of a new preferred scale for this surface that the
        compositor suggests that the client should use.

        The sent scale is the numerator of a fraction with a denominator of 120. */
	preferred_scale : proc "c" (data: rawptr, fractional_scale_v1: ^fractional_scale_v1, scale_: uint),

}
fractional_scale_v1_add_listener :: proc "contextless" (fractional_scale_v1_: ^fractional_scale_v1, listener: ^fractional_scale_v1_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)fractional_scale_v1_, cast(^generic_c_call)listener,data)
}
@(private)
fractional_scale_v1_requests := []message {
	{"destroy", "", raw_data(fractional_scale_v1_types)[0:]},
}

@(private)
fractional_scale_v1_events := []message {
	{"preferred_scale", "u", raw_data(fractional_scale_v1_types)[0:]},
}

fractional_scale_v1_interface : interface

@(private)
@(init)
init_interfaces_fractional_scale_v1 :: proc "contextless" () {
	fractional_scale_manager_v1_interface.name = "wp_fractional_scale_manager_v1"
	fractional_scale_manager_v1_interface.version = 1
	fractional_scale_manager_v1_interface.method_count = 2
	fractional_scale_manager_v1_interface.event_count = 0
	fractional_scale_manager_v1_interface.methods = raw_data(fractional_scale_manager_v1_requests)
	fractional_scale_v1_interface.name = "wp_fractional_scale_v1"
	fractional_scale_v1_interface.version = 1
	fractional_scale_v1_interface.method_count = 1
	fractional_scale_v1_interface.event_count = 1
	fractional_scale_v1_interface.methods = raw_data(fractional_scale_v1_requests)
	fractional_scale_v1_interface.events = raw_data(fractional_scale_v1_events)
}



