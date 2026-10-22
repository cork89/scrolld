// scrolld: an auto-scrolling masonry wall of the images in a directory.
//
// Build:  just build   (odin build . -define:RAYLIB_SHARED=true -o:speed -out:bin/scrolld)
// Run:    ./bin/scrolld [dir] [-r] [-s] [-x]
//
// The grid is drawn with raylib on a plane in 3D; Clay lays out the top bar,
// the angle panel and the full-size viewer. The wall scrolls in any of eight
// compass directions, and the plane can be tilted, turned and spun, with lanes
// added past the screen's edges so it always fills the screen. Images are
// decoded and shrunk to lane size on worker threads, uploaded to the GPU a few
// per frame, and unloaded once they're well off screen, so memory stays flat no
// matter how long it scrolls.
//
// Settings changed in the app (direction, angle, speed, lanes...) are saved to
// ~/.scrolld/settings whenever they change, and loaded on the next launch.
package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import stbi "vendor:stb/image"
import clay "clay-odin"

// Requires Homebrew's raylib, webp and libheif packages on macOS. On Windows,
// raylib comes with Odin, webp is Google's static build fetched by `just deps`,
// and libheif is windows/libheif.dll, built HEVC-decode-only by `just libheif`.
//
// raylib's own copy of stb_image is built without JPEG support, and linking it
// statically clashes with vendor:stb/image. Linking raylib as a dylib keeps its
// copy private, so images are decoded with the full stb_image.
#assert(rl.RAYLIB_SHARED, "build with -define:RAYLIB_SHARED=true")

// WebP comes from Homebrew's libwebp (`brew install webp`).
when ODIN_OS == .Windows {
	foreign import webp "windows/libwebp/lib/libwebp.lib"
} else {
	@(extra_linker_flags = "-L/opt/homebrew/opt/webp/lib")
	foreign import webp "system:webp"
}

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
when ODIN_OS == .Windows {
	foreign import heif "windows/heif.lib"
} else {
	@(extra_linker_flags = "-L/opt/homebrew/opt/libheif/lib")
	foreign import heif "system:heif"
}

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
  -x, --sideways    Start scrolling right (rows)
  -c, --crawl       Start tilted back, receding into the distance
  -h, --help        Show this help

Keys:
  Space       Start / pause auto scroll
  + / -       Faster / slower
  [ / ]       Fewer / more lanes (0 = auto)
  D           Next direction, clockwise
  A           Show / hide the angle panel
  R           Reset the angle to flat
  Wheel, arrows, PgUp/PgDn   Scroll manually
  Click       Open full size (Esc or click to close)
  Drag        Rotate the wall, while the angle panel is open
              (Shift: one axis at a time, Ctrl or Cmd: spin)
  F           Toggle fullscreen
  H, ☰ button Hide / show the top bar
  Esc, Q      Quit

Direction, angle, speed, lanes, fullscreen, auto scroll and the top bar are
remembered in ~/.scrolld/settings. Options above override them for a run.`

GAP :: 10.0
BAR_H :: 56.0
MIN_COL_W :: 280.0
MIN_ROW_H :: 220.0
WORKERS :: 4
MAX_UPLOADS_PER_FRAME :: 4
EVICT_AFTER_FRAMES :: 180
SPEED_STEP :: 20.0
FADE_IN_SECS :: 0.25
TILE_RADIUS :: 8.0
CAPTION_H :: 40.0

// The wall is a plane through the middle of the screen, seen from the distance
// where it exactly fills the screen when flat. World units are logical pixels *
// PLANE_UNIT, keeping it inside raylib's default clip distances.
PLANE_UNIT :: 0.01
PLANE_FAR :: 4.4 // how far behind the screen the wall has faded out, in screen heights
MAX_TILT :: 75.0
MAX_SIDE_LANES :: 40
DEFAULT_FOV :: 45.0
CRAWL_TILT :: 62.0 // the Crawl preset
DRAG_DEGREES_PER_PX :: 0.3

// raylib's default vertex shader, plus how far behind the screen each vertex
// is (0 at the screen, 1 where the wall has faded out). rlgl applies the
// plane's transform on the CPU, so vertexPosition is already in world space.
GRID_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
uniform mat4 mvp;
uniform float fadeDepth; // world depth where the wall has faded out, 0 = no fade
out vec2 fragTexCoord;
out vec4 fragColor;
out float fragFar;

void main() {
	fragTexCoord = vertexTexCoord;
	fragColor = vertexColor;
	fragFar = fadeDepth > 0.0 ? -vertexPosition.z / fadeDepth : 0.0;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}`

// Placeholders: fades the far end of the wall into the background.
FADE_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
in float fragFar;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
out vec4 finalColor;

void main() {
	vec4 c = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
	finalColor = vec4(c.rgb, c.a * (1.0 - smoothstep(0.55, 1.0, fragFar)));
}`

// Rounds a tile's corners with an antialiased rounded-rect distance field, and
// darkens its bottom edge behind the hover caption so that stays inside the
// corners too. The edge is antialiased over one screen pixel, however small
// the tile is drawn, and fades like FADE_FS.
TILE_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
in float fragFar;
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
	float aa = max(length(vec2(dFdx(d), dFdy(d))), 1e-4);
	float fade = 1.0 - smoothstep(0.55, 1.0, fragFar);
	finalColor = vec4(c.rgb, c.a * fade * clamp(0.5 - d / aa, 0.0, 1.0));
}`

ICON_PNG :: #load("icon.png") // icon.svg rendered at 256 px

IMAGE_EXTS :=[?]string{".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif"}

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

