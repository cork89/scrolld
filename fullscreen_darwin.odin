package main

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import rl "vendor:raylib"

// Fullscreen is macOS's own (its own Space, with the animation), toggled on
// the NSWindow that raylib's GLFW backend hands back as the window handle.
is_fullscreen :: proc() -> bool {
	mask := intrinsics.objc_send(NS.WindowStyleMask, (^NS.Window)(rl.GetWindowHandle()), "styleMask")
	return .FullScreen in mask
}

set_fullscreen :: proc(on: bool) {
	if is_fullscreen() != on do NS.Window_toggleFullScreen((^NS.Window)(rl.GetWindowHandle()), nil)
}
