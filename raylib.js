// raylib.js: the part of raylib that scrolld calls, on WebGL 2, as the wasm
// module's "raylib" imports. web.odin is built with
// -define:RAYLIB_WASM_LIB=raylib, which turns vendor:raylib's foreign blocks
// into imports from this module, so no C raylib (or Emscripten) is involved.
//
// What shows on screen follows raylib 6's own code: rlgl's batch, matrix
// stack and depth stepping, and the shapes, text and texture functions built
// on them. Odin passes structs by pointer and returns them through a pointer
// passed first, so most of these read and write wasm memory.
'use strict';

const MAX_VERTICES = 1 << 16;
const VERTEX_BYTES = 24; // position xyz, texcoord uv (f32s), color rgba (u8s)
const SMOOTH_CIRCLE_ERROR_RATE = 0.5;
const TEXT_LINE_SPACING = 2;
const CULL_NEAR = 0.01, CULL_FAR = 1000;
const FLAG_BORDERLESS_WINDOWED_MODE = 0x8000;

// KeyboardEvent.code to raylib's KeyboardKey, which are GLFW's (US layout).
const KEYS = {
	Space: 32, Quote: 39, Comma: 44, Minus: 45, Period: 46, Slash: 47, Semicolon: 59, Equal: 61,
	BracketLeft: 91, Backslash: 92, BracketRight: 93, Backquote: 96,
	Escape: 256, Enter: 257, Tab: 258, Backspace: 259, Insert: 260, Delete: 261,
	ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264, ArrowUp: 265, PageUp: 266, PageDown: 267, Home: 268, End: 269,
	NumpadDecimal: 330, NumpadDivide: 331, NumpadMultiply: 332, NumpadSubtract: 333, NumpadAdd: 334, NumpadEnter: 335, NumpadEqual: 336,
	ShiftLeft: 340, ControlLeft: 341, AltLeft: 342, MetaLeft: 343, ShiftRight: 344, ControlRight: 345, AltRight: 346, MetaRight: 347,
};
for (let i = 0; i < 26; i++) KEYS['Key' + String.fromCharCode(65 + i)] = 65 + i;
for (let i = 0; i < 10; i++) KEYS['Digit' + i] = 48 + i, KEYS['Numpad' + i] = 320 + i;
for (let i = 1; i <= 12; i++) KEYS['F' + i] = 289 + i;

const MOUSE_BUTTONS = [0, 2, 1]; // MouseEvent.button to raylib's: left, middle, right -> 0, 2, 1

const DEFAULT_VS = `#version 300 es
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
uniform mat4 mvp;
out vec2 fragTexCoord;
out vec4 fragColor;
void main() {
	fragTexCoord = vertexTexCoord;
	fragColor = vertexColor;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}`;

const DEFAULT_FS = `#version 300 es
precision mediump float;
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
out vec4 finalColor;
void main() {
	finalColor = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
}`;

// 4x4 matrices are column-major arrays, as in GL. mul(a, b) applies b first.
const mat = {
	identity: () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
	mul(a, b) {
		const r = new Array(16);
		for (let c = 0; c < 4; c++) {
			for (let i = 0; i < 4; i++) {
				r[c * 4 + i] = a[i] * b[c * 4] + a[4 + i] * b[c * 4 + 1] + a[8 + i] * b[c * 4 + 2] + a[12 + i] * b[c * 4 + 3];
			}
		}
		return r;
	},
	ortho: (l, r, b, t, n, f) => [2 / (r - l), 0, 0, 0, 0, 2 / (t - b), 0, 0, 0, 0, -2 / (f - n), 0, -(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n), 1],
	frustum: (l, r, b, t, n, f) => [2 * n / (r - l), 0, 0, 0, 0, 2 * n / (t - b), 0, 0, (r + l) / (r - l), (t + b) / (t - b), -(f + n) / (f - n), -1, 0, 0, -2 * f * n / (f - n), 0],
	translate: (x, y, z) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1],
	rotate(deg, x, y, z) {
		const len = Math.hypot(x, y, z) || 1;
		x /= len, y /= len, z /= len;
		const a = deg * Math.PI / 180, c = Math.cos(a), s = Math.sin(a), t = 1 - c;
		return [
			x * x * t + c, y * x * t + z * s, z * x * t - y * s, 0,
			x * y * t - z * s, y * y * t + c, z * y * t + x * s, 0,
			x * z * t + y * s, y * z * t - x * s, z * z * t + c, 0,
			0, 0, 0, 1,
		];
	},
	lookAt(eye, target, up) {
		const vz = vec3.norm(vec3.sub(eye, target)), vx = vec3.norm(vec3.cross(up, vz)), vy = vec3.cross(vz, vx);
		return [vx[0], vy[0], vz[0], 0, vx[1], vy[1], vz[1], 0, vx[2], vy[2], vz[2], 0, -vec3.dot(vx, eye), -vec3.dot(vy, eye), -vec3.dot(vz, eye), 1];
	},
};