// Placements live in lane space: `x`/`w` run across the lanes and `y`/`h` along
// the scroll direction, with the lanes centered on x = 0; the plane maps them
// onto the screen. They're generated in order and `y` never decreases, because each
// one goes into the currently shortest lane. That lets us binary search for
// the visible range.
Placement :: struct {
	pic:        int,
	block:      int, // see extend_layout
	k:          int, // the block's k-th tile
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

// Which way the content moves on screen, clockwise from up in 45° steps.
Direction :: enum {
	N,
	NE,
	E,
	SE,
	S,
	SW,
	W,
	NW,
}

DIRECTION_NAMES := [Direction]string {
	.N  = "n",
	.NE = "ne",
	.E  = "e",
	.SE = "se",
	.S  = "s",
	.SW = "sw",
	.W  = "w",
	.NW = "nw",
}

// How lane space lands on the screen, worked out each frame from the
// direction and angle.
Plane :: struct {
	// World vectors for one logical pixel along lane x and y, and the plane's
	// normal at the same scale. Lane space is centered on the screen at scroll.
	a, b, n:    [3]f64,
	cam:        rl.Camera3D,
	fade_depth: f64, // world depth behind the screen where the wall has faded out
	// The part of the wall on screen, as a convex polygon in lane space
	// relative to scroll, and its bounds.
	poly:       [16][2]f64,
	poly_n:     int,
	lo, hi:     [2]f64,
	// Each edge's normal, and the polygon's extent along it.
	axes:       [16][2]f64,
	spans:      [16][2]f64,
}

opts: struct {
	dir:       string,
	recursive: bool,
	shuffle:   bool,
}

// What's saved to the settings file; compared each frame to spot changes.
Settings :: struct {
	direction:    Direction,
	tilt_x:       f64,
	tilt_y:       f64,
	spin:         f64,
	fov:          f64,
	speed:        f64,
	lanes:        int,
	ui_hidden:    bool,
	autoscroll:   bool,
	fullscreen:   bool,
}

settings_dir: string // "" when $HOME (%USERPROFILE% on Windows) isn't set: nothing is loaded or saved
settings_path: string

pics: [dynamic]Picture
texs: []Tile_Tex
loaded: [dynamic]int // pictures whose texture is Ready
loader: Loader
frame: u64
generation: u64 = 1 // bumped when thumbnails must be redone (lane size or direction changed)
// Lane sizes in physical pixels, rounded up, for both kinds of lane: thumbnails
// are decoded big enough for either, so changing direction doesn't reload them.
thumb_px: i32 // column width
thumb_row_px: i32 // row height

// Direction and angle. Tilt X leans the top of the wall away, tilt Y the right
// side, and spin turns it clockwise within its own plane; all in degrees.
direction: Direction
tilt_x, tilt_y, spin: f64
fov := DEFAULT_FOV
plane: Plane

// Layout
rows := false // images turned a quarter turn in their lanes, so lanes are as tall as the images
lanes_setting := 0 // 0 = auto
lanes: int // across the screen, when flat
side_lanes: int // extra lanes on each side, past the screen's edges
lane_size: f64
lane_origin: f64 // lane-space x of the first lane's edge
heights: [dynamic]f64
block_counts: [dynamic]int // tiles placed in each block, leftmost first
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
	size, radius, caption, fade: c.int,
}
fade_shader: rl.Shader
fade_loc: c.int

