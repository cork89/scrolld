// scrolld: an auto-scrolling masonry wall of the images in a directory.
//
// Build:  just build   (odin build scrolld.odin -file -define:RAYLIB_SHARED=true -o:speed -out:bin/scrolld)
// Run:    ./bin/scrolld [dir] [-r] [-s] [-x]
//
// The grid is drawn directly with raylib; Clay lays out the top bar and the
// full-size viewer. The wall scrolls down in columns, right in rows (sideways),
// or away into the distance (crawl: the column grid is rendered to a texture
// drawn on a tilted 3D plane). Images are decoded and shrunk to lane size on worker
// threads, uploaded to the GPU a few per frame, and unloaded once they're well
// off screen, so memory stays flat no matter how long it scrolls.
//
// Settings changed in the app (mode, speed, lanes...) are saved to
// ~/.scrolld/settings whenever they change, and loaded on the next launch.
package main

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import NS "core:sys/darwin/Foundation"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import stbi "vendor:stb/image"
import clay "clay-odin"

// Requires Homebrew's raylib, webp and libheif packages.
//
// raylib's own copy of stb_image is built without JPEG support, and linking it
// statically clashes with vendor:stb/image. Linking raylib as a dylib keeps its
// copy private, so images are decoded with the full stb_image.
#assert(rl.RAYLIB_SHARED, "build with -define:RAYLIB_SHARED=true")

// WebP comes from Homebrew's libwebp (`brew install webp`).
@(extra_linker_flags = "-L/opt/homebrew/opt/webp/lib")
foreign import webp "system:webp"

WEBP_DECODER_ABI_VERSION :: 0x0210
WEBP_STATUS_NOT_ENOUGH_DATA :: 7

WebP_Features :: struct {
	width, height, has_alpha, has_animation, format: c.int,
	pad:                                             [5]u32,
}

@(default_calling_convention = "c")
foreign webp {
	WebPGetFeaturesInternal :: proc(data: [^]u8, size: c.size_t, features: ^WebP_Features, version: c.int) -> c.int ---
	WebPDecodeRGBA :: proc(data: [^]u8, size: c.size_t, width, height: ^c.int) -> [^]u8 ---
}

// HEIC/HEIF comes from Homebrew's libheif (`brew install libheif`).
@(extra_linker_flags = "-L/opt/homebrew/opt/libheif/lib")
foreign import heif "system:heif"

HEIF_COLORSPACE_RGB :: 1
HEIF_CHROMA_INTERLEAVED_RGBA :: 11
HEIF_CHANNEL_INTERLEAVED :: 10

Heif_Error :: struct {
	code, subcode: c.int,
	message:       cstring,
}

Heif_Context :: struct {}
Heif_Handle :: struct {}
Heif_Image :: struct {}

@(default_calling_convention = "c")
foreign heif {
	heif_init :: proc(params: rawptr) -> Heif_Error ---
	heif_context_alloc :: proc() -> ^Heif_Context ---
	heif_context_free :: proc(ctx: ^Heif_Context) ---
	heif_context_read_from_file :: proc(ctx: ^Heif_Context, filename: cstring, options: rawptr) -> Heif_Error ---
	heif_context_get_primary_image_handle :: proc(ctx: ^Heif_Context, handle: ^^Heif_Handle) -> Heif_Error ---
	heif_image_handle_get_width :: proc(handle: ^Heif_Handle) -> c.int ---
	heif_image_handle_get_height :: proc(handle: ^Heif_Handle) -> c.int ---
	heif_image_handle_release :: proc(handle: ^Heif_Handle) ---
	heif_decode_image :: proc(handle: ^Heif_Handle, img: ^^Heif_Image, colorspace, chroma: c.int, options: rawptr) -> Heif_Error ---
	heif_image_get_width :: proc(img: ^Heif_Image, channel: c.int) -> c.int ---
	heif_image_get_height :: proc(img: ^Heif_Image, channel: c.int) -> c.int ---
	heif_image_get_plane_readonly2 :: proc(img: ^Heif_Image, channel: c.int, stride: ^c.size_t) -> [^]u8 ---
	heif_image_release :: proc(img: ^Heif_Image) ---
}

USAGE :: `Usage: scrolld [dir] [options]

Show the images in a directory (default: current directory) as an
auto-scrolling masonry wall that wraps around forever.

Options:
  -r, --recursive   Include images in subdirectories
  -s, --shuffle     Random order (a new order on each pass)
  -x, --sideways    Start in sideways mode (rows scrolling right)
  -c, --crawl       Start in crawl mode (a tilted wall receding into the distance)
  -h, --help        Show this help

Keys:
  Space       Start / pause auto scroll
  + / -       Faster / slower
  [ / ]       Fewer / more columns or rows (0 = auto)
  D           Cycle vertical / sideways / crawl
  R           Crawl away from / toward you
  Wheel, arrows, PgUp/PgDn   Scroll manually
  Click       Open full size (Esc or click to close)
  F           Toggle fullscreen
  H, ☰ button Hide / show the top bar
  Esc, Q      Quit

Mode, speed, lanes, fullscreen, auto scroll and the top bar are remembered
in ~/.scrolld/settings. Options above override them for a run.`

GAP :: 10.0
BAR_H :: 56.0
MIN_COL_W :: 280.0
MIN_ROW_H :: 220.0
WORKERS :: 4
MAX_UPLOADS_PER_FRAME :: 4
SPEED_STEP :: 20.0
FADE_IN_SECS :: 0.25
TILE_RADIUS :: 8.0
CAPTION_H :: 40.0

// Crawl mode. World units are logical pixels * CRAWL_UNIT, keeping the plane
// inside raylib's default clip distances.
CRAWL_UNIT :: 0.01
CRAWL_FOVY :: 45.0
CRAWL_TILT :: 62.0 // degrees back from facing the camera
CRAWL_SCREENS :: 5.0 // plane length, in screen heights
CRAWL_MAX_TEX :: 8192 // render texture height cap, physical pixels

// Fades the far end of the crawl plane into the background.
CRAWL_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float toward; // 1 when the texture's v=1 edge is nearest
out vec4 finalColor;

void main() {
	float far = toward > 0.5 ? 1.0 - fragTexCoord.y : fragTexCoord.y;
	vec4 c = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
	finalColor = vec4(c.rgb, c.a * (1.0 - smoothstep(0.55, 1.0, far)));
}`

// Rounds a tile's corners with an antialiased rounded-rect distance field, and
// darkens its bottom edge behind the hover caption so that stays inside the
// corners too.
TILE_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 size;     // tile size in physical pixels
uniform float radius;  // physical pixels
uniform float caption; // caption band height in physical pixels, 0 = none
out vec4 finalColor;

void main() {
	vec2 p = fragTexCoord * size;
	vec2 q = abs(p - size * 0.5) - (size * 0.5 - radius);
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	vec4 c = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
	if (caption > 0.0) {
		c.rgb *= 1.0 - 0.7 * clamp((p.y - (size.y - caption)) / caption, 0.0, 1.0);
	}
	finalColor = vec4(c.rgb, c.a * clamp(0.5 - d, 0.0, 1.0));
}`