const vec3 = {
	sub: (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]],
	dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
	cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
	norm(a) {
		const l = Math.hypot(a[0], a[1], a[2]) || 1;
		return [a[0] / l, a[1] / l, a[2] / l];
	},
};

class Raylib {
	constructor(canvas, wmi) {
		this.canvas = canvas;
		this.wmi = wmi; // odin.js's WasmMemoryInterface
		const gl = canvas.getContext('webgl2', { alpha: false, antialias: true, premultipliedAlpha: false });
		if (!gl) throw new Error('WebGL 2 is not available');
		this.gl = gl;
		this.aniso = gl.getExtension('EXT_texture_filter_anisotropic');
		this.maxAniso = this.aniso ? gl.getParameter(this.aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT) : 0;
		this.decoder = new TextDecoder();

		// The batch: one vertex buffer, split into draws by texture.
		this.vertexData = new ArrayBuffer(MAX_VERTICES * VERTEX_BYTES);
		this.vf32 = new Float32Array(this.vertexData);
		this.vu8 = new Uint8Array(this.vertexData);
		this.count = 0;
		this.draws = []; // {tex, start}
		this.depth = -1; // rlgl's currentDepth: each shape is drawn a hair in front of the last
		this.vbo = gl.createBuffer();
		gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
		gl.bufferData(gl.ARRAY_BUFFER, this.vertexData.byteLength, gl.DYNAMIC_DRAW);
		this.vao = gl.createVertexArray();
		gl.bindVertexArray(this.vao);
		gl.enableVertexAttribArray(0);
		gl.vertexAttribPointer(0, 3, gl.FLOAT, false, VERTEX_BYTES, 0);
		gl.enableVertexAttribArray(1);
		gl.vertexAttribPointer(1, 2, gl.FLOAT, false, VERTEX_BYTES, 12);
		gl.enableVertexAttribArray(2);
		gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, true, VERTEX_BYTES, 20);

		// Textures and shaders by raylib id. Shapes are drawn with a 1x1 white texture.
		this.textures = new Map();
		this.nextTexture = 1;
		this.white = this.createTexture(1, 1, new Uint8Array([255, 255, 255, 255]));
		this.shaders = new Map();
		this.nextShader = 1;
		this.defaultShader = this.compileShader(DEFAULT_VS, DEFAULT_FS);
		this.shader = this.defaultShader;
		this.fonts = new Map(); // by texture id

		// rlgl's matrices. While pushed, shapes are transformed on the CPU.
		this.projection = mat.identity();
		this.modelview = mat.identity();
		this.transform = mat.identity();
		this.current = this.modelview;
		this.transformRequired = false;
		this.stack = [];

		gl.enable(gl.BLEND);
		gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

