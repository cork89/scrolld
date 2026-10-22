# scrolld

## Quick start

### macOS

```sh
brew install odin just raylib webp libheif jpeg-turbo
just build
```

### Windows

Install [Odin](https://odin-lang.org), [just](https://just.systems) and [Git for Windows](https://git-scm.com/download/win), which provides the `sh`, `curl` and `unzip` that the justfile uses:

```sh
winget install odin-lang.Odin Casey.Just Git.Git
just build
```

The first build downloads libwebp. libheif is prebuilt in `windows/`; rebuilding it with `just libheif` also needs [MSYS2](https://www.msys2.org).

Then run it with `just run [dir]`, or `./bin/scrolld [dir]`.