IMAGE_EXTS := [?]string{".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif"}

BG :: rl.Color{15, 15, 18, 255}
TILE_BG :: rl.Color{34, 34, 42, 255}
// Clay colors are 0-255 floats.
PANEL :: clay.Color{26, 26, 32, 230}
BUTTON :: clay.Color{42, 42, 51, 255}
BUTTON_HOVER :: clay.Color{56, 56, 68, 255}
ACCENT :: clay.Color{79, 140, 255, 255}
TEXT :: clay.Color{232, 232, 238, 255}
MUTED :: clay.Color{138, 138, 150, 255}

Format :: enum {
	Stb, // everything stb_image reads
	Webp,
	Heif,
}

Picture :: struct {
	path:   cstring,
	name:   string,
	width:  i32,
	height: i32,
	format: Format,
}

Tex_State :: enum {
	Empty,
	Loading,
	Ready,
	Failed,
}

// One per picture (not per tile), so a picture repeated by wrap-around shares a texture.
Tile_Tex :: struct {
	state:    Tex_State,
	tex:      rl.Texture2D,
	ready_at: f64, // for the fade-in
	used:     u64, // last frame it was near the viewport
}

// Placements live in lane space: `x`/`w` run across the lanes (columns, or rows
// when sideways) and `y`/`h` along the scroll direction; tile_rect maps them to
// the screen. They're generated in order and `y` never decreases, because each
// one goes into the currently shortest lane. That lets us binary search for
// the visible range.
Placement :: struct {
	pic:        int,
	x, y, w, h: f64,
}

Job :: struct {
	pic:        int,
	target_w:   i32,
	generation: u64,
	lightbox:   bool,
}

Result_Status :: enum {
	Ok,
	Skipped, // scrolled out of range before a worker got to it
	Failed,
}

Result :: struct {
	job:    Job,
	status: Result_Status,
	image:  rl.Image,
}

Loader :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	jobs:    [dynamic]Job,
	results: [dynamic]Result,
	quit:    bool,
	frame:   u64, // atomic
	wanted:  []u64, // atomic, per picture: last frame it was in range
}

Mode :: enum {
	Vertical,
	Sideways,
	Crawl,
}

MODE_NAMES := [Mode]string {
	.Vertical = "vertical",
	.Sideways = "sideways",
	.Crawl    = "crawl",
}

opts: struct {
	dir:       string,
	recursive: bool,
	shuffle:   bool,
}

// What's saved to the settings file; compared each frame to spot changes.
Settings :: struct {
	mode:         Mode,
	crawl_toward: bool,
	speed:        f64,
	lanes:        int,
	ui_hidden:    bool,
	autoscroll:   bool,
	fullscreen:   bool,
}

settings_dir: string // "" when $HOME isn't set: nothing is loaded or saved
settings_path: string

pics: [dynamic]Picture
texs: []Tile_Tex
loaded: [dynamic]int // pictures whose texture is Ready
loader: Loader
frame: u64
generation: u64 = 1 // bumped when thumbnails must be redone (lane size or direction changed)
thumb_px: i32 // lane size in physical pixels, rounded up
thumb_sideways: bool

// Layout
mode: Mode
sideways := false // mode == .Sideways, kept as a flag since the layout code checks it everywhere
lanes_setting := 0 // 0 = auto
lanes: int
lane_size: f64
lane_origin: f64 // screen offset of the first lane (below the bar when sideways)
heights: [dynamic]f64
placements: [dynamic]Placement
max_tile_h: f64
shuffle_seed: u64
perm: []int
perm_pass := -1

// Scrolling & UI
scroll: f64
autoscroll := false
speed := 80.0
ui_hidden := false
fullscreen := false
quit := false
ui_font: rl.Font
tile_shader: rl.Shader
tile_locs: struct {
	size, radius, caption: c.int,
}

crawl_toward := false // content comes out of the distance toward you
crawl_rt: rl.RenderTexture2D
crawl_shader: rl.Shader
crawl_toward_loc: c.int

lightbox: struct {
	open:   bool,
	pic:    int,
	tex:    rl.Texture2D,
	id:     u64,
	resume: bool,
}
lightbox_seq: u64

main :: proc() {
	// Flags override the saved settings, and get saved along with them.
	saved := load_settings()
	parse_args()
	heif_init(nil)
	scan()
	if len(pics) == 0 {
		fmt.eprintfln("scrolld: no images found in %s%s", opts.dir, opts.recursive ? "" : " (try --recursive)")
		os.exit(1)
	}
	if !opts.shuffle {
		slice.sort_by(pics[:], proc(a, b: Picture) -> bool {return a.name < b.name})
	}
	fmt.printfln("scrolld: %d images from %s", len(pics), opts.dir)

	texs = make([]Tile_Tex, len(pics))
	loader.wanted = make([]u64, len(pics))
	perm = make([]int, len(pics))
	shuffle_seed = rand.uint64()

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1280, 800, "scrolld")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)
	if fullscreen do set_fullscreen(true)

	ui_font = rl.LoadFontEx("/System/Library/Fonts/Supplemental/Arial.ttf", 48, nil, 0)
	rl.SetTextureFilter(ui_font.texture, .BILINEAR)

	tile_shader = rl.LoadShaderFromMemory(nil, TILE_FS)
	tile_locs.size = rl.GetShaderLocation(tile_shader, "size")
	tile_locs.radius = rl.GetShaderLocation(tile_shader, "radius")
	tile_locs.caption = rl.GetShaderLocation(tile_shader, "caption")
	crawl_shader = rl.LoadShaderFromMemory(nil, CRAWL_FS)
	crawl_toward_loc = rl.GetShaderLocation(crawl_shader, "toward")

	clay_memory := make([]u8, clay.MinMemorySize())
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(len(clay_memory)), raw_data(clay_memory))
	clay.Initialize(arena, {1280, 800}, {handler = clay_error})
	clay.SetMeasureTextFunction(measure_text, nil)

	workers: [WORKERS]^thread.Thread
	for &w in workers do w = thread.create_and_start(worker)
	defer {
		sync.mutex_lock(&loader.mutex)
		loader.quit = true
		sync.mutex_unlock(&loader.mutex)
		sync.cond_broadcast(&loader.cond)
		for w in workers {
			thread.join(w)
			thread.destroy(w)
		}
	}

	layout_cross, layout_sideways := -1.0, false
	for !rl.WindowShouldClose() && !quit {
		frame += 1
		sync.atomic_store(&loader.frame, frame)
		fullscreen = is_fullscreen() // also entered/left with the green button or ⌃⌘F
		now := rl.GetTime()
		dt := f64(rl.GetFrameTime())
		sw, sh := f64(rl.GetScreenWidth()), f64(rl.GetScreenHeight())

		// Along the scroll direction: the screen, or the whole crawl plane.
		view_len := mode == .Sideways ? sw : mode == .Crawl ? crawl_length(sh) : sh
		handle_keys(view_len)

		// Clay handles the top bar buttons while building the layout.
		clay.SetLayoutDimensions({f32(sw), f32(sh)})
		clay.SetPointerState(rl.GetMousePosition(), rl.IsMouseButtonDown(.LEFT))
		commands := build_ui(sw, sh)

		// Keys and buttons above may have changed the mode.
		sideways = mode == .Sideways
		view_len = sideways ? sw : mode == .Crawl ? crawl_length(sh) : sh
		if mode != .Crawl && crawl_rt.id != 0 {
			rl.UnloadRenderTexture(crawl_rt) // ~80MB of VRAM
			crawl_rt = {}
		}

		// Lanes span the width (columns), or the height below the bar (rows).
		bar := ui_hidden ? 0 : BAR_H
		cross, origin := sideways ? sh - bar : sw, sideways ? bar : 0
		if cross != layout_cross || origin != lane_origin || sideways != layout_sideways || lane_count(cross) != lanes {
			relayout(cross, origin)
			layout_cross, layout_sideways = cross, sideways
		}

		if !lightbox.open {
			wheel := rl.GetMouseWheelMoveV()
			scroll -= f64(sideways ? wheel.y + wheel.x : wheel.y) * 40
			if autoscroll do scroll += speed * dt
			scroll = max(scroll, 0)
		}

		view_top := scroll - content_lead() // content position at the screen's leading edge
		extend_layout(view_top + view_len * 4)
		update_textures(view_top, view_len)
		process_results(now)
		evict()

		if rl.IsMouseButtonPressed(.LEFT) {
			if lightbox.open {
				close_lightbox()
			} else if !pointer_over_ui() {
				mouse := rl.GetMousePosition()
				pic := crawl_tile_at(mouse, view_top, view_len, sw, sh) if mode == .Crawl else tile_at(mouse, view_top)
				if pic >= 0 do open_lightbox(pic)
			}
		}

		if mode == .Crawl do render_crawl_texture(view_top, view_len, sw, now)

		rl.BeginDrawing()
		rl.ClearBackground(BG)
		if mode == .Crawl do draw_crawl_plane(view_len, sw, sh)
		else do draw_grid(view_top, view_len, now)
		render_clay(&commands)
		rl.EndDrawing()

		if s := current_settings(); s != saved {
			save_settings(s)
			saved = s
		}

		free_all(context.temp_allocator)
	}
}