angle_open := false // the angle panel; dragging the wall rotates it while it's open
active_slider: u32 // Clay id of the slider being dragged, 0 = none
drag: struct {
	down:        bool, // pressed on the wall (not the UI)
	moved:       bool, // far enough to be a drag rather than a click
	start, last: rl.Vector2,
}

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

	// macOS windows have no icon of their own; there it comes from an app bundle.
	when ODIN_OS != .Darwin {
		icon := rl.LoadImageFromMemory(".png", raw_data(ICON_PNG), c.int(len(ICON_PNG)))
		rl.SetWindowIcon(icon)
		rl.UnloadImage(icon)
	}

	ui_font = rl.LoadFontEx(ODIN_OS == .Windows ? "C:/Windows/Fonts/arial.ttf" : "/System/Library/Fonts/Supplemental/Arial.ttf", 48, nil, 0)
	rl.SetTextureFilter(ui_font.texture, .BILINEAR)

	tile_shader = rl.LoadShaderFromMemory(GRID_VS, TILE_FS)
	tile_locs.size = rl.GetShaderLocation(tile_shader, "size")
	tile_locs.radius = rl.GetShaderLocation(tile_shader, "radius")
	tile_locs.caption = rl.GetShaderLocation(tile_shader, "caption")
	tile_locs.fade = rl.GetShaderLocation(tile_shader, "fadeDepth")
	fade_shader = rl.LoadShaderFromMemory(GRID_VS, FADE_FS)
	fade_loc = rl.GetShaderLocation(fade_shader, "fadeDepth")

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

	layout_rows, layout_tilted := rows, tilted()
	for !rl.WindowShouldClose() && !quit {
		frame += 1
		sync.atomic_store(&loader.frame, frame)
		fullscreen = is_fullscreen() // also entered/left with the green button or ⌃⌘F
		now := rl.GetTime()
		dt := f64(rl.GetFrameTime())
		sw, sh := f64(rl.GetScreenWidth()), f64(rl.GetScreenHeight())

		_, screen_len := screen_extent(sw, sh)
		handle_keys(screen_len)

		// Clay handles the top bar and angle panel while building the layout.
		clay.SetLayoutDimensions({f32(sw), f32(sh)})
		clay.SetPointerState(rl.GetMousePosition(), rl.IsMouseButtonDown(.LEFT))
		commands := build_ui(sw, sh)

		// Keys, buttons and sliders above may have changed the direction or angle.
		rows = int(image_rotation()) % 180 != 0
		across, _ := screen_extent(sw, sh)
		update_plane(sw, sh)
		update_thumb_sizes(sw, sh)
		if tilted() != layout_tilted || rows != layout_rows {
			layout_tilted = tilted()
			for pic in loaded do set_tile_filter(pic)
		}

		// Changing the angle only adds or drops lanes at the sides, which leaves
		// the rest where they were.
		n, size, side := lane_geometry(across)
		if rows != layout_rows || n != lanes || size != lane_size || side != side_lanes {
			relayout(n, size, side)
			layout_rows = rows
		}

		if !lightbox.open {
			wheel := rl.GetMouseWheelMoveV()
			scroll -= f64(rows ? wheel.y + wheel.x : wheel.y) * 40
			// Diagonally, scroll is only the part along the lanes.
			if autoscroll do scroll += speed * dt * (diagonal() ? 1 / math.SQRT_TWO : 1)
		}
		// At the start, the first tiles are just inside the trailing edge of the
		// wall on screen, below the bar when that's the top of a flat one.
		lead := GAP + (direction == .N && !tilted() && !ui_hidden ? BAR_H : 0)
		scroll = max(scroll, -plane.lo.y - lead)

		// Content y range of the part of the wall on screen.
		view_top, view_len := scroll + plane.lo.y, plane.hi.y - plane.lo.y
		extend_layout(view_top + view_len * 4)
		update_textures(view_top, view_len)
		process_results(now)
		evict()

		hovered := handle_pointer(sw, sh)

		rl.BeginDrawing()
		rl.ClearBackground(BG)
		draw_wall(view_top, view_len, hovered, now)
		render_clay(&commands)
		rl.EndDrawing()

		// Not mid-drag, which would write the file every frame.
		adjusting := (drag.moved && angle_open) || active_slider != 0
		if s := current_settings(); s != saved && !adjusting {
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
			direction = .E
		case "-c", "--crawl":
			tilt_x = CRAWL_TILT
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
	home := os.get_env(ODIN_OS == .Windows ? "USERPROFILE" : "HOME", context.temp_allocator)
	if home == "" do return current_settings()
	settings_dir = strings.concatenate({home, "/.scrolld"})
	settings_path = strings.concatenate({settings_dir, "/settings"})

	data, err := os.read_entire_file(settings_path, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist do fmt.eprintfln("scrolld: can't read %s: %v", settings_path, err)
		return current_settings()
	}

	set_angle :: proc(dst: ^f64, s: string, lo, hi: f64) -> bool {
		dst^ = clamp(strconv.parse_f64(s) or_return, lo, hi)
		return true
	}

	// Older versions saved a mode (vertical, sideways or crawl) and which way
	// crawl went; they're turned into a direction and tilt below.
	old_mode, old_toward := "", false

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
		case "direction":
			ok = false
			for name, d in DIRECTION_NAMES {
				if value == name do direction, ok = d, true
			}
		case "tilt_x": ok = set_angle(&tilt_x, value, -MAX_TILT, MAX_TILT)
		case "tilt_y": ok = set_angle(&tilt_y, value, -MAX_TILT, MAX_TILT)
		case "spin":   ok = set_angle(&spin, value, -180, 180)
		case "fov":    ok = set_angle(&fov, value, 15, 100)
		case "mode":
			ok = value == "vertical" || value == "sideways" || value == "crawl"
			if ok do old_mode = value
		case "crawl_toward": ok = set_bool(&old_toward, value)
		case "speed":
			if v, vok := strconv.parse_f64(value); vok do speed = clamp(v, 10, 2000)
			else do ok = false
		case "lanes":
			if v, vok := strconv.parse_int(value, 10); vok do lanes_setting = clamp(v, 0, 12)
			else do ok = false
		case "ui_hidden":  ok = set_bool(&ui_hidden, value)
		case "autoscroll": ok = set_bool(&autoscroll, value)
		case "fullscreen": ok = set_bool(&fullscreen, value)
		case:
			fmt.eprintfln("scrolld: %s:%d: unknown setting %s", settings_path, line_no, key)
			continue
		}
		if !ok do fmt.eprintfln("scrolld: %s:%d: bad value for %s: %s", settings_path, line_no, key, value)
	}

	switch old_mode {
	case "vertical": direction = .N
	case "sideways": direction = .E
	case "crawl":    direction, tilt_x = old_toward ? .S : .N, CRAWL_TILT
	}
	return current_settings()
}

