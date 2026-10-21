#+build !darwin
package main

import rl "vendor:raylib"

// Elsewhere fullscreen is raylib's borderless window covering the monitor,
// which keeps the desktop resolution and switches instantly.
is_fullscreen :: proc() -> bool {
	return rl.IsWindowState({.BORDERLESS_WINDOWED_MODE})
}

set_fullscreen :: proc(on: bool) {
	if is_fullscreen() != on do rl.ToggleBorderlessWindowed()
}