parse_args :: proc() {
	for arg in os.args[1:] {
		switch arg {
		case "-r", "--recursive":
			opts.recursive = true
		case "-s", "--shuffle":
			opts.shuffle = true
		case "-x", "--sideways":
			mode = .Sideways
		case "-c", "--crawl":
			mode = .Crawl
		case "-h", "--help":
			fmt.println(USAGE)
			os.exit(0)
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintfln("scrolld: unknown option %s\n\n%s", arg, USAGE)
				os.exit(2)
			}
			opts.dir = arg
		}
	}
	abs, err := os.get_absolute_path(opts.dir == "" ? "." : opts.dir, context.allocator)
	if err != nil || !os.is_dir(abs) {
		fmt.eprintfln("scrolld: not a directory: %s", opts.dir)
		os.exit(1)
	}
	opts.dir = abs
}

// --- Settings ----------------------------------------------------------------

// Reads `key = value` lines from ~/.scrolld/settings into the globals. Blank
// lines and `#` comments are skipped; a bad line is reported and ignored.
// Returns what was loaded, so main can tell when something changes.
load_settings :: proc() -> Settings {
	set_bool :: proc(dst: ^bool, s: string) -> bool {
		dst^ = strconv.parse_bool(s) or_return
		return true
	}

	defer free_all(context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return current_settings()
	settings_dir = strings.concatenate({home, "/.scrolld"})
	settings_path = strings.concatenate({settings_dir, "/settings"})

	data, err := os.read_entire_file(settings_path, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist do fmt.eprintfln("scrolld: can't read %s: %v", settings_path, err)
		return current_settings()
	}

	text := string(data)
	line_no := 0
	for line in strings.split_lines_iterator(&text) {
		line_no += 1
		line := strings.trim_space(line)
		if line == "" || strings.has_prefix(line, "#") do continue
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			fmt.eprintfln("scrolld: %s:%d: expected key = value", settings_path, line_no)
			continue
		}
		key, value := strings.trim_space(line[:eq]), strings.trim_space(line[eq + 1:])

		ok := true
		switch key {
		case "mode":
			ok = false
			for name, m in MODE_NAMES {
				if value == name do mode, ok = m, true
			}
		case "speed":
			if v, vok := strconv.parse_f64(value); vok do speed = clamp(v, 10, 2000)
			else do ok = false
		case "lanes":
			if v, vok := strconv.parse_int(value, 10); vok do lanes_setting = clamp(v, 0, 12)
			else do ok = false
		case "crawl_toward": ok = set_bool(&crawl_toward, value)
		case "ui_hidden":    ok = set_bool(&ui_hidden, value)
		case "autoscroll":   ok = set_bool(&autoscroll, value)
		case "fullscreen":   ok = set_bool(&fullscreen, value)
		case:
			fmt.eprintfln("scrolld: %s:%d: unknown setting %s", settings_path, line_no, key)
			continue
		}
		if !ok do fmt.eprintfln("scrolld: %s:%d: bad value for %s: %s", settings_path, line_no, key, value)
	}
	return current_settings()
}

current_settings :: proc() -> Settings {
	return {
		mode = mode,
		crawl_toward = crawl_toward,
		speed = speed,
		lanes = lanes_setting,
		ui_hidden = ui_hidden,
		// The lightbox pauses scrolling; save what it will resume to.
		autoscroll = lightbox.open ? lightbox.resume : autoscroll,
		fullscreen = fullscreen,
	}
}

// Writes to a temp file and renames it over the old one, so a crash mid-write
// can't leave a truncated file.
save_settings :: proc(s: Settings) {
	if settings_dir == "" do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "# scrolld settings, saved whenever they change in the app")
	fmt.sbprintln(&b, "# mode: vertical, sideways or crawl; lanes: 0 = auto")
	fmt.sbprintfln(&b, "mode = %s", MODE_NAMES[s.mode])
	fmt.sbprintfln(&b, "crawl_toward = %v", s.crawl_toward)
	fmt.sbprintfln(&b, "speed = %v", s.speed)
	fmt.sbprintfln(&b, "lanes = %d", s.lanes)
	fmt.sbprintfln(&b, "ui_hidden = %v", s.ui_hidden)
	fmt.sbprintfln(&b, "autoscroll = %v", s.autoscroll)
	fmt.sbprintfln(&b, "fullscreen = %v", s.fullscreen)

	tmp := strings.concatenate({settings_path, ".tmp"}, context.temp_allocator)
	err := os.make_directory(settings_dir)
	if err == .Exist do err = nil
	if err == nil do err = os.write_entire_file(tmp, strings.to_string(b))
	if err == nil do err = os.rename(tmp, settings_path)
	if err != nil do fmt.eprintfln("scrolld: can't save %s: %v", settings_path, err)
}