		// Window and input.
		this.sized = false; // canvas size checked this frame
		this.screenW = this.screenH = 1;
		this.dpr = 1;
		this.start = performance.now();
		this.lastFrame = this.start;
		this.frameTime = 0;
		this.keysDown = new Set();
		this.keysPressed = new Set();
		this.keysRepeated = new Set();
		this.keysReleased = new Set();
		this.mouse = [0, 0];
		this.buttonsDown = [false, false, false];
		this.buttonsPressed = [false, false, false];
		this.wheel = [0, 0];
		this.listen();
	}

	// --- Memory ----------------------------------------------------------------

	// Views of wasm memory, renewed when it grows (which detaches the old buffer).
	get dv() {
		const buf = this.wmi.memory.buffer;
		if (buf !== this.buf) {
			this.buf = buf;
			this.view = new DataView(buf);
			this.bytes = new Uint8Array(buf);
		}
		return this.view;
	}
	f32(p) { return this.dv.getFloat32(p, true); }
	i32(p) { return this.dv.getInt32(p, true); }
	u32(p) { return this.dv.getUint32(p, true); }
	vec2(p) { return [this.f32(p), this.f32(p + 4)]; }
	vec3(p) { return [this.f32(p), this.f32(p + 4), this.f32(p + 8)]; }
	rect(p) { return [this.f32(p), this.f32(p + 4), this.f32(p + 8), this.f32(p + 12)]; }
	color(p) {
		const d = this.dv;
		return [d.getUint8(p), d.getUint8(p + 1), d.getUint8(p + 2), d.getUint8(p + 3)];
	}
	cstring(p) {
		if (!p) return '';
		this.dv;
		let end = p;
		while (this.bytes[end]) end++;
		return this.decoder.decode(this.bytes.subarray(p, end));
	}
	storeF32s(p, ...values) {
		const d = this.dv;
		values.forEach((v, i) => d.setFloat32(p + i * 4, v, true));
	}
	storeI32s(p, ...values) {
		const d = this.dv;
		values.forEach((v, i) => d.setInt32(p + i * 4, v, true));
	}
	// Texture2D: id, width, height, mipmaps, format.
	storeTexture(p, id, w, h, mipmaps = 1, format = 7 /* UNCOMPRESSED_R8G8B8A8 */) {
		this.storeI32s(p, id, w, h, mipmaps, format);
	}

	// --- Input -----------------------------------------------------------------

	listen() {
		const c = this.canvas;
		window.addEventListener('keydown', e => {
			const key = KEYS[e.code];
			if (key === undefined) return;
			// Leave the browser's own shortcuts alone.
			if (!e.metaKey && !e.ctrlKey && !e.altKey && !(key >= 290 && key <= 301)) e.preventDefault();
			if (e.repeat) this.keysRepeated.add(key);
			else this.keysPressed.add(key);
			this.keysDown.add(key);
		});
		window.addEventListener('keyup', e => {
			const key = KEYS[e.code];
			if (key === undefined) return;
			this.keysDown.delete(key);
			this.keysReleased.add(key);
		});
		window.addEventListener('blur', () => {
			for (const key of this.keysDown) this.keysReleased.add(key);
			this.keysDown.clear();
			this.buttonsDown.fill(false);
		});
		const move = e => {
			const r = c.getBoundingClientRect();
			this.mouse = [e.clientX - r.left, e.clientY - r.top];
		};
		c.addEventListener('pointermove', move);
		c.addEventListener('pointerdown', e => {
			move(e);
			c.setPointerCapture(e.pointerId);
			const b = MOUSE_BUTTONS[e.button];
			if (b === undefined) return;
			this.buttonsDown[b] = true;
			this.buttonsPressed[b] = true;
		});
		const up = e => {
			move(e);
			const b = MOUSE_BUTTONS[e.button];
			if (b !== undefined) this.buttonsDown[b] = false;
		};
		c.addEventListener('pointerup', up);
		c.addEventListener('pointercancel', up);
		c.addEventListener('contextmenu', e => e.preventDefault());
		// GLFW's wheel is in lines, positive away from you; scrolld scrolls 40
		// px per line, so pixel deltas scroll 1:1.
		c.addEventListener('wheel', e => {
			e.preventDefault();
			if (e.ctrlKey) return; // pinch-zoom on a trackpad
			const scale = e.deltaMode === 1 ? 1 : e.deltaMode === 2 ? 20 : 1 / 40;
			this.wheel[0] -= e.deltaX * scale;
			this.wheel[1] -= e.deltaY * scale;
		}, { passive: false });
	}

	// Sizes the canvas to its CSS box in device pixels, once a frame, before
	// anything is drawn (resizing clears it).
	sync() {
		if (this.sized) return;
		this.sized = true;
		const c = this.canvas;
		this.dpr = window.devicePixelRatio || 1;
		this.screenW = Math.max(1, c.clientWidth);
		this.screenH = Math.max(1, c.clientHeight);
		const w = Math.max(1, Math.round(this.screenW * this.dpr)), h = Math.max(1, Math.round(this.screenH * this.dpr));
		if (c.width !== w || c.height !== h) c.width = w, c.height = h;
	}

	// --- Batch -----------------------------------------------------------------

	// Starts a shape of n vertices with texture id tex.
	begin(tex, n) {
		if (this.count + n > MAX_VERTICES) this.flush();
		const last = this.draws[this.draws.length - 1];
		if (!last || last.tex !== tex) this.draws.push({ tex, start: this.count });
	}

	end() {
		this.depth += 1 / 20000;
	}

	vertex(x, y, u, v, c) {
		let z = this.depth;
		if (this.transformRequired) {
			const m = this.transform;
			[x, y, z] = [m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]];
		}
		const i = this.count * 6, b = this.count * VERTEX_BYTES + 20;
		this.vf32[i] = x, this.vf32[i + 1] = y, this.vf32[i + 2] = z;
		this.vf32[i + 3] = u, this.vf32[i + 4] = v;
		this.vu8[b] = c[0], this.vu8[b + 1] = c[1], this.vu8[b + 2] = c[2], this.vu8[b + 3] = c[3];
		this.count++;
	}

	// A triangle of [x, y] points in the shapes texture.
	triangle(a, b, c, color) {
		this.vertex(a[0], a[1], 0.5, 0.5, color);
		this.vertex(b[0], b[1], 0.5, 0.5, color);
		this.vertex(c[0], c[1], 0.5, 0.5, color);
	}

	quad(tl, bl, br, tr, color) {
		this.triangle(tl, bl, br, color);
		this.triangle(tl, br, tr, color);
	}

	flush() {
		const gl = this.gl;
		if (this.count > 0) {
			gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
			gl.bufferSubData(gl.ARRAY_BUFFER, 0, this.vu8, 0, this.count * VERTEX_BYTES);
			const sh = this.shaders.get(this.shader);
			gl.useProgram(sh.program);
			gl.uniformMatrix4fv(sh.mvp, false, mat.mul(this.projection, this.modelview));
			gl.uniform4f(sh.colDiffuse, 1, 1, 1, 1);
			gl.uniform1i(sh.texture0, 0);
			gl.bindVertexArray(this.vao);
			gl.activeTexture(gl.TEXTURE0);
			this.draws.forEach((d, k) => {
				const end = k + 1 < this.draws.length ? this.draws[k + 1].start : this.count;
				gl.bindTexture(gl.TEXTURE_2D, this.textures.get(d.tex) ?? this.textures.get(this.white));
				gl.drawArrays(gl.TRIANGLES, d.start, end - d.start);
			});
		}
		this.count = 0;
		this.draws.length = 0;
		this.depth = -1;
	}

	// --- Textures and shaders --------------------------------------------------

	createTexture(w, h, pixels) {
		const gl = this.gl, t = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, t);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
		return this.addTexture(t);
	}

	// From an ImageBitmap or canvas, into the Texture2D at p.
	loadTexture(source, p) {
		const gl = this.gl, t = gl.createTexture();
		gl.bindTexture(gl.TEXTURE_2D, t);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, source);
		this.storeTexture(p, this.addTexture(t), source.width, source.height);
	}

	// raylib's defaults: repeat, and point filtering until SetTextureFilter.
	addTexture(t) {
		const gl = this.gl;
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
		gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
		const id = this.nextTexture++;
		this.textures.set(id, t);
		return id;
	}

	compileShader(vsSource, fsSource) {
		const gl = this.gl;
		const compile = (type, source) => {
			const s = gl.createShader(type);
			gl.shaderSource(s, source);
			gl.compileShader(s);
			if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
				console.warn('raylib.js: shader failed to compile:\n' + gl.getShaderInfoLog(s));
				return null;
			}
			return s;
		};
		const vs = compile(gl.VERTEX_SHADER, vsSource), fs = compile(gl.FRAGMENT_SHADER, fsSource);
		if (!vs || !fs) return this.defaultShader;
		const program = gl.createProgram();
		gl.attachShader(program, vs);
		gl.attachShader(program, fs);
		gl.bindAttribLocation(program, 0, 'vertexPosition');
		gl.bindAttribLocation(program, 1, 'vertexTexCoord');
		gl.bindAttribLocation(program, 2, 'vertexColor');
		gl.linkProgram(program);
		if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
			console.warn('raylib.js: shader failed to link:\n' + gl.getProgramInfoLog(program));
			return this.defaultShader;
		}
		const id = this.nextShader++;
		this.shaders.set(id, {
			program,
			mvp: gl.getUniformLocation(program, 'mvp'),
			colDiffuse: gl.getUniformLocation(program, 'colDiffuse'),
			texture0: gl.getUniformLocation(program, 'texture0'),
			locs: [], // GetShaderLocation's, by index
		});
		return id;
	}

	setShader(id) {
		if (id === this.shader) return;
		this.flush();
		this.shader = id;
	}

	// --- Drawing ---------------------------------------------------------------

	// raylib's DrawTexturePro.
	drawTexturePro(id, tw, th, src, dst, origin, rotation, tint) {
		let [sx, sy, sw, sh] = src;
		let [dx, dy, dw, dh] = dst;
		let flipX = false;
		if (sw < 0) flipX = true, sw = -sw;
		if (sh < 0) sy -= sh;
		dw = Math.abs(dw), dh = Math.abs(dh);
		let tl, tr, bl, br;
		if (rotation === 0) {
			const x = dx - origin[0], y = dy - origin[1];
			tl = [x, y], tr = [x + dw, y], bl = [x, y + dh], br = [x + dw, y + dh];
		} else {
			const s = Math.sin(rotation * Math.PI / 180), c = Math.cos(rotation * Math.PI / 180);
			const ox = -origin[0], oy = -origin[1];
			const at = (px, py) => [dx + px * c - py * s, dy + px * s + py * c];
			tl = at(ox, oy), tr = at(ox + dw, oy), bl = at(ox, oy + dh), br = at(ox + dw, oy + dh);
		}
		const u0 = (flipX ? sx + sw : sx) / tw, u1 = (flipX ? sx : sx + sw) / tw;
		const v0 = sy / th, v1 = (sy + sh) / th;
		this.begin(id, 6);
		this.vertex(tl[0], tl[1], u0, v0, tint);
		this.vertex(bl[0], bl[1], u0, v1, tint);
		this.vertex(br[0], br[1], u1, v1, tint);
		this.vertex(tl[0], tl[1], u0, v0, tint);
		this.vertex(br[0], br[1], u1, v1, tint);
		this.vertex(tr[0], tr[1], u1, v0, tint);
		this.end();
	}

	drawRectangle(x, y, w, h, color) {
		this.begin(this.white, 6);
		this.quad([x, y], [x, y + h], [x + w, y + h], [x + w, y], color);
		this.end();
	}

	// Corner segments when raylib picks them, for a circle of radius r.
	static segmentsFor(r, degrees) {
		const th = Math.acos(2 * Math.pow(1 - SMOOTH_CIRCLE_ERROR_RATE / r, 2) - 1);
		return Math.ceil(2 * Math.PI / th) * degrees / 360;
	}

	// raylib's DrawRectangleRounded: four corner fans around a cross of rectangles.
	drawRectangleRounded([x, y, w, h], roundness, segments, color) {
		if (roundness <= 0 || w < 1 || h < 1) return this.drawRectangle(x, y, w, h, color);
		roundness = Math.min(roundness, 1);
		const r = (w > h ? h : w) * roundness / 2;
		if (r <= 0) return;
		if (segments < 4) segments = Math.max(Math.trunc(Raylib.segmentsFor(r, 360) / 4), 4);
		const step = 90 / segments;
		const centers = [[x + r, y + r], [x + w - r, y + r], [x + w - r, y + h - r], [x + r, y + h - r]];
		const angles = [180, 270, 0, 90];
		this.begin(this.white, segments * 12 + 30);
		for (let k = 0; k < 4; k++) {
			const [cx, cy] = centers[k];
			let a = angles[k];
			for (let i = 0; i < segments; i++, a += step) {
				const a0 = a * Math.PI / 180, a1 = (a + step) * Math.PI / 180;
				this.triangle([cx, cy], [cx + Math.cos(a1) * r, cy + Math.sin(a1) * r], [cx + Math.cos(a0) * r, cy + Math.sin(a0) * r], color);
			}
		}
		const q = (x0, y0, x1, y1) => this.quad([x0, y0], [x0, y1], [x1, y1], [x1, y0], color);
		q(x + r, y, x + w - r, y + r); // top
		q(x + w - r, y + r, x + w, y + h - r); // right
		q(x + r, y + h - r, x + w - r, y + h); // bottom
		q(x, y + r, x + r, y + h - r); // left
		q(x + r, y + r, x + w - r, y + h - r); // middle
		this.end();
	}

	fontFor(fontPtr) {
		return this.fonts.get(this.u32(fontPtr + 12));
	}

	glyphIndex(font, codepoint) {
		return font.index.get(codepoint) ?? font.index.get(63) ?? 0; // '?' when it's missing
	}

	// --- Imports ---------------------------------------------------------------

	get imports() {
		const gl = this.gl;
		return { raylib: {
			// Window
			SetConfigFlags: () => {},
			SetTraceLogLevel: () => {},
			SetExitKey: () => {},
			InitWindow: (w, h, title) => {
				document.title = this.cstring(title);
				this.sync();
			},
			WindowShouldClose: () => false,
			CloseWindow: () => {},
			IsWindowState: flags => (document.fullscreenElement ? FLAG_BORDERLESS_WINDOWED_MODE : 0) & flags ? 1 : 0,
			ToggleBorderlessWindowed: () => {
				if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
				else document.documentElement.requestFullscreen().catch(() => {});
			},
			GetScreenWidth: () => (this.sync(), this.screenW),
			GetScreenHeight: () => (this.sync(), this.screenH),
			GetRenderWidth: () => (this.sync(), this.canvas.width),
			GetRenderHeight: () => (this.sync(), this.canvas.height),
			GetWindowScaleDPI: ret => (this.sync(), this.storeF32s(ret, this.dpr, this.dpr)),
			GetTime: () => (performance.now() - this.start) / 1000,
			GetFrameTime: () => this.frameTime,

			// Input. Pressed and released are since the last EndDrawing.
			IsKeyDown: key => this.keysDown.has(key) ? 1 : 0,
			IsKeyPressed: key => this.keysPressed.has(key) ? 1 : 0,
			IsKeyPressedRepeat: key => this.keysRepeated.has(key) ? 1 : 0,
			IsKeyReleased: key => this.keysReleased.has(key) ? 1 : 0,
			IsMouseButtonDown: b => this.buttonsDown[b] ? 1 : 0,
			IsMouseButtonPressed: b => this.buttonsPressed[b] ? 1 : 0,
			GetMousePosition: ret => this.storeF32s(ret, this.mouse[0], this.mouse[1]),
			GetMouseX: () => Math.trunc(this.mouse[0]),
			GetMouseWheelMoveV: ret => this.storeF32s(ret, this.wheel[0], this.wheel[1]),

			// Frame
			BeginDrawing: () => {
				this.sync();
				gl.viewport(0, 0, this.canvas.width, this.canvas.height);
				this.projection = mat.ortho(0, this.screenW, this.screenH, 0, 0, 1);
				this.modelview = mat.identity();
				this.current = this.modelview;
			},
			EndDrawing: () => {
				this.flush();
				const now = performance.now();
				// Capped, so coming back to a background tab doesn't jump the scroll.
				this.frameTime = Math.min((now - this.lastFrame) / 1000, 0.25);
				this.lastFrame = now;
				this.sized = false;
				this.keysPressed.clear();
				this.keysRepeated.clear();
				this.keysReleased.clear();
				this.buttonsPressed.fill(false);
				this.wheel = [0, 0];
			},
			ClearBackground: color => {
				const [r, g, b, a] = this.color(color);
				gl.clearColor(r / 255, g / 255, b / 255, a / 255);
				gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
			},
			BeginMode3D: camPtr => {
				this.flush();
				const position = this.vec3(camPtr), target = this.vec3(camPtr + 12), up = this.vec3(camPtr + 24), fovy = this.f32(camPtr + 36);
				const top = CULL_NEAR * Math.tan(fovy / 2 * Math.PI / 180), right = top * this.canvas.width / this.canvas.height;
				this.projection = mat.frustum(-right, right, -top, top, CULL_NEAR, CULL_FAR);
				this.modelview = mat.lookAt(position, target, up);
				this.current = this.modelview;
				gl.enable(gl.DEPTH_TEST);
			},
			EndMode3D: () => {
				this.flush();
				this.projection = mat.ortho(0, this.screenW, this.screenH, 0, 0, 1);
				this.modelview = mat.identity();
				this.current = this.modelview;
				gl.disable(gl.DEPTH_TEST);
			},
			BeginScissorMode: (x, y, w, h) => {
				this.flush();
				gl.enable(gl.SCISSOR_TEST);
				const s = this.dpr;
				gl.scissor(Math.trunc(x * s), Math.trunc(this.screenH * s - (y + h) * s), Math.trunc(w * s), Math.trunc(h * s));
			},
			EndScissorMode: () => {
				this.flush();
				gl.disable(gl.SCISSOR_TEST);
			},
			GetScreenToWorldRay: (ret, posPtr, camPtr) => {
				const [px, py] = this.vec2(posPtr);
				const position = this.vec3(camPtr), target = this.vec3(camPtr + 12), up = this.vec3(camPtr + 24), fovy = this.f32(camPtr + 36);
				const x = 2 * px / this.screenW - 1, y = 1 - 2 * py / this.screenH;
				const f = vec3.norm(vec3.sub(target, position)), r = vec3.norm(vec3.cross(f, up)), u = vec3.cross(r, f);
				const th = Math.tan(fovy / 2 * Math.PI / 180), tw = th * this.screenW / this.screenH;
				const d = vec3.norm([0, 1, 2].map(i => f[i] + r[i] * x * tw + u[i] * y * th));
				this.storeF32s(ret, ...position, ...d);
			},

			// rlgl
			rlPushMatrix: () => {
				this.transformRequired = true;
				this.current = this.transform;
				this.stack.push(this.current.slice());
			},
			rlPopMatrix: () => {
				if (this.stack.length > 0) this.current.splice(0, 16, ...this.stack.pop());
				if (this.stack.length === 0) {
					this.current = this.modelview;
					this.transformRequired = false;
				}
			},
			rlMultMatrixf: p => this.current.splice(0, 16, ...mat.mul(this.current, Array.from({ length: 16 }, (_, i) => this.f32(p + i * 4)))),
			rlTranslatef: (x, y, z) => this.current.splice(0, 16, ...mat.mul(this.current, mat.translate(x, y, z))),
			rlRotatef: (a, x, y, z) => this.current.splice(0, 16, ...mat.mul(this.current, mat.rotate(a, x, y, z))),
			rlDrawRenderBatchActive: () => this.flush(),
			rlEnableDepthTest: () => gl.enable(gl.DEPTH_TEST),
			rlDisableDepthTest: () => gl.disable(gl.DEPTH_TEST),
			// Culling stays off: nothing scrolld draws faces away, and the
			// triangles here aren't wound as raylib's are.
			rlEnableBackfaceCulling: () => {},
			rlDisableBackfaceCulling: () => {},

			// Shaders
			LoadShaderFromMemory: (ret, vs, fs) => {
				const id = this.compileShader(vs ? this.cstring(vs) : DEFAULT_VS, fs ? this.cstring(fs) : DEFAULT_FS);
				this.storeI32s(ret, id, 0);
			},
			GetShaderLocation: (shaderPtr, name) => {
				const sh = this.shaders.get(this.u32(shaderPtr));
				const loc = sh && gl.getUniformLocation(sh.program, this.cstring(name));
				if (!loc) return -1;
				sh.locs.push(loc);
				return sh.locs.length - 1;
			},
			// Sets it right away, as raylib does, so it applies to the whole
			// pending batch.
			SetShaderValue: (shaderPtr, locIndex, value, type) => {
				const sh = this.shaders.get(this.u32(shaderPtr));
				const loc = sh?.locs[locIndex];
				if (!loc) return;
				gl.useProgram(sh.program);
				const f = n => Array.from({ length: n }, (_, i) => this.f32(value + i * 4));
				const i = n => Array.from({ length: n }, (_, k) => this.i32(value + k * 4));
				switch (type) {
				case 0: gl.uniform1fv(loc, f(1)); break; // FLOAT
				case 1: gl.uniform2fv(loc, f(2)); break;
				case 2: gl.uniform3fv(loc, f(3)); break;
				case 3: gl.uniform4fv(loc, f(4)); break;
				case 4: gl.uniform1iv(loc, i(1)); break; // INT
				case 5: gl.uniform2iv(loc, i(2)); break;
				case 6: gl.uniform3iv(loc, i(3)); break;
				case 7: gl.uniform4iv(loc, i(4)); break;
				}
			},
			BeginShaderMode: shaderPtr => this.setShader(this.u32(shaderPtr)),
			EndShaderMode: () => this.setShader(this.defaultShader),

			// Textures
			UnloadTexture: p => {
				const id = this.u32(p);
				gl.deleteTexture(this.textures.get(id) ?? null);
				this.textures.delete(id);
			},
			GenTextureMipmaps: p => {
				const w = this.i32(p + 4), h = this.i32(p + 8);
				gl.bindTexture(gl.TEXTURE_2D, this.textures.get(this.u32(p)) ?? null);
				gl.generateMipmap(gl.TEXTURE_2D);
				this.dv.setInt32(p + 12, 1 + Math.floor(Math.log2(Math.max(w, h))), true);
			},
			SetTextureFilter: (p, filter) => {
				const t = this.textures.get(this.u32(p));
				if (!t) return;
				const mipmapped = this.i32(p + 12) > 1;
				gl.bindTexture(gl.TEXTURE_2D, t);
				const set = (min, mag) => {
					gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, min);
					gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, mag);
				};
				switch (filter) {
				case 0: set(mipmapped ? gl.NEAREST_MIPMAP_NEAREST : gl.NEAREST, gl.NEAREST); break; // POINT
				case 1: set(mipmapped ? gl.LINEAR_MIPMAP_NEAREST : gl.LINEAR, gl.LINEAR); break; // BILINEAR
				case 2: set(mipmapped ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR, gl.LINEAR); break; // TRILINEAR
				case 3: case 4: case 5: // ANISOTROPIC_4X, 8X, 16X
					if (this.aniso) gl.texParameterf(gl.TEXTURE_2D, this.aniso.TEXTURE_MAX_ANISOTROPY_EXT, Math.min(4 << (filter - 3), this.maxAniso));
					break;
				}
			},

			// Shapes
			DrawRectangleRec: (rec, color) => {
				const [x, y, w, h] = this.rect(rec);
				this.drawRectangle(x, y, w, h, this.color(color));
			},
			DrawRectangleRounded: (rec, roundness, segments, color) => this.drawRectangleRounded(this.rect(rec), roundness, segments, this.color(color)),
			DrawLineEx: (startPtr, endPtr, thick, colorPtr) => {
				const s = this.vec2(startPtr), e = this.vec2(endPtr), color = this.color(colorPtr);
				const dx = e[0] - s[0], dy = e[1] - s[1], len = Math.hypot(dx, dy);
				if (len <= 0 || thick <= 0) return;
				const k = thick / (2 * len), rx = -k * dy, ry = k * dx;
				this.begin(this.white, 6);
				this.quad([s[0] - rx, s[1] - ry], [s[0] + rx, s[1] + ry], [e[0] + rx, e[1] + ry], [e[0] - rx, e[1] - ry], color);
				this.end();
			},
			DrawCircleV: (centerPtr, radius, colorPtr) => {
				const [cx, cy] = this.vec2(centerPtr), color = this.color(colorPtr);
				const segments = Math.max(36, Math.trunc(Raylib.segmentsFor(radius, 360)));
				const step = 360 / segments;
				this.begin(this.white, segments * 3);
				for (let i = 0, a = 0; i < segments; i++, a += step) {
					const a0 = a * Math.PI / 180, a1 = (a + step) * Math.PI / 180;
					this.triangle([cx, cy], [cx + Math.cos(a1) * radius, cy + Math.sin(a1) * radius], [cx + Math.cos(a0) * radius, cy + Math.sin(a0) * radius], color);
				}
				this.end();
			},
			DrawTexturePro: (texPtr, srcPtr, dstPtr, originPtr, rotation, tintPtr) => {
				const id = this.u32(texPtr);
				if (id === 0) return;
				this.drawTexturePro(id, this.i32(texPtr + 4), this.i32(texPtr + 8), this.rect(srcPtr), this.rect(dstPtr), this.vec2(originPtr), rotation, this.color(tintPtr));
			},

			// Text. The font is drawn by the browser into an atlas: fileName is a
			// CSS font family.
			LoadFontEx: (ret, fileName, fontSize, codepointsPtr, count) => this.loadFont(ret, this.cstring(fileName), fontSize, codepointsPtr, count),
			GetGlyphIndex: (fontPtr, codepoint) => this.glyphIndex(this.fontFor(fontPtr), codepoint),
			MeasureTextEx: (ret, fontPtr, textPtr, fontSize, spacing) => {
				const font = this.fontFor(fontPtr), text = this.cstring(textPtr);
				if (!font || text === '') return this.storeF32s(ret, 0, 0);
				const scale = fontSize / font.baseSize;
				let width = 0, maxWidth = 0, height = fontSize, chars = 0, maxChars = 0;
				for (const ch of text) {
					const cp = ch.codePointAt(0);
					chars++;
					if (cp !== 10) {
						const g = font.glyphs[this.glyphIndex(font, cp)];
						width += g.advanceX > 0 ? g.advanceX : g.w + g.offsetX;
					} else {
						maxWidth = Math.max(maxWidth, width);
						chars = 0, width = 0;
						height += fontSize + TEXT_LINE_SPACING;
					}
					maxChars = Math.max(maxChars, chars);
				}
				maxWidth = Math.max(maxWidth, width);
				this.storeF32s(ret, maxWidth * scale + (maxChars - 1) * spacing, height);
			},
			DrawTextEx: (fontPtr, textPtr, posPtr, fontSize, spacing, tintPtr) => {
				const font = this.fontFor(fontPtr);
				if (!font) return;
				const [px, py] = this.vec2(posPtr), tint = this.color(tintPtr), text = this.cstring(textPtr);
				const scale = fontSize / font.baseSize, pad = font.padding;
				let x = 0, y = 0;
				for (const ch of text) {
					const cp = ch.codePointAt(0);
					if (cp === 10) {
						y += fontSize + TEXT_LINE_SPACING;
						x = 0;
						continue;
					}
					const g = font.glyphs[this.glyphIndex(font, cp)];
					if (cp !== 32 && cp !== 9) {
						this.drawTexturePro(font.texture, font.width, font.height,
							[g.x - pad, g.y - pad, g.w + 2 * pad, g.h + 2 * pad],
							[px + x + (g.offsetX - pad) * scale, py + y + (g.offsetY - pad) * scale, (g.w + 2 * pad) * scale, (g.h + 2 * pad) * scale],
							[0, 0], 0, tint);
					}
					x += (g.advanceX === 0 ? g.w : g.advanceX) * scale + spacing;
				}
			},
		} };
	}

	// LoadFontEx, with the glyphs drawn by the browser into an atlas. Sized as
	// stb_truetype's ScaleForPixelHeight is, so ascent to descent is fontSize.
	loadFont(ret, family, fontSize, codepointsPtr, count) {
		const PADDING = 4, ATLAS_W = 1024;
		const codepoints = [];
		if (codepointsPtr && count > 0) for (let i = 0; i < count; i++) codepoints.push(this.i32(codepointsPtr + i * 4));
		else for (let cp = 32; cp < 127; cp++) codepoints.push(cp);

		const canvas = document.createElement('canvas'), ctx = canvas.getContext('2d');
		ctx.font = `100px ${family}`;
		const m = ctx.measureText('Hg');
		const px = fontSize * 100 / (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent);
		const ascent = Math.round(m.fontBoundingBoxAscent * px / 100);
		const font = `${px}px ${family}`;
		ctx.font = font;

		// Each glyph's box around its pen position (left, top <= 0), packed in shelves.
		let x = PADDING, y = PADDING, shelf = 0;
		const glyphs = codepoints.map(cp => {
			const gm = ctx.measureText(String.fromCodePoint(cp));
			const left = Math.floor(-gm.actualBoundingBoxLeft), right = Math.ceil(gm.actualBoundingBoxRight);
			const top = Math.floor(-gm.actualBoundingBoxAscent), bottom = Math.ceil(gm.actualBoundingBoxDescent);
			const w = Math.max(0, right - left), h = Math.max(0, bottom - top);
			if (x + w + PADDING > ATLAS_W) x = PADDING, y += shelf + 2 * PADDING, shelf = 0;
			const g = { value: cp, x, y, w, h, left, top, offsetX: left, offsetY: ascent + top, advanceX: Math.trunc(gm.width) };
			x += w + 2 * PADDING;
			shelf = Math.max(shelf, h);
			return g;
		});
		canvas.width = ATLAS_W;
		canvas.height = y + shelf + PADDING;
		ctx.font = font;
		ctx.fillStyle = '#fff';
		for (const g of glyphs) ctx.fillText(String.fromCodePoint(g.value), g.x - g.left, g.y - g.top);

		const texPtr = ret + 12;
		this.loadTexture(canvas, texPtr);
		this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_WRAP_S, this.gl.CLAMP_TO_EDGE);
		this.gl.texParameteri(this.gl.TEXTURE_2D, this.gl.TEXTURE_WRAP_T, this.gl.CLAMP_TO_EDGE);
		const texture = this.u32(texPtr);

		// The Font struct, and the arrays scrolld's measure_text reads.
		const n = glyphs.length;
		const recs = this.wmi.exports.web_alloc(n * 16), infos = this.wmi.exports.web_alloc(n * 36);
		glyphs.forEach((g, i) => {
			this.storeF32s(recs + i * 16, g.x, g.y, g.w, g.h);
			this.storeI32s(infos + i * 36, g.value, g.offsetX, g.offsetY, g.advanceX);
		});
		this.storeI32s(ret, fontSize, n, PADDING);
		this.storeI32s(ret + 32, recs, infos);
		this.fonts.set(texture, {
			baseSize: fontSize, padding: PADDING, texture, width: canvas.width, height: canvas.height,
			glyphs, index: new Map(glyphs.map((g, i) => [g.value, i])),
		});
	}
}