current_settings :: proc() -> Settings {
	return {
		direction = direction,
		tilt_x = tilt_x,
		tilt_y = tilt_y,
		spin = spin,
		fov = fov,
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
	fmt.sbprintln(&b, "# direction: n, ne, e, se, s, sw, w or nw; angles in degrees; lanes: 0 = auto")
	fmt.sbprintfln(&b, "direction = %s", DIRECTION_NAMES[s.direction])
	fmt.sbprintfln(&b, "tilt_x = %.1f", s.tilt_x)
	fmt.sbprintfln(&b, "tilt_y = %.1f", s.tilt_y)
	fmt.sbprintfln(&b, "spin = %.1f", s.spin)
	fmt.sbprintfln(&b, "fov = %.1f", s.fov)
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

lane_count :: proc(cross: f64, as_rows := rows) -> int {
	if lanes_setting > 0 do return lanes_setting
	return max(1, int(cross / (as_rows ? MIN_ROW_H : MIN_COL_W)))
}

diagonal :: proc() -> bool {
	return int(direction) % 2 == 1
}

// Which way lane -y points on screen, in degrees clockwise from up. The
// diagonals keep upright columns, moving up or down, and drift them sideways.
grid_bearing :: proc() -> int {
	b := int(direction) * 45
	if diagonal() do return b < 90 || b > 270 ? 0 : 180
	return b
}

// How far the columns drift across, per unit of scroll along them: right on
// screen for NE and SE, left for NW and SW (lane x points left when they
// move down).
drift :: proc() -> f64 {
	if !diagonal() do return 0
	right := direction == .NE || direction == .SE
	return right == (grid_bearing() == 0) ? 1 : -1
}

// The flat screen's extent across and along the lanes.
screen_extent :: proc(sw, sh: f64) -> (across, along: f64) {
	if grid_bearing() % 180 == 0 do return sw, sh
	return sh, sw
}

// Degrees to turn each image within its lane so it's upright on screen (before
// spin).
image_rotation :: proc() -> f32 {
	return f32((360 - grid_bearing()) % 360)
}

// The lanes across the flat screen (count and size), and how many more each
// side needs to reach the edges of the part of the wall on screen, in whole
// blocks of n.
lane_geometry :: proc(across: f64) -> (n: int, size: f64, side: int) {
	n = lane_count(across)
	size = max((across - GAP * f64(n + 1)) / f64(n), 1)
	reach := max(-plane.lo.x, plane.hi.x) - across / 2
	// Less a hair, so rounding error doesn't add lanes to a flat wall.
	side = clamp(int(math.ceil(reach / (size + GAP) - 0.001)), 0, MAX_SIDE_LANES)
	// Drifting lanes wrap around, which has to happen out of sight.
	if diagonal() do side += 1
	side = (side + n - 1) / n * n
	return
}

// A placement's x in lane space, after drifting: the lanes wrap around, so a
// lane leaving one side comes back in on the other.
tile_x :: proc(p: Placement) -> f64 {
	d := drift()
	if d == 0 do return p.x
	width := f64(len(heights)) * (lane_size + GAP)
	rel := p.x - lane_origin + d * scroll
	return lane_origin + rel - width * math.floor(rel / width)
}

// A placement's rectangle in lane space relative to scroll, where the plane
// is drawn.
tile_rect :: proc(p: Placement) -> rl.Rectangle {
	return {f32(tile_x(p)), f32(p.y - scroll), f32(p.w), f32(p.h)}
}

// The image's size within a tile, which is turned a quarter turn for rows.
image_size :: proc(dst: rl.Rectangle) -> (w, h: f32) {
	return rows ? dst.height : dst.width, rows ? dst.width : dst.height
}

// Width to decode a thumbnail at: the column width, or the width that gives
// the row height, whichever is bigger.
thumb_width :: proc(pic: int) -> i32 {
	return max(thumb_px, row_thumb_width(pic))
}

row_thumb_width :: proc(pic: int) -> i32 {
	p := pics[pic]
	return max(i32(math.ceil(f64(thumb_row_px) * f64(p.width) / f64(p.height))), 1)
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

// The lanes come in blocks of `lanes`: block 0 is the screen's own, and
// blocks ±1, ±2... are added out to the sides as the angle needs them. Each
// block is laid out on its own, from its own run of pictures, so adding or
// dropping blocks never moves the tiles in the others (and their textures
// stay loaded). Placements still come out in y order: the next tile always
// goes into the shortest lane overall, which is also the shortest in its block.
extend_layout :: proc(until_y: f64, min_center := 0) {
	side_blocks := side_lanes / lanes
	for {
		shortest := 0
		for h, i in heights do if h < heights[shortest] do shortest = i
		if block_counts[side_blocks] >= min_center && heights[shortest] >= until_y do return

		bi := shortest / lanes
		block, k := bi - side_blocks, block_counts[bi]
		block_counts[bi] += 1
		pic := pic_for(k)
		// Other blocks show the same run turned around by a different amount.
		if block != 0 {
			pic = (pic + (abs(block) * 2 - (block < 0 ? 1 : 0)) * 7919) % len(pics)
		}
		aspect := f64(pics[pic].height) / f64(pics[pic].width)
		h := lane_size * (rows ? 1 / aspect : aspect)
		x := lane_origin + GAP + f64(shortest) * (lane_size + GAP)
		append(&placements, Placement{pic = pic, block = block, k = k, x = x, y = heights[shortest], w = lane_size, h = h})
		heights[shortest] += h + GAP
		max_tile_h = max(max_tile_h, h)
	}
}

// Rebuilds the layout for a new lane geometry (from lane_geometry) or
// direction, keeping the screen's tile at the leading edge of the view where
// it was. When only the side blocks change, everything stays put.
relayout :: proc(n: int, size: f64, side: int) {
	anchor, anchor_dy := -1, 0.0
	view_top := scroll + plane.lo.y
	for i := first_index(view_top); i < len(placements); i += 1 {
		p := placements[i]
		if p.block == 0 && p.y + p.h > view_top {
			anchor, anchor_dy = p.k, p.y - scroll
			break
		}
	}

	lanes, lane_size, side_lanes = n, size, side
	total := lanes + 2 * side_lanes
	lane_origin = -(f64(total) * (lane_size + GAP) + GAP) / 2
	resize(&heights, total)
	slice.fill(heights[:], 0)
	resize(&block_counts, total / lanes)
	slice.fill(block_counts[:], 0)
	clear(&placements)
	max_tile_h = 0
	perm_pass = -1
	if anchor >= 0 {
		extend_layout(0, anchor + 1)
		for p in placements {
			if p.block == 0 && p.k == anchor {
				scroll = max(p.y - anchor_dy, 0)
				break
			}
		}
	}
}

// Thumbnails are decoded at lane size in physical pixels, rounded up so small
// resizes don't throw them all away.
update_thumb_sizes :: proc(sw, sh: f64) {
	px :: proc(across: f64, as_rows: bool) -> i32 {
		n := lane_count(across, as_rows)
		size := max((across - GAP * f64(n + 1)) / f64(n), 1)
		return i32(math.ceil(size * f64(rl.GetWindowScaleDPI().x) / 128) * 128)
	}
	col, row := px(sw, false), px(sh, true)
	if col != thumb_px || row != thumb_row_px {
		thumb_px, thumb_row_px = col, row
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

// The placement under a point on screen, or -1.
placement_at :: proc(mouse: rl.Vector2) -> int {
	v, ok := screen_to_lane(mouse)
	if !ok do return -1
	across, along := v.x, v.y + scroll
	for i := first_index(along); i < len(placements) && placements[i].y <= along; i += 1 {
		p := placements[i]
		x := tile_x(p)
		if across >= x && across < x + p.w && along >= p.y && along < p.y + p.h do return i
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
// the ones that aren't loaded yet. Only the ones in the part of the wall on
// screen count, or that line up with it to scroll in.
mark_range :: proc(y0, y1: f64, request: bool) {
	for i := first_index(y0); i < len(placements) && placements[i].y < y1; i += 1 {
		p := placements[i]
		if p.y + p.h < y0 || !in_view(p) do continue
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
			set_tile_filter(r.job.pic)
			t.state = .Ready
			t.ready_at = now
			append(&loaded, r.job.pic)
		}
	}
}

// A tilted wall minifies the far tiles heavily, and a thumbnail decoded for
// the other kind of lane can be well over the size it's drawn at; mipmaps and
// anisotropic filtering keep them from shimmering as they move.
set_tile_filter :: proc(pic: int) {
	tex := &texs[pic].tex
	drawn := rows ? row_thumb_width(pic) : thumb_px
	if !tilted() && f64(tex.width) < f64(drawn) * 1.5 {
		rl.SetTextureFilter(tex^, .BILINEAR)
		return
	}
	if tex.mipmaps == 1 do rl.GenTextureMipmaps(tex)
	rl.SetTextureFilter(tex^, .TRILINEAR)
	rl.SetTextureFilter(tex^, .ANISOTROPIC_16X)
}

// Unloads textures that have been out of range for a while, so turning the
// wall back and forth doesn't keep reloading the same ones.
evict :: proc() {
	for i := 0; i < len(loaded); {
		t := &texs[loaded[i]]
		if t.used + EVICT_AFTER_FRAMES < frame {
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

handle_keys :: proc(screen_len: f64) {
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
	if rl.IsKeyPressed(.D) do direction = Direction((int(direction) + 1) % len(Direction))
	if rl.IsKeyPressed(.A) do angle_open = !angle_open
	if rl.IsKeyPressed(.R) do set_angle(0, 0, 0)

	// Down and right go forward whatever the direction.
	if !lightbox.open {
		if pressed(.DOWN, .RIGHT) do scroll += 100
		if pressed(.UP, .LEFT) do scroll -= 100
		if pressed(.PAGE_DOWN) do scroll += screen_len * 0.9
		if pressed(.PAGE_UP) do scroll -= screen_len * 0.9
	}
}

set_angle :: proc(x, y: f64, field_of_view := DEFAULT_FOV) {
	tilt_x, tilt_y, spin, fov = x, y, 0, field_of_view
}

// A press on the wall opens the picture under it if it's released without
// moving; dragging rotates the wall while the angle panel is open. Returns the
// hovered placement, or -1.
handle_pointer :: proc(sw, sh: f64) -> int {
	mouse := rl.GetMousePosition()
	if rl.IsMouseButtonPressed(.LEFT) {
		if lightbox.open do close_lightbox()
		else if !pointer_over_ui() do drag = {down = true, start = mouse, last = mouse}
	}
	if drag.down {
		if rl.IsMouseButtonDown(.LEFT) {
			if rl.Vector2Distance(mouse, drag.start) > 4 do drag.moved = true
			if drag.moved && angle_open && !ui_hidden do rotate_by_drag(drag.last, mouse, sw, sh)
			drag.last = mouse
		} else {
			if !drag.moved {
				if i := placement_at(mouse); i >= 0 do open_lightbox(placements[i].pic)
			}
			drag = {}
		}
	}

	if lightbox.open || drag.moved || pointer_over_ui() do return -1
	return placement_at(mouse)
}

// Like GIMP's 3D transform: the wall turns as if grabbed and pulled. Shift
// keeps to the axis dragged along most, Ctrl (Cmd on macOS) spins it instead.
rotate_by_drag :: proc(prev, cur: rl.Vector2, sw, sh: f64) {
	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) {
		center := rl.Vector2{f32(sw / 2), f32(sh / 2)}
		a0 := math.atan2(f64(prev.y - center.y), f64(prev.x - center.x))
		a1 := math.atan2(f64(cur.y - center.y), f64(cur.x - center.x))
		spin = math.mod(spin + math.to_degrees(a1 - a0) + 540, 360) - 180
		return
	}
	d := cur - prev
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
		total := cur - drag.start
		if abs(total.x) > abs(total.y) do d.y = 0
		else do d.x = 0
	}
	tilt_x = clamp(tilt_x - f64(d.y) * DRAG_DEGREES_PER_PX, -MAX_TILT, MAX_TILT)
	tilt_y = clamp(tilt_y + f64(d.x) * DRAG_DEGREES_PER_PX, -MAX_TILT, MAX_TILT)
}

change_speed :: proc(delta: f64) {
	speed = clamp(speed + delta, 10, 2000)
}

change_lanes :: proc(delta: int) {
	lanes_setting = clamp((lanes_setting == 0 ? lanes : lanes_setting) + delta, 1, 12)
}

// --- Drawing -----------------------------------------------------------------

// Draws the grid onto the plane.
draw_wall :: proc(view_top, view_len: f64, hovered: int, now: f64) {
	rl.BeginMode3D(plane.cam)
	// Everything is coplanar and drawn in order, as in 2D.
	rlgl.DisableDepthTest()
	rlgl.DisableBackfaceCulling()
	a, b, n := plane.a, plane.b, plane.n
	m := [16]f32 {
		f32(a.x), f32(a.y), f32(a.z), 0,
		f32(b.x), f32(b.y), f32(b.z), 0,
		f32(n.x), f32(n.y), f32(n.z), 0,
		0, 0, 0, 1,
	}
	rlgl.PushMatrix()
	rlgl.MultMatrixf(&m[0])
	draw_grid(view_top, view_len, hovered, now)
	rlgl.PopMatrix()
	rlgl.EnableBackfaceCulling()
	rl.EndMode3D()
}

// Draws in lane space relative to scroll (draw_wall puts that on the plane),
// skipping tiles outside the part of the wall on screen.
draw_grid :: proc(view_top, view_len: f64, hovered: int, now: f64) {
	dpi := rl.GetWindowScaleDPI().x
	rot := image_rotation()
	first := first_index(view_top)
	view_bottom := view_top + view_len
	fade := f32(plane.fade_depth)
	rl.SetShaderValue(fade_shader, fade_loc, &fade, .FLOAT)
	rl.SetShaderValue(tile_shader, tile_locs.fade, &fade, .FLOAT)

	// Placeholders first...
	rl.BeginShaderMode(fade_shader)
	for i := first; i < len(placements) && placements[i].y < view_bottom; i += 1 {
		p := placements[i]
		if p.y + p.h < view_top || !in_view(p) do continue
		dst := tile_rect(p)
		// Skip it under fully faded-in images, where it would fringe the antialiased edge.
		t := &texs[p.pic]
		if t.state != .Ready || now - t.ready_at < FADE_IN_SECS {
			rl.DrawRectangleRounded(dst, TILE_RADIUS * 2 / min(dst.width, dst.height), 6, TILE_BG)
		}
	}
	rl.EndShaderMode()

	// ...then the loaded images through the rounding shader, each turned about
	// its center to stand upright.
	rl.BeginShaderMode(tile_shader)
	radius := TILE_RADIUS * dpi
	rl.SetShaderValue(tile_shader, tile_locs.radius, &radius, .FLOAT)
	for i := first; i < len(placements) && placements[i].y < view_bottom; i += 1 {
		p := placements[i]
		t := &texs[p.pic]
		if p.y + p.h < view_top || t.state != .Ready || !in_view(p) do continue
		dst := tile_rect(p)
		w, h := image_size(dst)
		size := [2]f32{w * dpi, h * dpi}
		caption := i == hovered ? CAPTION_H * dpi : 0
		// Uniforms apply to the whole pending batch, so flush before changing them.
		rlgl.DrawRenderBatchActive()
		rl.SetShaderValue(tile_shader, tile_locs.size, &size, .VEC2)
		rl.SetShaderValue(tile_shader, tile_locs.caption, &caption, .FLOAT)
		alpha := f32(clamp((now - t.ready_at) / FADE_IN_SECS, 0, 1))
		src := rl.Rectangle{0, 0, f32(t.tex.width), f32(t.tex.height)}
		centered := rl.Rectangle{dst.x + dst.width / 2, dst.y + dst.height / 2, w, h}
		rl.DrawTexturePro(t.tex, src, centered, {w / 2, h / 2}, rot, rl.Fade(rl.WHITE, alpha))
	}
	rl.EndShaderMode()

	// File name on hover, along the bottom of the image.
	if hovered >= 0 {
		dst := tile_rect(placements[hovered])
		w, h := image_size(dst)
		name := fit_text(pics[placements[hovered].pic].name, 16, w - 20)
		rlgl.PushMatrix()
		rlgl.Translatef(dst.x + dst.width / 2, dst.y + dst.height / 2, 0)
		rlgl.Rotatef(rot, 0, 0, 1)
		rl.DrawTextEx(ui_font, name, {-w / 2 + 10, h / 2 - CAPTION_H + 14}, 16, 0, rl.RAYWHITE)
		rlgl.PopMatrix()
	}
}

// The text, cut short with "..." if needed to fit max_w at the font size.
fit_text :: proc(text: string, size, max_w: f32) -> cstring {
	s := text
	for {
		cut := len(s) < len(text) ? strings.concatenate({s, "..."}, context.temp_allocator) : s
		c := strings.clone_to_cstring(cut, context.temp_allocator)
		if len(s) == 0 || rl.MeasureTextEx(ui_font, c, size, 0).x <= max_w do return c
		_, n := utf8.decode_last_rune_in_string(s)
		s = s[:len(s) - n]
	}
}

// --- Plane -------------------------------------------------------------------
//
// Lane space is mapped onto a plane through the middle of the screen: turned
// within the plane so the content moves in `direction` (lane -y points that
// way), spun, then tilted. The camera sits where the plane exactly fills the
// screen when flat, so a flat wall is drawn 1:1. The wall fades out PLANE_FAR
// behind the screen, which bounds how much of a tilted one is on screen.

tilted :: proc() -> bool {
	return tilt_x != 0 || tilt_y != 0
}

update_plane :: proc(sw, sh: f64) {
	// Spin clockwise, lean the top away, then turn the right side away.
	rotate :: proc(v: [3]f64) -> [3]f64 {
		r := math.to_radians(-spin)
		v := [3]f64{v.x * math.cos(r) - v.y * math.sin(r), v.x * math.sin(r) + v.y * math.cos(r), v.z}
		r = math.to_radians(-tilt_x)
		v = {v.x, v.y * math.cos(r) - v.z * math.sin(r), v.y * math.sin(r) + v.z * math.cos(r)}
		r = math.to_radians(tilt_y)
		return {v.x * math.cos(r) + v.z * math.sin(r), v.y, -v.x * math.sin(r) + v.z * math.cos(r)}
	}

	U :: PLANE_UNIT
	b := math.to_radians(f64(grid_bearing()))
	s, c := math.sin(b), math.cos(b)
	// World y is up, lane (and screen) y is down.
	plane.a = rotate({U * c, -U * s, 0})
	plane.b = rotate({-U * s, -U * c, 0})
	plane.n = rotate({0, 0, U})

	half := math.tan(math.to_radians(fov) / 2)
	dist := sh / 2 / half * U
	plane.cam = {position = {0, 0, f32(dist)}, up = {0, 1, 0}, fovy = f32(fov), projection = .PERSPECTIVE}
	plane.fade_depth = PLANE_FAR * sh * U

	// A square of the plane bigger than any part of it that can be on screen,
	// clipped to the view frustum and the fade-out depth.
	big := 10 * (dist + plane.fade_depth) * (1 + sw / sh) / U
	poly: [16][3]f64
	poly[0] = (plane.a + plane.b) * big
	poly[1] = (-plane.a + plane.b) * big
	poly[2] = (-plane.a - plane.b) * big
	poly[3] = (plane.a - plane.b) * big
	n := 4
	hx, hy := half * sw / sh, half
	// Each keeps k.xyz · p + k.w >= 0.
	keep := [5][4]f64 {
		{1, 0, -hx, dist * hx},
		{-1, 0, -hx, dist * hx},
		{0, 1, -hy, dist * hy},
		{0, -1, -hy, dist * hy},
		{0, 0, 1, plane.fade_depth},
	}
	for k in keep do n = clip_polygon(&poly, n, k)

	// Back into lane space, with the edge normals and the polygon's extent
	// along each, for in_view.
	plane.poly_n = n
	plane.lo, plane.hi = {max(f64), max(f64)}, {min(f64), min(f64)}
	for i in 0 ..< n {
		v := [2]f64{linalg.dot(poly[i], plane.a), linalg.dot(poly[i], plane.b)} / (U * U)
		plane.poly[i] = v
		plane.lo, plane.hi = linalg.min(plane.lo, v), linalg.max(plane.hi, v)
	}
	for i in 0 ..< n {
		e := plane.poly[(i + 1) % n] - plane.poly[i]
		axis := [2]f64{-e.y, e.x}
		plane.axes[i] = axis
		plane.spans[i] = {max(f64), min(f64)}
		for v in plane.poly[:n] {
			d := linalg.dot(axis, v)
			plane.spans[i] = {min(plane.spans[i][0], d), max(plane.spans[i][1], d)}
		}
	}
}

// Sutherland–Hodgman: keeps the part of a convex polygon where k.xyz · p + k.w >= 0.
clip_polygon :: proc(poly: ^[16][3]f64, n: int, k: [4]f64) -> int {
	side :: proc(p: [3]f64, k: [4]f64) -> f64 {return k.x * p.x + k.y * p.y + k.z * p.z + k.w}
	out: [16][3]f64
	m := 0
	for i in 0 ..< n {
		p, q := poly[i], poly[(i + 1) % n]
		fp, fq := side(p, k), side(q, k)
		if fp >= 0 {
			out[m] = p
			m += 1
		}
		if (fp >= 0) != (fq >= 0) {
			out[m] = p + (q - p) * (fp / (fp - fq))
			m += 1
		}
	}
	poly^ = out
	return m
}

// Whether a tile, with a gap's margin, overlaps the part of the wall on
// screen. Tiles ahead of or behind it count if they line up with its nearest
// edge, since that's where they'll scroll in.
in_view :: proc(p: Placement) -> bool {
	// Drifting tiles get a lane's margin, so they're loaded before they drift in.
	margin := drift() != 0 ? lane_size + GAP : GAP
	x := tile_x(p)
	x0, x1 := x - margin, x + p.w + margin
	y0 := clamp(p.y - scroll - GAP, plane.lo.y, plane.hi.y)
	y1 := clamp(p.y - scroll + p.h + GAP, plane.lo.y, plane.hi.y)
	if x1 < plane.lo.x || x0 > plane.hi.x do return false
	// Separating axes: the box's own are covered by the bounds (and the
	// clamp), leaving the polygon's edge normals.
	for i in 0 ..< plane.poly_n {
		axis, span := plane.axes[i], plane.spans[i]
		lo := min(axis.x * x0, axis.x * x1) + min(axis.y * y0, axis.y * y1)
		hi := max(axis.x * x0, axis.x * x1) + max(axis.y * y0, axis.y * y1)
		if hi < span[0] || lo > span[1] do return false
	}
	return true
}

// Where a point on screen lands on the wall, in lane space relative to scroll.
screen_to_lane :: proc(pos: rl.Vector2) -> (v: [2]f64, ok: bool) {
	ray := rl.GetScreenToWorldRay(pos, plane.cam)
	o := [3]f64{f64(ray.position.x), f64(ray.position.y), f64(ray.position.z)}
	d := [3]f64{f64(ray.direction.x), f64(ray.direction.y), f64(ray.direction.z)}
	denom := linalg.dot(d, plane.n)
	if abs(denom) < 1e-12 do return
	t := -linalg.dot(o, plane.n) / denom
	w := o + d * t
	if t <= 0 || w.z < -plane.fade_depth do return
	return [2]f64{linalg.dot(w, plane.a), linalg.dot(w, plane.b)} / (PLANE_UNIT * PLANE_UNIT), true
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

			label("   Direction", 15, MUTED)
			compass()
			if button("angle", "Angle", angle_open) do angle_open = !angle_open

			label(rows ? "   Rows" : "   Columns", 15, MUTED)
			if button("fewer", "-") do change_lanes(-1)
			label(lanes_setting == 0 ? fmt.tprintf("Auto (%d)", lanes) : fmt.tprintf("%d", lanes), 16, TEXT)
			if button("more", "+") do change_lanes(1)
			if lanes_setting != 0 {
				if button("auto", "Auto") do lanes_setting = 0
			}

			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(6)}}}) {}
			if menu_button(.Close) do ui_hidden = true
		}
		if angle_open do angle_panel()
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

// Panel under the top bar for the wall's angle, like the Rotate and Camera
// tabs of GIMP's 3D transform tool.
angle_panel :: proc() {
	row :: proc(id, name: string, value: ^f64, lo, hi: f64) {
		if clay.UI()({layout = {childGap = 12, childAlignment = {y = .Center}}}) {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(90)}}}) {
				label(name, 15, MUTED)
			}
			slider(id, value, lo, hi)
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(36)}, childAlignment = {x = .Right}}}) {
				label(fmt.tprintf("%d", int(math.round(value^))), 15, TEXT)
			}
		}
	}

	if clay.UI()({
		id = clay.ID("anglepanel"),
		floating = {attachTo = .Root, attachment = {element = .RightTop, parent = .RightTop}, offset = {-16, BAR_H + 8}, zIndex = 5},
		layout = {layoutDirection = .TopToBottom, padding = {16, 16, 14, 14}, childGap = 10},
		backgroundColor = PANEL,
		cornerRadius = clay.CornerRadiusAll(10),
	}) {
		row("tiltx", "Tilt back", &tilt_x, -MAX_TILT, MAX_TILT)
		row("tilty", "Turn", &tilt_y, -MAX_TILT, MAX_TILT)
		row("spin", "Spin", &spin, -180, 180)
		row("fov", "Perspective", &fov, 15, 100)
		if clay.UI()({layout = {childGap = 8, childAlignment = {y = .Center}}}) {
			if button("flat", "Flat") do set_angle(0, 0)
			if button("crawl", "Crawl") do set_angle(CRAWL_TILT, 0)
		}
		label("Drag the wall to rotate it.", 13, MUTED)
		label("Shift: one axis.  Ctrl or Cmd: spin.", 13, MUTED)
	}
}