// Finds images and reads their dimensions from the file header only.
scan :: proc() {
	walker := os.walker_create(opts.dir)
	defer os.walker_destroy(&walker)
	webp_header := make([]u8, 64 * 1024)
	defer delete(webp_header)

	for info in os.walker_walk(&walker) {
		if _, err := os.walker_error(&walker); err != nil do continue
		if info.type == .Directory {
			if !opts.recursive || strings.has_prefix(info.name, ".") do os.walker_skip_dir(&walker)
			continue
		}
		if strings.has_prefix(info.name, ".") do continue
		ext := strings.to_lower(os.ext(info.name), context.temp_allocator)
		if !slice.contains(IMAGE_EXTS[:], ext) do continue

		path := strings.clone_to_cstring(info.fullpath)
		format: Format
		switch ext {
		case ".webp":          format = .Webp
		case ".heic", ".heif": format = .Heif
		}
		w, h, comp: c.int
		ok: bool
		switch format {
		case .Stb:  ok = stbi.info(path, &w, &h, &comp) != 0
		case .Webp: ok = webp_info(info.fullpath, webp_header, &w, &h)
		case .Heif: ok = heif_info(path, &w, &h)
		}
		if !ok || w <= 0 || h <= 0 {
			delete(path)
			continue
		}
		name := strings.clone(strings.trim_prefix(strings.trim_prefix(info.fullpath, opts.dir), "/"))
		append(&pics, Picture{path = path, name = name, width = w, height = h, format = format})
	}
	free_all(context.temp_allocator)
}

// Reads WebP dimensions from the start of the file, falling back to the whole
// file when metadata chunks (ICC, EXIF) push the image header further in.
// Animated WebPs are skipped: decoding them needs libwebpdemux.
webp_info :: proc(path: string, buf: []u8, w, h: ^c.int) -> bool {
	f, err := os.open(path)
	if err != nil do return false
	n, _ := os.read(f, buf)
	os.close(f)

	features: WebP_Features
	status := WebPGetFeaturesInternal(raw_data(buf), c.size_t(n), &features, WEBP_DECODER_ABI_VERSION)
	if status == WEBP_STATUS_NOT_ENOUGH_DATA && n == len(buf) {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil do return false
		defer delete(data)
		status = WebPGetFeaturesInternal(raw_data(data), c.size_t(len(data)), &features, WEBP_DECODER_ABI_VERSION)
	}
	if status != 0 || features.has_animation != 0 do return false
	w^, h^ = features.width, features.height
	return true
}

// Reads the primary image's size from the HEIF container, without decoding it.
// It's the size after rotation, which decoding also applies.
heif_info :: proc(path: cstring, w, h: ^c.int) -> bool {
	ctx := heif_context_alloc()
	defer heif_context_free(ctx)
	if heif_context_read_from_file(ctx, path, nil).code != 0 do return false
	handle: ^Heif_Handle
	if heif_context_get_primary_image_handle(ctx, &handle).code != 0 do return false
	defer heif_image_handle_release(handle)
	w^, h^ = heif_image_handle_get_width(handle), heif_image_handle_get_height(handle)
	return true
}

// --- Layout ------------------------------------------------------------------

lane_count :: proc(cross: f64) -> int {
	if lanes_setting > 0 do return lanes_setting
	return max(1, int(cross / (sideways ? MIN_ROW_H : MIN_COL_W)))
}

// Where content starts along the scroll direction: below the bar when
// vertical (tiles scroll under it), just the gap otherwise.
content_lead :: proc() -> f64 {
	if mode != .Vertical || ui_hidden do return GAP
	return BAR_H + GAP
}

// Maps a placement from lane space to the screen.
tile_rect :: proc(p: Placement, view_top: f64) -> rl.Rectangle {
	if sideways do return {f32(p.y - view_top), f32(p.x), f32(p.h), f32(p.w)}
	return {f32(p.x), f32(p.y - view_top), f32(p.w), f32(p.h)}
}

// Width to decode a thumbnail at: the lane size, or for rows, the width that
// gives the row height.
thumb_width :: proc(pic: int) -> i32 {
	if !sideways do return thumb_px
	p := pics[pic]
	return max(i32(math.ceil(f64(thumb_px) * f64(p.width) / f64(p.height))), 1)
}

// Which picture the k-th tile shows. Wraps around forever; with --shuffle,
// each pass through the folder gets its own (reproducible) order.
pic_for :: proc(k: int) -> int {
	n := len(pics)
	if !opts.shuffle do return k % n
	if pass := k / n; pass != perm_pass {
		state := rand.create(shuffle_seed + u64(pass))
		gen := runtime.default_random_generator(&state)
		for i in 0 ..< n do perm[i] = i
		rand.shuffle(perm, gen)
		perm_pass = pass
	}
	return perm[k % n]
}

extend_layout :: proc(until_y: f64, min_count := 0) {
	for {
		shortest := 0
		for h, i in heights do if h < heights[shortest] do shortest = i
		if len(placements) >= min_count && heights[shortest] >= until_y do return

		pic := pic_for(len(placements))
		aspect := f64(pics[pic].height) / f64(pics[pic].width)
		h := lane_size * (sideways ? 1 / aspect : aspect)
		x := lane_origin + GAP + f64(shortest) * (lane_size + GAP)
		append(&placements, Placement{pic = pic, x = x, y = heights[shortest], w = lane_size, h = h})
		heights[shortest] += h + GAP
		max_tile_h = max(max_tile_h, h)
	}
}

// Rebuilds the layout for a new size, lane count or direction, keeping the
// tile at the leading edge of the screen where it was.
relayout :: proc(cross, origin: f64) {
	anchor, anchor_dy := -1, 0.0
	view_top := scroll - content_lead()
	for i := first_index(view_top); i < len(placements); i += 1 {
		if placements[i].y + placements[i].h > view_top {
			anchor, anchor_dy = i, placements[i].y - scroll
			break
		}
	}

	lanes = lane_count(cross)
	lane_size = max((cross - GAP * f64(lanes + 1)) / f64(lanes), 1)
	lane_origin = origin
	resize(&heights, lanes)
	slice.fill(heights[:], 0)
	clear(&placements)
	max_tile_h = 0
	perm_pass = -1
	if anchor >= 0 {
		extend_layout(0, anchor + 1)
		scroll = max(placements[anchor].y - anchor_dy, 0)
	}

	// Thumbnails are decoded at lane size in physical pixels, rounded up so
	// small resizes don't throw them all away.
	px := i32(math.ceil(lane_size * f64(rl.GetWindowScaleDPI().x) / 128) * 128)
	if px != thumb_px || sideways != thumb_sideways {
		thumb_px, thumb_sideways = px, sideways
		reset_textures()
	}
}

