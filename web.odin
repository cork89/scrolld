#+build js
package main

// The web build: scrolld.wasm in a page, with web/raylib.js standing in for
// raylib (on WebGL 2) and web/scrolld.js for the rest. The images are listed in
// images/manifest.txt next to the page, the browser decodes and shrinks them
// off the main thread, and settings are kept in localStorage. Flags come from
// the page's query string: ?shuffle&crawl&sideways.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

UI_FONT :: "Arial" // a CSS font family: raylib.js renders the glyphs with the browser's text

MAX_IN_FLIGHT :: 8 // images the browser is fetching and decoding at once

// An ImageBitmap held by scrolld.js until it's uploaded or released.
Decoded :: struct {
	bitmap:        i32, // 0 = none
	width, height: i32,
}

Web_Result :: struct {
	id:    i32,
	ok:    b32,
	image: Decoded,
}

foreign import scrolld_js "scrolld"

@(default_calling_convention = "contextless")
foreign scrolld_js {
	// Each returns its text's length, copying it into buf when it fits, or -1
	// when there's none.
	js_manifest :: proc(buf: []u8) -> int ---
	js_args :: proc(buf: []u8) -> int ---
	js_settings :: proc(buf: []u8) -> int ---
	js_save_settings :: proc(text: string) ---

	// Fetches and decodes images/name at w x h, for js_poll to hand back as id.
	js_load :: proc(id: i32, name: string, w, h: i32) ---
	js_poll :: proc(result: ^Web_Result) -> b32 ---
	js_upload :: proc(bitmap: i32, tex: ^rl.Texture2D) ---
	js_release :: proc(bitmap: i32) ---
}

// Jobs wait here while MAX_IN_FLIGHT are with the browser; like a worker,
// dispatch skips the ones that have scrolled out of range by then.
Loader :: struct {
	jobs:      [dynamic]Job,
	skipped:   [dynamic]Result,
	in_flight: map[i32]Job,
	next_id:   i32,
	wanted:    []u64, // per picture: last frame it was in range
}

loader: Loader

main :: proc() {
	saved_settings = load_settings()
	if args, ok := read_text(js_args); ok {
		for arg in strings.split_lines_iterator(&args) do apply_flag(arg)
	}
	opts.dir = "images"
	scan()
	if len(pics) == 0 {
		fmt.eprintln("scrolld: no images in images/manifest.txt")
		return
	}
	loader.wanted = make([]u64, len(pics))
	init()
}

// Called by odin.js every animation frame. There's no quitting a page, so Q
// and Esc do nothing but close the lightbox.
@(export)
step :: proc(dt: f64) -> (keep_going: bool) {
	update_frame()
	return true
}

// Zeroed memory for raylib.js to fill in where raylib allocates itself: a
// Font's glyphs and recs.
@(export)
web_alloc :: proc "contextless" (size: i32) -> rawptr {
	context = runtime.default_context()
	data, _ := mem.alloc(int(size))
	return data
}

read_text :: proc(get: proc "contextless" (buf: []u8) -> int) -> (text: string, ok: bool) {
	n := get(nil)
	if n < 0 do return
	buf := make([]u8, n, context.temp_allocator)
	get(buf)
	return string(buf), true
}

// Reads images/manifest.txt: a `name<TAB>width<TAB>height` line per image.
scan :: proc() {
	text := read_text(js_manifest) or_else ""
	for line in strings.split_lines_iterator(&text) {
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != 3 do continue
		w, w_ok := strconv.parse_int(fields[1], 10)
		h, h_ok := strconv.parse_int(fields[2], 10)
		if !w_ok || !h_ok || w <= 0 || h <= 0 do continue
		name := strings.clone(fields[0])
		append(&pics, Picture{path = strings.clone_to_cstring(name), name = name, width = i32(w), height = i32(h)})
	}
	free_all(context.temp_allocator)
}

load_settings :: proc() -> Settings {
	defer free_all(context.temp_allocator)
	if text, ok := read_text(js_settings); ok do parse_settings(text, "localStorage")
	return current_settings()
}

save_settings :: proc(s: Settings) {
	js_save_settings(format_settings(s))
}

enqueue :: proc(job: Job, front := false) {
	if front do inject_at(&loader.jobs, 0, job)
	else do append(&loader.jobs, job)
	dispatch()
}

dispatch :: proc() {
	for len(loader.jobs) > 0 && len(loader.in_flight) < MAX_IN_FLIGHT {
		job := pop_front(&loader.jobs)
		if !job.lightbox && frame > loader.wanted[job.pic] + 30 {
			append(&loader.skipped, Result{job = job, status = .Skipped})
			continue
		}
		loader.next_id += 1
		loader.in_flight[loader.next_id] = job
		pic := pics[job.pic]
		w, h := shrunk(pic.width, pic.height, job.target_w)
		js_load(loader.next_id, pic.name, w, h)
	}
}

loader_begin_frame :: proc() {
	dispatch()
}

want :: proc(pic: int) {
	loader.wanted[pic] = frame
}

next_result :: proc() -> (r: Result, ok: bool) {
	if len(loader.skipped) > 0 do return pop_front(&loader.skipped), true
	res: Web_Result
	for js_poll(&res) {
		job, known := loader.in_flight[res.id]
		if !known {
			js_release(res.image.bitmap)
			continue
		}
		delete_key(&loader.in_flight, res.id)
		return {job = job, status = res.ok ? .Ok : .Failed, image = res.image}, true
	}
	return
}

upload :: proc(img: Decoded) -> (tex: rl.Texture2D) {
	js_upload(img.bitmap, &tex)
	return
}

// A no-op for an uploaded bitmap, which js_upload has already let go.
release :: proc(img: Decoded) {
	if img.bitmap != 0 do js_release(img.bitmap)
}

drop_queued_thumbnails :: proc() {
	for len(loader.jobs) > 0 && !loader.jobs[len(loader.jobs) - 1].lightbox do pop(&loader.jobs)
}