// Drags (or jumps, when clicked) to the pointer's position along the track,
// even once the pointer leaves it.
slider :: proc(id: string, value: ^f64, lo, hi: f64) {
	cid := clay.ID(id)
	if clay.UI()({
		id = cid,
		layout = {sizing = {clay.SizingFixed(170), clay.SizingFixed(18)}},
		custom = {customData = new_clone(Custom(Slider_Fill((value^ - lo) / (hi - lo))), context.temp_allocator)},
	}) {
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do active_slider = cid.id
	}
	if active_slider != cid.id do return
	if !rl.IsMouseButtonDown(.LEFT) {
		active_slider = 0
		return
	}
	b := clay.GetElementData(cid).boundingBox
	frac := clamp((f64(rl.GetMouseX()) - f64(b.x)) / f64(b.width), 0, 1)
	value^ = lo + frac * (hi - lo)
}

// A 3x3 grid of arrows, one for each direction around an empty middle.
compass :: proc() {
	COMPASS :: [3][3]Maybe(Direction){{.NW, .N, .NE}, {.W, nil, .E}, {.SW, .S, .SE}}
	if clay.UI()({layout = {layoutDirection = .TopToBottom, childGap = 2}}) {
		for line in COMPASS {
			if clay.UI()({layout = {childGap = 2}}) {
				for cell in line {
					d, ok := cell.?
					if !ok {
						if clay.UI()({layout = {sizing = {clay.SizingFixed(20), clay.SizingFixed(14)}}}) {}
						continue
					}
					if clay.UI()({
						id = clay.ID("dir", u32(d)),
						layout = {sizing = {clay.SizingFixed(20), clay.SizingFixed(14)}, childAlignment = {.Center, .Center}},
						backgroundColor = d == direction ? ACCENT : clay.Hovered() ? BUTTON_HOVER : BUTTON,
						cornerRadius = clay.CornerRadiusAll(3),
					}) {
						if clay.UI()({
							layout = {sizing = {clay.SizingFixed(10), clay.SizingFixed(10)}},
							custom = {customData = new_clone(Custom(d), context.temp_allocator)},
						}) {}
						if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do direction = d
					}
				}
			}
		}
	}
}