// First placement that could overlap content y (accounts for tall tiles above).
first_index :: proc(y: f64) -> int {
	target := y - max_tile_h
	lo, hi := 0, len(placements)
	for lo < hi {
		mid := (lo + hi) / 2
		if placements[mid].y < target do lo = mid + 1
		else do hi = mid
	}
	return lo
}

tile_at :: proc(mouse: rl.Vector2, view_top: f64) -> int {
	if sideways do return tile_at_lane_point(f64(mouse.y), view_top + f64(mouse.x))
	return tile_at_lane_point(f64(mouse.x), view_top + f64(mouse.y))
}

// The picture at a point in lane space (across, along), or -1.
tile_at_lane_point :: proc(across, along: f64) -> int {
	for i := first_index(along); i < len(placements) && placements[i].y <= along; i += 1 {
		p := placements[i]
		if across >= p.x && across < p.x + p.w && along >= p.y && along < p.y + p.h do return p.pic
	}
	return -1
}

// --- Image loading -------------------------------------------------------------

worker :: proc() {
	for {
		sync.mutex_lock(&loader.mutex)
		for len(loader.jobs) == 0 && !loader.quit do sync.cond_wait(&loader.cond, &loader.mutex)
		if loader.quit {
			sync.mutex_unlock(&loader.mutex)
			return
		}
		job := pop_front(&loader.jobs)
		sync.mutex_unlock(&loader.mutex)

		res := Result{job = job}
		if !job.lightbox && sync.atomic_load(&loader.frame) > sync.atomic_load(&loader.wanted[job.pic]) + 30 {
			res.status = .Skipped
		} else {
			// CPU-only work is safe off the main thread; GPU upload is not.
			pic := pics[job.pic]
			switch pic.format {
			case .Stb:  res.image = load_image(pic.path)
			case .Webp: res.image = load_webp(string(pic.path))
			case .Heif: res.image = load_heif(pic.path)
			}
			if res.image.data == nil {
				res.status = .Failed
			} else if res.image.width > job.target_w {
				h := c.int(f64(res.image.height) * f64(job.target_w) / f64(res.image.width))
				rl.ImageResize(&res.image, job.target_w, max(h, 1))
			}
		}

		sync.mutex_lock(&loader.mutex)
		append(&loader.results, res)
		sync.mutex_unlock(&loader.mutex)
	}
}

// Decodes with stb_image into a raylib Image. Both use the C heap, so raylib
// can resize and free it.
load_image :: proc(path: cstring) -> rl.Image {
	w, h, channels: c.int
	data := stbi.load(path, &w, &h, &channels, 0)
	if data == nil do return {}
	format: rl.PixelFormat
	switch channels {
	case 1: format = .UNCOMPRESSED_GRAYSCALE
	case 2: format = .UNCOMPRESSED_GRAY_ALPHA
	case 3: format = .UNCOMPRESSED_R8G8B8
	case:   format = .UNCOMPRESSED_R8G8B8A8
	}
	return {data = data, width = w, height = h, mipmaps = 1, format = format}
}

