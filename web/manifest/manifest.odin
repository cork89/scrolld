// Copies the images in a directory (not its subdirectories) into the web
// build's images directory, with the manifest.txt that web.odin's scan reads:
// a `name<TAB>width<TAB>height` line for each.
//
//   odin run web/manifest -- <dir> bin/web/images
package manifest

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import stbi "vendor:stb/image"

// The formats both stb_image (for the size) and browsers (to decode) read.
EXTS := [?]string{".jpg", ".jpeg", ".png", ".gif", ".bmp"}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: manifest <dir> <out dir>")
		os.exit(2)
	}
	src, out := os.args[1], os.args[2]
	files, read_err := os.read_all_directory_by_path(src, context.allocator)
	if read_err != nil {
		fmt.eprintfln("manifest: can't read %s: %v", src, read_err)
		os.exit(1)
	}
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	// Starts afresh, so images removed from dir don't linger.
	os.remove_all(out)
	if err := os.make_directory_all(out); err != nil {
		fmt.eprintfln("manifest: can't create %s: %v", out, err)
		os.exit(1)
	}

	b := strings.builder_make()
	n := 0
	for f in files {
		ext := strings.to_lower(os.ext(f.name), context.temp_allocator)
		if f.type != .Regular || strings.has_prefix(f.name, ".") || !slice.contains(EXTS[:], ext) do continue
		w, h, comp: i32
		if stbi.info(strings.clone_to_cstring(f.fullpath, context.temp_allocator), &w, &h, &comp) == 0 {
			fmt.eprintfln("manifest: skipping %s: %s", f.name, stbi.failure_reason())
			continue
		}
		dst := strings.concatenate({out, "/", f.name}, context.temp_allocator)
		if err := os.copy_file(dst, f.fullpath); err != nil {
			fmt.eprintfln("manifest: can't copy %s: %v", f.name, err)
			continue
		}
		fmt.sbprintfln(&b, "%s\t%d\t%d", f.name, w, h)
		n += 1
		free_all(context.temp_allocator)
	}

	manifest := strings.concatenate({out, "/manifest.txt"})
	if err := os.write_entire_file(manifest, strings.to_string(b)); err != nil {
		fmt.eprintfln("manifest: can't write %s: %v", manifest, err)
		os.exit(1)
	}
	fmt.printfln("manifest: %d images in %s", n, out)
}
