#+build !js
package main

// The desktop build: a window, images from a directory decoded on worker
// threads, and settings in ~/.scrolld/settings. web.odin is the browser's.

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"
import stbi "vendor:stb/image"

// Requires Homebrew's raylib, webp, libheif and jpeg-turbo packages on macOS. On Windows,
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
WEBP_MODE_RGBA :: 1

WebP_Features :: struct {
	width, height, has_alpha, has_animation, format: c.int,
	pad:                                             [5]u32,
}

// WebPDecBuffer, with only the RGBA view of its union.
WebP_Dec_Buffer :: struct {
	colorspace, width, height, is_external_memory: c.int,
	rgba:                                          [^]u8,
	stride:                                        c.int,
	size:                                          c.size_t,
	yuva_rest:                                     [56]u8, // the union's YUVA view is bigger
	pad:                                           [4]u32,
	private_memory:                                rawptr,
}

WebP_Decoder_Options :: struct {
	bypass_filtering, no_fancy_upsampling, use_cropping: c.int,
	crop_left, crop_top, crop_width, crop_height:        c.int,
	use_scaling, scaled_width, scaled_height:            c.int,
	use_threads, dithering_strength, flip:               c.int,
	alpha_dithering_strength:                            c.int,
	pad:                                                 [5]u32,
}

WebP_Decoder_Config :: struct {
	input:   WebP_Features,
	output:  WebP_Dec_Buffer,
	options: WebP_Decoder_Options,
}
#assert(size_of(WebP_Decoder_Config) == 240 && offset_of(WebP_Decoder_Config, options) == 160)

@(default_calling_convention = "c")
foreign webp {
	WebPGetFeaturesInternal :: proc(data: [^]u8, size: c.size_t, features: ^WebP_Features, version: c.int) -> c.int ---
	WebPInitDecoderConfigInternal :: proc(config: ^WebP_Decoder_Config, version: c.int) -> c.int ---
	WebPDecode :: proc(data: [^]u8, size: c.size_t, config: ^WebP_Decoder_Config) -> c.int ---
}

// JPEGs are decoded with libjpeg-turbo, which can scale them down by up to 8x
// while decoding, far faster than decoding them whole. It isn't set up on
// Windows yet, so stb_image decodes them there.
TURBOJPEG :: ODIN_OS != .Windows

when TURBOJPEG {
	@(extra_linker_flags = "-L/opt/homebrew/opt/jpeg-turbo/lib")
	foreign import turbojpeg "system:turbojpeg"

	TJINIT_DECOMPRESS :: 1
	TJPARAM_JPEGWIDTH :: 5
	TJPARAM_JPEGHEIGHT :: 6
	TJPF_RGB :: 0
	TJERR_WARNING :: 0

	Tj_Scaling_Factor :: struct {
		num, denom: c.int,
	}

	@(default_calling_convention = "c")
	foreign turbojpeg {
		tj3Init :: proc(init_type: c.int) -> rawptr ---
		tj3Destroy :: proc(handle: rawptr) ---
		tj3Get :: proc(handle: rawptr, param: c.int) -> c.int ---
		tj3GetErrorCode :: proc(handle: rawptr) -> c.int ---
		tj3DecompressHeader :: proc(handle: rawptr, jpeg: [^]u8, size: c.size_t) -> c.int ---
		tj3GetScalingFactors :: proc(count: ^c.int) -> [^]Tj_Scaling_Factor ---
		tj3SetScalingFactor :: proc(handle: rawptr, factor: Tj_Scaling_Factor) -> c.int ---
		tj3Decompress8 :: proc(handle: rawptr, jpeg: [^]u8, size: c.size_t, dst: [^]u8, pitch, pixel_format: c.int) -> c.int ---
	}
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

ICON_PNG :: #load("icon.png") // icon.svg rendered at 256 px

IMAGE_EXTS :=[?]string{".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif"}

WORKERS :: 4

// Decoded by a worker, uploaded by process_results.
Decoded :: rl.Image

UI_FONT :: "C:/Windows/Fonts/arial.ttf" when ODIN_OS == .Windows else "/System/Library/Fonts/Supplemental/Arial.ttf"

Loader :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	jobs:    [dynamic]Job,
	results: [dynamic]Result,
	quit:    bool,
	frame:   u64, // atomic
	wanted:  []u64, // atomic, per picture: last frame it was in range
}