// libwebp also allocates with malloc, so raylib can resize and free it too.
load_webp :: proc(path: string) -> rl.Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}
	defer delete(data)
	w, h: c.int
	pixels := WebPDecodeRGBA(raw_data(data), c.size_t(len(data)), &w, &h)
	if pixels == nil do return {}
	return {data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

// libheif owns its pixels, so they're copied (dropping any row padding) into a
// malloc'd buffer raylib can resize and free.
load_heif :: proc(path: cstring) -> rl.Image {
	ctx := heif_context_alloc()
	defer heif_context_free(ctx)
	if heif_context_read_from_file(ctx, path, nil).code != 0 do return {}
	handle: ^Heif_Handle
	if heif_context_get_primary_image_handle(ctx, &handle).code != 0 do return {}
	defer heif_image_handle_release(handle)
	img: ^Heif_Image
	if heif_decode_image(handle, &img, HEIF_COLORSPACE_RGB, HEIF_CHROMA_INTERLEAVED_RGBA, nil).code != 0 do return {}
	defer heif_image_release(img)

	w := heif_image_get_width(img, HEIF_CHANNEL_INTERLEAVED)
	h := heif_image_get_height(img, HEIF_CHANNEL_INTERLEAVED)
	stride: c.size_t
	src := heif_image_get_plane_readonly2(img, HEIF_CHANNEL_INTERLEAVED, &stride)
	row := c.size_t(w) * 4
	if src == nil || w <= 0 || h <= 0 || stride < row do return {}
	pixels := ([^]u8)(libc.malloc(row * c.size_t(h)))
	if pixels == nil do return {}
	for y in 0 ..< c.size_t(h) {
		libc.memcpy(pixels[y * row:], src[y * stride:], row)
	}
	return {data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

enqueue :: proc(job: Job, front := false) {
	sync.mutex_lock(&loader.mutex)
	if front do inject_at(&loader.jobs, 0, job)
	else do append(&loader.jobs, job)
	sync.mutex_unlock(&loader.mutex)
	sync.cond_signal(&loader.cond)
}

// Marks pictures between content y0 and y1 as in use, and optionally queues
// the ones that aren't loaded yet.
mark_range :: proc(y0, y1: f64, request: bool) {
	for i := first_index(y0); i < len(placements) && placements[i].y < y1; i += 1 {
		p := placements[i]
		if p.y + p.h < y0 do continue
		t := &texs[p.pic]
		t.used = frame
		sync.atomic_store(&loader.wanted[p.pic], frame)
		if request && t.state == .Empty {
			t.state = .Loading
			enqueue({pic = p.pic, target_w = thumb_width(p.pic), generation = generation})
		}
	}
}

update_textures :: proc(view_top, view_h: f64) {
	view_bottom := view_top + view_h
	// Visible tiles first, then a band ahead of (and a bit behind) the viewport.
	mark_range(view_top, view_bottom, true)
	mark_range(view_top - view_h * 0.5, view_bottom + view_h * 1.5, true)
	// Textures stay loaded within a wider band so they don't thrash at the edges.
	mark_range(view_top - view_h * 2, view_bottom + view_h * 3, false)
	if lightbox.open do texs[lightbox.pic].used = frame
}

process_results :: proc(now: f64) {
	batch: [MAX_UPLOADS_PER_FRAME]Result
	n := 0
	sync.mutex_lock(&loader.mutex)
	for n < len(batch) && len(loader.results) > 0 {
		batch[n] = pop_front(&loader.results)
		n += 1
	}
	sync.mutex_unlock(&loader.mutex)

	for &r in batch[:n] {
		defer rl.UnloadImage(r.image)
		if r.job.lightbox {
			if lightbox.open && r.job.generation == lightbox.id && r.status == .Ok {
				lightbox.tex = rl.LoadTextureFromImage(r.image)
				rl.SetTextureFilter(lightbox.tex, .BILINEAR)
			}
			continue
		}
		if r.job.generation != generation do continue // stale thumbnail size

		t := &texs[r.job.pic]
		switch r.status {
		case .Skipped:
			t.state = .Empty
		case .Failed:
			t.state = .Failed
		case .Ok:
			t.tex = rl.LoadTextureFromImage(r.image)
			rl.SetTextureFilter(t.tex, .BILINEAR)
			t.state = .Ready
			t.ready_at = now
			append(&loaded, r.job.pic)
		}
	}
}

evict :: proc() {
	for i := 0; i < len(loaded); {
		t := &texs[loaded[i]]
		if t.used < frame {
			rl.UnloadTexture(t.tex)
			t^ = {}
			unordered_remove(&loaded, i)
		} else {
			i += 1
		}
	}
}

reset_textures :: proc() {
	generation += 1
	for pic in loaded do rl.UnloadTexture(texs[pic].tex)
	clear(&loaded)
	slice.zero(texs)
	sync.mutex_lock(&loader.mutex)
	for len(loader.jobs) > 0 && !loader.jobs[len(loader.jobs) - 1].lightbox do pop(&loader.jobs)
	sync.mutex_unlock(&loader.mutex)
}

// --- Lightbox ----------------------------------------------------------------

open_lightbox :: proc(pic: int) {
	lightbox_seq += 1
	lightbox = {open = true, pic = pic, id = lightbox_seq, resume = autoscroll}
	autoscroll = false
	// Decode at the size it will be shown, in physical pixels.
	p := pics[pic]
	scale := min(f64(rl.GetRenderWidth()) * 0.95 / f64(p.width), f64(rl.GetRenderHeight()) * 0.9 / f64(p.height), 1)
	enqueue({pic = pic, target_w = max(i32(f64(p.width) * scale), 1), generation = lightbox_seq, lightbox = true}, front = true)
}

close_lightbox :: proc() {
	if lightbox.tex.id != 0 do rl.UnloadTexture(lightbox.tex)
	autoscroll = lightbox.resume
	lightbox = {}
}

// --- Input -------------------------------------------------------------------

handle_keys :: proc(view_len: f64) {
	pressed :: proc(keys: ..rl.KeyboardKey) -> bool {
		for k in keys do if rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k) do return true
		return false
	}

	if rl.IsKeyPressed(.ESCAPE) {
		if lightbox.open do close_lightbox()
		else do quit = true
	}
	if rl.IsKeyPressed(.Q) do quit = true
	if rl.IsKeyPressed(.SPACE) {
		if lightbox.open do close_lightbox()
		else do autoscroll = !autoscroll
	}
	if pressed(.EQUAL, .KP_ADD) do change_speed(SPEED_STEP)
	if pressed(.MINUS, .KP_SUBTRACT) do change_speed(-SPEED_STEP)
	if pressed(.LEFT_BRACKET) do change_lanes(-1)
	if pressed(.RIGHT_BRACKET) do change_lanes(1)
	if rl.IsKeyPressed(.ZERO) do lanes_setting = 0
	// On release: once the fullscreen transition starts, the window never gets
	// the key-up, so raylib would think F is still held and miss the next press.
	if rl.IsKeyReleased(.F) do set_fullscreen(!fullscreen)
	if rl.IsKeyPressed(.H) do ui_hidden = !ui_hidden
	if rl.IsKeyPressed(.D) do mode = Mode((int(mode) + 1) % len(Mode))
	if rl.IsKeyPressed(.R) do crawl_toward = !crawl_toward

	// Forward is down, or right when sideways; both arrow pairs work in either mode.
	if !lightbox.open {
		if pressed(.DOWN, .RIGHT) do scroll += 100
		if pressed(.UP, .LEFT) do scroll -= 100
		if pressed(.PAGE_DOWN) do scroll += view_len * 0.9
		if pressed(.PAGE_UP) do scroll -= view_len * 0.9
	}
}

// Fullscreen is macOS's own (its own Space, with the animation), toggled on
// the NSWindow that raylib's GLFW backend hands back as the window handle.
is_fullscreen :: proc() -> bool {
	mask := intrinsics.objc_send(NS.WindowStyleMask, (^NS.Window)(rl.GetWindowHandle()), "styleMask")
	return .FullScreen in mask
}

set_fullscreen :: proc(on: bool) {
	if is_fullscreen() != on do NS.Window_toggleFullScreen((^NS.Window)(rl.GetWindowHandle()), nil)
}

change_speed :: proc(delta: f64) {
	speed = clamp(speed + delta, 10, 2000)
}

change_lanes :: proc(delta: int) {
	lanes_setting = clamp((lanes_setting == 0 ? lanes : lanes_setting) + delta, 1, 12)
}

// --- Drawing -----------------------------------------------------------------

// `crawl` draws for the crawl texture: no hover, and with `crawl_toward` each
// image is flipped, because the texture is mapped onto the plane upside down.
draw_grid :: proc(view_top, view_len: f64, now: f64, crawl := false) {
	mouse := rl.GetMousePosition()
	dpi := rl.GetWindowScaleDPI().x
	flip := crawl && crawl_toward
	first := first_index(view_top)
	view_bottom := view_top + view_len

	// Placeholders (and hover detection) first...
	hovered := -1
	for i := first; i < len(placements) && placements[i].y < view_bottom; i += 1 {
		p := placements[i]
		if p.y + p.h < view_top do continue
		dst := tile_rect(p, view_top)
		// Skip it under fully faded-in images, where it would fringe the antialiased edge.
		t := &texs[p.pic]
		if t.state != .Ready || now - t.ready_at < FADE_IN_SECS {
			rl.DrawRectangleRounded(dst, TILE_RADIUS * 2 / min(dst.width, dst.height), 6, TILE_BG)
		}
		if !lightbox.open && rl.CheckCollisionPointRec(mouse, dst) do hovered = i
	}
	if crawl || (!ui_hidden && f64(mouse.y) <= BAR_H) || pointer_over_ui() do hovered = -1

	// ...then the loaded images through the rounding shader.
	rl.BeginShaderMode(tile_shader)
	radius := TILE_RADIUS * dpi
	rl.SetShaderValue(tile_shader, tile_locs.radius, &radius, .FLOAT)
	for i := first; i < len(placements) && placements[i].y < view_bottom; i += 1 {
		p := placements[i]
		t := &texs[p.pic]
		if p.y + p.h < view_top || t.state != .Ready do continue
		dst := tile_rect(p, view_top)
		size := [2]f32{dst.width * dpi, dst.height * dpi}
		caption := i == hovered ? CAPTION_H * dpi : 0
		// Uniforms apply to the whole pending batch, so flush before changing them.
		rlgl.DrawRenderBatchActive()
		rl.SetShaderValue(tile_shader, tile_locs.size, &size, .VEC2)
		rl.SetShaderValue(tile_shader, tile_locs.caption, &caption, .FLOAT)
		alpha := f32(clamp((now - t.ready_at) / FADE_IN_SECS, 0, 1))
		src := rl.Rectangle{0, 0, f32(t.tex.width), f32(t.tex.height)}
		if flip do src.height = -src.height
		rl.DrawTexturePro(t.tex, src, dst, {}, 0, rl.Fade(rl.WHITE, alpha))
	}
	rl.EndShaderMode()

	// File name on hover.
	if hovered >= 0 {
		dst := tile_rect(placements[hovered], view_top)
		y := dst.y + dst.height - CAPTION_H
		name := strings.clone_to_cstring(pics[placements[hovered].pic].name, context.temp_allocator)
		rl.BeginScissorMode(i32(dst.x), i32(y), i32(dst.width), i32(CAPTION_H))
		rl.DrawTextEx(ui_font, name, {dst.x + 10, y + 14}, 16, 0, rl.RAYWHITE)
		rl.EndScissorMode()
	}
}

// --- Crawl -------------------------------------------------------------------
//
// The column grid for the whole plane is drawn into a render texture, which is
// mapped onto a quad tilted back from the bottom edge of the screen. Away: the
// texture's bottom (newest content) is the near edge, so tiles appear at the
// bottom and recede. Toward: the texture's top is the near edge instead, so
// tiles come out of the distance.

crawl_length :: proc(sh: f64) -> f64 {
	return min(sh * CRAWL_SCREENS, CRAWL_MAX_TEX / f64(rl.GetWindowScaleDPI().y))
}

// Looking straight ahead, at the distance where the z=0 plane exactly fills
// the screen, so the plane's near edge spans the full width.
crawl_camera :: proc(sh: f64) -> rl.Camera3D {
	d := sh / 2 / math.tan(math.to_radians(f64(CRAWL_FOVY) / 2)) * CRAWL_UNIT
	return {position = {0, 0, f32(d)}, up = {0, 1, 0}, fovy = CRAWL_FOVY, projection = .PERSPECTIVE}
}

// Near-left, near-right, far-right, far-left.
crawl_corners :: proc(view_len, sw, sh: f64) -> [4]rl.Vector3 {
	tilt := math.to_radians(f64(CRAWL_TILT))
	x := f32(sw / 2 * CRAWL_UNIT)
	y := f32(-sh / 2 * CRAWL_UNIT)
	l := view_len * CRAWL_UNIT
	fy, fz := y + f32(l * math.cos(tilt)), f32(-l * math.sin(tilt))
	return {{-x, y, 0}, {x, y, 0}, {x, fy, fz}, {-x, fy, fz}}
}

render_crawl_texture :: proc(view_top, view_len, sw: f64, now: f64) {
	dpi := rl.GetWindowScaleDPI().x
	w, h := i32(sw * f64(dpi)), i32(view_len * f64(dpi))
	if crawl_rt.texture.width != w || crawl_rt.texture.height != h {
		if crawl_rt.id != 0 do rl.UnloadRenderTexture(crawl_rt)
		crawl_rt = rl.LoadRenderTexture(w, h)
	}

	rl.BeginTextureMode(crawl_rt)
	rl.ClearBackground(BG)
	rl.BeginMode2D({zoom = dpi}) // draw in logical pixels at full resolution
	draw_grid(view_top, view_len, now, crawl = true)
	rl.EndMode2D()
	rl.EndTextureMode()

	// The far end is heavily minified; mipmaps + anisotropic filtering keep it
	// from shimmering as it moves.
	rl.GenTextureMipmaps(&crawl_rt.texture)
	rl.SetTextureFilter(crawl_rt.texture, .TRILINEAR)
	rl.SetTextureFilter(crawl_rt.texture, .ANISOTROPIC_16X)
}

draw_crawl_plane :: proc(view_len, sw, sh: f64) {
	c := crawl_corners(view_len, sw, sh)
	// Render textures are stored bottom-up: v=0 is the bottom of what was drawn.
	near_v, far_v: f32 = 0, 1
	if crawl_toward do near_v, far_v = 1, 0
	toward: f32 = crawl_toward ? 1 : 0

	rl.BeginMode3D(crawl_camera(sh))
	rl.BeginShaderMode(crawl_shader)
	rl.SetShaderValue(crawl_shader, crawl_toward_loc, &toward, .FLOAT)
	rlgl.DisableBackfaceCulling()
	rlgl.SetTexture(crawl_rt.texture.id)
	rlgl.Begin(rlgl.QUADS)
	rlgl.Color4ub(255, 255, 255, 255)
	rlgl.TexCoord2f(0, near_v); rlgl.Vertex3f(c[0].x, c[0].y, c[0].z)
	rlgl.TexCoord2f(1, near_v); rlgl.Vertex3f(c[1].x, c[1].y, c[1].z)
	rlgl.TexCoord2f(1, far_v); rlgl.Vertex3f(c[2].x, c[2].y, c[2].z)
	rlgl.TexCoord2f(0, far_v); rlgl.Vertex3f(c[3].x, c[3].y, c[3].z)
	rlgl.End()
	rlgl.SetTexture(0)
	rlgl.EnableBackfaceCulling()
	rl.EndShaderMode()
	rl.EndMode3D()
}

// Casts the mouse onto the plane and maps the hit back into lane space.
crawl_tile_at :: proc(mouse: rl.Vector2, view_top, view_len, sw, sh: f64) -> int {
	c := crawl_corners(view_len, sw, sh)
	hit := rl.GetRayCollisionQuad(rl.GetScreenToWorldRay(mouse, crawl_camera(sh)), c[0], c[1], c[2], c[3])
	if !hit.hit do return -1
	// Distance from the near edge along the plane, in logical pixels.
	s := f64(hit.point.y - c[0].y) / math.cos(math.to_radians(f64(CRAWL_TILT))) / CRAWL_UNIT
	across := f64(hit.point.x) / CRAWL_UNIT + sw / 2
	along := view_top + (crawl_toward ? s : view_len - s)
	return tile_at_lane_point(across, along)
}

// --- Clay UI -----------------------------------------------------------------

build_ui :: proc(sw, sh: f64) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if !ui_hidden && !lightbox.open {
		if clay.UI()({
			id = clay.ID("topbar"),
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingFixed(BAR_H)},
				padding = {16, 16, 0, 0},
				childGap = 10,
				childAlignment = {y = .Center},
			},
			backgroundColor = PANEL,
		}) {
			label("scrolld", 22, TEXT)
			// label(fmt.tprintf("%d images", len(pics)), 15, MUTED)
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {}

			if button("toggle", autoscroll ? "Pause" : "Auto scroll", autoscroll) do autoscroll = !autoscroll

			label("   Speed", 15, MUTED)
			if button("slower", "-") do change_speed(-SPEED_STEP)
			label(fmt.tprintf("%d", int(speed)), 16, TEXT)
			if button("faster", "+") do change_speed(SPEED_STEP)

			label("  ", 15, MUTED)
			if button("vertical", "Vertical", mode == .Vertical) do mode = .Vertical
			if button("sideways", "Sideways", mode == .Sideways) do mode = .Sideways
			if button("crawl", "Crawl", mode == .Crawl) do mode = .Crawl
			// Labelled with the direction it switches to.
			if mode == .Crawl {
				if button("toward", crawl_toward ? "Away" : "Toward") do crawl_toward = !crawl_toward
			}

			label(sideways ? "   Rows" : "   Columns", 15, MUTED)
			if button("fewer", "-") do change_lanes(-1)
			label(lanes_setting == 0 ? fmt.tprintf("Auto (%d)", lanes) : fmt.tprintf("%d", lanes), 16, TEXT)
			if button("more", "+") do change_lanes(1)
			if lanes_setting != 0 {
				if button("auto", "Auto") do lanes_setting = 0
			}

			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(6)}}}) {}
			if menu_button(.Close) do ui_hidden = true
		}
	} else if ui_hidden && !lightbox.open {
		// Only the menu button, floating where it sits in the bar.
		floating := clay.FloatingElementConfig {
			attachTo   = .Root,
			attachment = {element = .RightTop, parent = .RightTop},
			offset     = {-16, (BAR_H - 30) / 2},
			zIndex     = 5,
		}
		if menu_button(.Menu, floating) do ui_hidden = false
	}

	if lightbox.open {
		tex: ^rl.Texture2D
		if lightbox.tex.id != 0 do tex = &lightbox.tex
		else if texs[lightbox.pic].state == .Ready do tex = &texs[lightbox.pic].tex // thumbnail until the full image arrives

		p := pics[lightbox.pic]
		scale := min(sw * 0.95 / f64(p.width), (sh - 50) * 0.95 / f64(p.height), 1)
		if clay.UI()({
			id = clay.ID("lightbox"),
			floating = {attachTo = .Root, zIndex = 10},
			layout = {
				sizing = {clay.SizingFixed(f32(sw)), clay.SizingFixed(f32(sh))},
				childAlignment = {.Center, .Center},
				layoutDirection = .TopToBottom,
				childGap = 12,
			},
			backgroundColor = {0, 0, 0, 235},
		}) {
			if tex != nil {
				if clay.UI()({
					layout = {sizing = {clay.SizingFixed(f32(f64(p.width) * scale)), clay.SizingFixed(f32(f64(p.height) * scale))}},
					image = {imageData = tex},
				}) {}
			}
			label(fmt.tprintf("%s   (%d x %d)", p.name, p.width, p.height), 15, MUTED)
		}
	}

	return clay.EndLayout()
}

