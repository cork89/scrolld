# scrolld

- a command line utility to auto scroll your image library

## Quick start

### macOS

```sh
brew install odin just raylib webp libheif jpeg-turbo
just build
./bin/scrolld -h
```

### Windows

```sh
winget install odin-lang.Odin Casey.Just Git.Git
just build
./bin/scrolld -h
```

The first build downloads libwebp. libheif is prebuilt in `windows/`; rebuilding it with `just libheif` also needs [MSYS2](https://www.msys2.org).

Then run it with `just run [dir]`, or `./bin/scrolld [dir]`.

### Web

```sh
just web ~/some/images
python3 -m http.server -d bin/web
```

Open in http://localhost:8000. This builds `bin/web` with the JPEG, PNG, GIF and BMP images in the directory (not its subdirectories). `web/raylib.js` implements the raylib calls scrolld makes, on WebGL 2, and the browser decodes the images. Settings are kept in localStorage, and `?shuffle`, `?crawl` and `?sideways` work like the flags.
