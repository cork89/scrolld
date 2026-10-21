// Writes a Windows .res file holding one icon made of the given PNGs, for
// `odin build -resource:`. windows/scrolld.res was made from icon.svg rendered
// at 16, 24, 32, 48, 64, 128 and 256 px:
//
//     odin run windows/make_res.odin -file -- windows/scrolld.res 16.png 24.png ... 256.png
//
// Each PNG goes in as-is (Windows reads PNG icon images), so no resource
// compiler is needed.
package make_res

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"

RT_ICON :: 3
RT_GROUP_ICON :: 14

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: make_res out.res image.png...")
		os.exit(2)
	}

	b: bytes.Buffer
	// A .res file starts with an empty entry.
	write_entry(&b, 0, 0, 0, nil)

	group: bytes.Buffer
	put16(&group, 0) // reserved
	put16(&group, 1) // type: icon
	put16(&group, u16(len(os.args) - 2))

	for path, i in os.args[2:] {
		png, err := os.read_entire_file(path, context.allocator)
		if err != nil || len(png) < 24 || string(png[1:4]) != "PNG" {
			fmt.eprintln("make_res: not a PNG:", path)
			os.exit(1)
		}
		w, _ := endian.get_u32(png[16:20], .Big)
		h, _ := endian.get_u32(png[20:24], .Big)
		id := u16(i + 1)
		write_entry(&b, RT_ICON, id, 0x1010, png)

		// 256 is stored as 0.
		bytes.buffer_write_byte(&group, u8(w & 0xff))
		bytes.buffer_write_byte(&group, u8(h & 0xff))
		bytes.buffer_write_byte(&group, 0) // palette colors
		bytes.buffer_write_byte(&group, 0) // reserved
		put16(&group, 1) // planes
		put16(&group, 32) // bits per pixel
		put32(&group, u32(len(png)))
		put16(&group, id)
	}
	write_entry(&b, RT_GROUP_ICON, 1, 0x1030, bytes.buffer_to_bytes(&group))

	if err := os.write_entire_file(os.args[1], bytes.buffer_to_bytes(&b)); err != nil {
		fmt.eprintln("make_res: can't write", os.args[1])
		os.exit(1)
	}
}

// A resource header with numeric type and name, then the data padded to 4 bytes.
write_entry :: proc(b: ^bytes.Buffer, type, name: u16, flags: u16, data: []u8) {
	put32(b, u32(len(data)))
	put32(b, 32) // header size
	put16(b, 0xffff)
	put16(b, type)
	put16(b, 0xffff)
	put16(b, name)
	put32(b, 0) // data version
	put16(b, flags)
	put16(b, type == 0 ? 0 : 0x0409) // language: en-US, as rc uses (the empty entry is all zeros)
	put32(b, 0) // version
	put32(b, 0) // characteristics
	bytes.buffer_write(b, data)
	for bytes.buffer_length(b) % 4 != 0 do bytes.buffer_write_byte(b, 0)
}

put16 :: proc(b: ^bytes.Buffer, v: u16) {
	buf: [2]u8
	endian.put_u16(buf[:], .Little, v)
	bytes.buffer_write(b, buf[:])
}

put32 :: proc(b: ^bytes.Buffer, v: u32) {
	buf: [4]u8
	endian.put_u32(buf[:], .Little, v)
	bytes.buffer_write(b, buf[:])
}