label :: proc(text: string, size: u16, color: clay.Color) {
	clay.TextDynamic(text, clay.TextConfig({fontSize = size, textColor = color, wrapMode = .None}))
}

button :: proc(id: string, text: string, active := false) -> (clicked: bool) {
	if clay.UI()({
		id = clay.ID(id),
		layout = {padding = {12, 12, 7, 7}},
		backgroundColor = active ? ACCENT : clay.Hovered() ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(8),
	}) {
		label(text, 16, TEXT)
		clicked = clay.Hovered() && rl.IsMouseButtonPressed(.LEFT)
	}
	return
}

Icon :: enum uintptr {
	Menu = 1,
	Close,
}

// The icon is a Clay custom element (Clay can't draw diagonals); render_clay draws it.
menu_button :: proc(icon: Icon, floating: clay.FloatingElementConfig = {}) -> (clicked: bool) {
	if clay.UI()({
		id = clay.ID("menu"),
		layout = {sizing = {clay.SizingFixed(36), clay.SizingFixed(30)}, childAlignment = {.Center, .Center}},
		backgroundColor = clay.Hovered() ? BUTTON_HOVER : BUTTON,
		cornerRadius = clay.CornerRadiusAll(8),
		floating = floating,
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingFixed(16), clay.SizingFixed(14)}},
			custom = {customData = rawptr(uintptr(icon))},
		}) {}
		clicked = clay.Hovered() && rl.IsMouseButtonPressed(.LEFT)
	}
	return
}