Icon :: enum {
	Menu,
	Close,
}

Slider_Fill :: distinct f64 // 0 to 1

// What render_clay draws for a Clay custom element (Clay can't draw diagonals
// or circles): an icon, a direction's arrow, or a slider.
Custom :: union {
	Icon,
	Direction,
	Slider_Fill,
}

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
			custom = {customData = new_clone(Custom(icon), context.temp_allocator)},
		}) {}
		clicked = clay.Hovered() && rl.IsMouseButtonPressed(.LEFT)
	}
	return
}

draw_custom :: proc(custom: Custom, b: clay.BoundingBox, color: rl.Color) {
	switch v in custom {
	case Icon:
		draw_icon(v, b, color)
	case Direction:
		// A shaft through the middle, and a head at the end it points to.
		r := math.to_radians(f32(v) * 45)
		u := rl.Vector2{math.sin(r), -math.cos(r)} * min(b.width, b.height) / 2
		c := rl.Vector2{b.x + b.width / 2, b.y + b.height / 2}
		tip := c + u
		rl.DrawLineEx(c - u, tip, 1.5, color)
		rl.DrawLineEx(tip, tip - rl.Vector2Rotate(u, 0.6) * 0.7, 1.5, color)
		rl.DrawLineEx(tip, tip - rl.Vector2Rotate(u, -0.6) * 0.7, 1.5, color)
	case Slider_Fill:
		x := b.x + b.width * f32(v)
		y := b.y + b.height / 2
		rl.DrawRectangleRounded({b.x, y - 2, b.width, 4}, 1, 4, {56, 56, 68, 255})
		rl.DrawRectangleRounded({b.x, y - 2, x - b.x, 4}, 1, 4, {79, 140, 255, 255})
		rl.DrawCircleV({x, y}, 7, color)
	}
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
	if angle_open && clay.PointerOver(clay.ID("anglepanel")) do return true
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
			draw_custom((^Custom)(cmd.renderData.custom.customData)^, b, to_rl(TEXT))
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
