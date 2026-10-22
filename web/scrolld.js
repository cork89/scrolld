// Starts scrolld.wasm with raylib.js, and provides web.odin's "scrolld"
// imports: the image list, loading images, settings and flags.
'use strict';

(async () => {
	const canvas = document.getElementById('scrolld');
	const mem = new odin.WasmMemoryInterface();
	let rl;
	try {
		rl = new Raylib(canvas, mem);
	} catch (e) {
		document.body.textContent = `scrolld needs WebGL 2: ${e.message}`;
		return;
	}

	const manifest = await fetch('images/manifest.txt').then(r => r.ok ? r.text() : '', () => '');
	const encoder = new TextEncoder();

	// Returns the text's length in bytes, copying it in when it fits; -1 for none.
	const text = (s, ptr, len) => {
		if (s == null) return -1;
		const bytes = encoder.encode(s);
		if (bytes.length <= len) mem.loadBytes(ptr, bytes.length).set(bytes);
		return bytes.length;
	};
	const storage = {
		get: () => { try { return localStorage.getItem('scrolld.settings'); } catch { return null; } },
		set: s => { try { localStorage.setItem('scrolld.settings', s); } catch {} },
	};

	// Decoded images wait in `bitmaps` until they're uploaded or released, and
	// their results in `done` until js_poll.
	const bitmaps = new Map();
	let nextBitmap = 1;
	const done = [];

	const scrolld = {
		js_manifest: (ptr, len) => text(manifest, ptr, len),
		// ?shuffle&crawl&sideways, as the desktop's --shuffle --crawl --sideways.
		js_args: (ptr, len) => text([...new URLSearchParams(location.search).keys()].map(k => '--' + k).join('\n'), ptr, len),
		js_settings: (ptr, len) => text(storage.get(), ptr, len),
		js_save_settings: (ptr, len) => storage.set(mem.loadString(ptr, len)),

		js_load: (id, namePtr, nameLen, w, h) => {
			const name = mem.loadString(namePtr, nameLen);
			const url = 'images/' + name.split('/').map(encodeURIComponent).join('/');
			fetch(url)
				.then(r => {
					if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
					return r.blob();
				})
				// Shrunk by the browser, off the main thread.
				.then(blob => createImageBitmap(blob, { resizeWidth: w, resizeHeight: h, resizeQuality: 'high', premultiplyAlpha: 'none' }))
				.then(bitmap => {
					const handle = nextBitmap++;
					bitmaps.set(handle, bitmap);
					done.push([id, 1, handle, bitmap.width, bitmap.height]);
				})
				.catch(e => {
					console.warn(`scrolld: can't load ${name}: ${e.message}`);
					done.push([id, 0, 0, 0, 0]);
				});
		},
		// Web_Result: id, ok, then Decoded's bitmap, width and height.
		js_poll: ptr => {
			const r = done.shift();
			if (!r) return 0;
			r.forEach((v, i) => mem.storeI32(ptr + i * 4, v));
			return 1;
		},
		js_upload: (handle, texPtr) => {
			const bitmap = bitmaps.get(handle);
			bitmaps.delete(handle);
			rl.loadTexture(bitmap, texPtr);
			bitmap.close();
		},
		js_release: handle => {
			bitmaps.get(handle)?.close();
			bitmaps.delete(handle);
		},
	};

	await odin.runWasm('scrolld.wasm', null, { ...rl.imports, scrolld }, mem);
})();