draw_icon :: proc(icon: Icon, b: clay.BoundingBox, color: rl.Color) {
	switch icon {
	case .Menu:
		for i in 0 ..< 3 {
			bar := rl.Rectangle{b.x, b.y + f32(i) * (b.height - 2) / 2, b.width, 2}
			rl.DrawRectangleRounded(bar, 1, 4, color)
		}
	case .Close:
		// Square, and a little smaller than the bars so it looks the same weight.
		s := min(b.width, b.height) - 2
		x, y := b.x + (b.width - s) / 2, b.y + (b.height - s) / 2
		rl.DrawLineEx({x, y}, {x + s, y + s}, 2, color)
		rl.DrawLineEx({x + s, y}, {x, y + s}, 2, color)
	}
}

pointer_over_ui :: proc() -> bool {
	return clay.PointerOver(clay.ID("topbar")) || clay.PointerOver(clay.ID("menu"))
}

render_clay :: proc(commands: ^clay.ClayArray(clay.RenderCommand)) {
	to_rl :: proc(c: clay.Color) -> rl.Color {return {u8(c.r), u8(c.g), u8(c.b), u8(c.a)}}

	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i)
		b := cmd.boundingBox
		rect := rl.Rectangle{b.x, b.y, b.width, b.height}
		#partial switch cmd.commandType {
		case .Rectangle:
			d := cmd.renderData.rectangle
			if r := d.cornerRadius.topLeft; r > 0 {
				rl.DrawRectangleRounded(rect, r * 2 / min(b.width, b.height), 8, to_rl(d.backgroundColor))
			} else {
				rl.DrawRectangleRec(rect, to_rl(d.backgroundColor))
			}
		case .Text:
			d := cmd.renderData.text
			text := strings.clone_to_cstring(string(d.stringContents.chars[:d.stringContents.length]), context.temp_allocator)
			rl.DrawTextEx(ui_font, text, {b.x, b.y}, f32(d.fontSize), f32(d.letterSpacing), to_rl(d.textColor))
		case .Image:
			tex := (^rl.Texture2D)(cmd.renderData.image.imageData)^
			rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, rect, {}, 0, rl.WHITE)
		case .Custom:
			draw_icon(Icon(uintptr(cmd.renderData.custom.customData)), b, to_rl(TEXT))
		case .ScissorStart:
			rl.BeginScissorMode(i32(b.x), i32(b.y), i32(b.width), i32(b.height))
		case .ScissorEnd:
			rl.EndScissorMode()
		}
	}
}

// Matches how raylib's DrawTextEx advances glyphs (letter spacing is always 0 here).
measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	scale := f32(config.fontSize) / f32(ui_font.baseSize)
	width: f32
	for i in 0 ..< int(text.length) {
		g := rl.GetGlyphIndex(ui_font, rune(text.chars[i]))
		adv := f32(ui_font.glyphs[g].advanceX)
		width += adv != 0 ? adv : ui_font.recs[g].width + f32(ui_font.glyphs[g].offsetX)
	}
	return {width * scale, f32(config.fontSize)}
}

clay_error :: proc "c" (err: clay.ErrorData) {
	context = runtime.default_context()
	fmt.eprintln("clay:", string(err.errorText.chars[:err.errorText.length]))
}