loader: Loader

settings_dir: string // "" when $HOME (%USERPROFILE% on Windows) isn't set: nothing is loaded or saved
settings_path: string

main :: proc() {
	// Flags override the saved settings, and get saved along with them.
	saved_settings = load_settings()
	parse_args()
	heif_init(nil)
	scan()
	if len(pics) == 0 {
		fmt.eprintfln("scrolld: no images found in %s%s", opts.dir, opts.recursive ? "" : " (try --recursive)")
		os.exit(1)
	}
	loader.wanted = make([]u64, len(pics))

	init()
	defer rl.CloseWindow()

	// macOS windows have no icon of their own; there it comes from an app bundle.
	when ODIN_OS != .Darwin {
		icon := rl.LoadImageFromMemory(".png", raw_data(ICON_PNG), c.int(len(ICON_PNG)))
		rl.SetWindowIcon(icon)
		rl.UnloadImage(icon)
	}

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

	for !rl.WindowShouldClose() && !quit do update_frame()
}

parse_args :: proc() {
	for arg in os.args[1:] {
		if apply_flag(arg) do continue
		switch arg {
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

// Loads ~/.scrolld/settings (see parse_settings), returning what was loaded so
// update_frame can tell when something changes.
load_settings :: proc() -> Settings {
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
	parse_settings(string(data), settings_path)
	return current_settings()
}

// Writes to a temp file and renames it over the old one, so a crash mid-write
// can't leave a truncated file.
save_settings :: proc(s: Settings) {
	if settings_dir == "" do return
	tmp := strings.concatenate({settings_path, ".tmp"}, context.temp_allocator)
	err := os.make_directory(settings_dir)
	if err == .Exist do err = nil
	if err == nil do err = os.write_entire_file(tmp, format_settings(s))
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
		case ".jpg", ".jpeg":  if TURBOJPEG do format = .Jpeg
		case ".webp":          format = .Webp
		case ".heic", ".heif": format = .Heif
		}
		w, h, comp: c.int
		ok: bool
		switch format {
		case .Stb, .Jpeg: ok = stbi.info(path, &w, &h, &comp) != 0
		case .Webp:       ok = webp_info(info.fullpath, webp_header, &w, &h)
		case .Heif:       ok = heif_info(path, &w, &h)
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
			// The JPEG, WebP and HEIF decoders shrink to about target_w themselves.
			switch pic.format {
			case .Stb:  res.image = load_image(pic.path)
			case .Jpeg: when TURBOJPEG do res.image = load_jpeg(pic.path, job.target_w)
			case .Webp: res.image = load_webp(string(pic.path), job.target_w)
			case .Heif: res.image = load_heif(pic.path, job.target_w)
			}
			if res.image.data == nil {
				res.status = .Failed
			} else if res.image.width > job.target_w {
				w, h := shrunk(res.image.width, res.image.height, job.target_w)
				rl.ImageResize(&res.image, w, h)
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

when TURBOJPEG {
	// Decodes at the smallest scale libjpeg-turbo offers that's at least
	// target_w wide, leaving the rest to the worker's resize. JPEGs it can't
	// decode (CMYK, 12-bit...) go to stb_image.
	load_jpeg :: proc(path: cstring, target_w: i32) -> rl.Image {
		scaled :: proc(dim: c.int, f: Tj_Scaling_Factor) -> c.int {return (dim * f.num + f.denom - 1) / f.denom}

		data, err := os.read_entire_file(string(path), context.allocator)
		if err != nil do return {}
		defer delete(data)
		tj := tj3Init(TJINIT_DECOMPRESS)
		if tj == nil do return load_image(path)
		defer tj3Destroy(tj)
		if tj3DecompressHeader(tj, raw_data(data), c.size_t(len(data))) != 0 do return load_image(path)
		jw, jh := tj3Get(tj, TJPARAM_JPEGWIDTH), tj3Get(tj, TJPARAM_JPEGHEIGHT)

		n: c.int
		factors := tj3GetScalingFactors(&n)
		best := Tj_Scaling_Factor{1, 1}
		for f in factors[:n] {
			sw := scaled(jw, f)
			if f.num < f.denom && sw >= target_w && sw < scaled(jw, best) do best = f
		}
		if tj3SetScalingFactor(tj, best) != 0 do return load_image(path)

		w, h := scaled(jw, best), scaled(jh, best)
		pixels := ([^]u8)(libc.malloc(c.size_t(w) * c.size_t(h) * 3))
		if pixels == nil do return {}
		// A warning means it's damaged but decoded what it could, as stb_image does.
		if tj3Decompress8(tj, raw_data(data), c.size_t(len(data)), pixels, 0, TJPF_RGB) != 0 && tj3GetErrorCode(tj) != TJERR_WARNING {
			libc.free(pixels)
			return load_image(path)
		}
		return {data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8}
	}
}

// Decodes straight to target_w wide when that's smaller, into a malloc'd
// buffer raylib can free.
load_webp :: proc(path: string, target_w: i32) -> rl.Image {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}
	defer delete(data)
	config: WebP_Decoder_Config
	if WebPInitDecoderConfigInternal(&config, WEBP_DECODER_ABI_VERSION) == 0 do return {}
	if WebPGetFeaturesInternal(raw_data(data), c.size_t(len(data)), &config.input, WEBP_DECODER_ABI_VERSION) != 0 do return {}

	w, h := shrunk(config.input.width, config.input.height, target_w)
	if w != config.input.width {
		config.options.use_scaling, config.options.scaled_width, config.options.scaled_height = 1, w, h
	}
	row := c.size_t(w) * 4
	pixels := ([^]u8)(libc.malloc(row * c.size_t(h)))
	if pixels == nil do return {}
	config.output.colorspace = WEBP_MODE_RGBA
	config.output.is_external_memory = 1
	config.output.rgba, config.output.stride, config.output.size = pixels, c.int(row), row * c.size_t(h)
	if WebPDecode(raw_data(data), c.size_t(len(data)), &config) != 0 {
		libc.free(pixels)
		return {}
	}
	return {data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

// libheif owns its pixels, so they're copied (dropping any row padding) into a
// malloc'd buffer raylib can free, shrunk to target_w on the way when they're
// wider, so there's never a second full-size copy.
load_heif :: proc(path: cstring, target_w: i32) -> rl.Image {
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
	ow, oh := shrunk(w, h, target_w)
	pixels := ([^]u8)(libc.malloc(c.size_t(ow) * c.size_t(oh) * 4))
	if pixels == nil do return {}
	if ow == w {
		for y in 0 ..< c.size_t(h) {
			libc.memcpy(pixels[y * row:], src[y * stride:], row)
		}
	} else if stbi.resize_uint8(src, w, h, c.int(stride), pixels, ow, oh, 0, 4) == 0 {
		libc.free(pixels)
		return {}
	}
	return {data = pixels, width = ow, height = oh, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

enqueue :: proc(job: Job, front := false) {
	sync.mutex_lock(&loader.mutex)
	if front do inject_at(&loader.jobs, 0, job)
	else do append(&loader.jobs, job)
	sync.mutex_unlock(&loader.mutex)
	sync.cond_signal(&loader.cond)
}

loader_begin_frame :: proc() {
	sync.atomic_store(&loader.frame, frame)
}

// Marks a picture as wanted this frame, so workers don't skip it.
want :: proc(pic: int) {
	sync.atomic_store(&loader.wanted[pic], frame)
}

next_result :: proc() -> (r: Result, ok: bool) {
	sync.mutex_lock(&loader.mutex)
	defer sync.mutex_unlock(&loader.mutex)
	if len(loader.results) == 0 do return
	return pop_front(&loader.results), true
}

upload :: proc(img: Decoded) -> rl.Texture2D {
	return rl.LoadTextureFromImage(img)
}

release :: proc(img: Decoded) {
	rl.UnloadImage(img)
}

// Drops the thumbnails still waiting for a worker, leaving the lightbox's.
drop_queued_thumbnails :: proc() {
	sync.mutex_lock(&loader.mutex)
	for len(loader.jobs) > 0 && !loader.jobs[len(loader.jobs) - 1].lightbox do pop(&loader.jobs)
	sync.mutex_unlock(&loader.mutex)
}
