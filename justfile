exe := if os_family() == "windows" { ".exe" } else { "" }
resource := if os_family() == "windows" { "-resource:windows/scrolld.res" } else { "" }
msys := env("MSYS2_ROOT", "C:/msys64")

build: deps
    mkdir -p bin
    odin build . -define:RAYLIB_SHARED=true -o:speed -out:bin/scrolld{{exe}} {{resource}}

run *args: build
    ./bin/scrolld{{exe}} {{args}}

# Builds the web version into bin/web, with the images in dir, ready to serve
# with `python3 -m http.server -d bin/web`. Homebrew's Odin needs wasm-ld from
# its lld dependency, which isn't on PATH.
web dir:
    mkdir -p bin/web
    PATH="$(dirname "$(command -v wasm-ld || ls /opt/homebrew/opt/lld*/bin/wasm-ld | tail -1)"):$PATH" odin build . -target:js_wasm32 -define:RAYLIB_WASM_LIB=raylib -o:speed -out:bin/web/scrolld.wasm
    cp web/index.html web/raylib.js web/scrolld.js icon.png "$(odin root)/core/sys/wasm/js/odin.js" bin/web/
    odin run web/manifest -- "{{dir}}" bin/web/images

# Builds the web version and force-pushes it, as a single commit, to the
# gh-pages branch, which GitHub Pages serves (Settings > Pages > Deploy from a
# branch: gh-pages, root).
pages dir: (web dir)
    touch bin/web/.nojekyll
    rm -rf bin/web/.git
    cd bin/web && git init -q -b gh-pages && git add -A && git commit -q -m "Deploy web demo" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && git push -f "$(git -C ../.. remote get-url origin)" gh-pages
    rm -rf bin/web/.git

webp_version := "1.6.0"
webp_sha256 := "48886f506b21f62e4661f0f4cbfca19800897c385128e8902542d29a950c93f1"

# Downloads Google's static libwebp into windows/libwebp/ (skipped once it's
# there), generates libheif's import library, and copies the two DLLs the exe
# loads into bin/: raylib's from Odin and the committed windows/libheif.dll.
[windows]
deps:
    [ -f windows/libwebp/lib/libwebp.lib ] || { curl -sfL -o windows/libwebp.zip https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-{{webp_version}}-windows-x64.zip && echo "{{webp_sha256}} *windows/libwebp.zip" | sha256sum -c - && unzip -q windows/libwebp.zip -d windows && mv windows/libwebp-{{webp_version}}-windows-x64 windows/libwebp && rm windows/libwebp.zip; }
    "$(odin root)/bin/lld-link.exe" -lib -machine:x64 -def:windows/heif.def -out:windows/heif.lib
    mkdir -p bin
    cp "$(odin root)/vendor/raylib/windows/raylib.dll" windows/libheif.dll bin/

# Rebuilds windows/libheif.dll from source with MSYS2; only needed to change
# libheif's version or codecs.
[windows]
libheif:
    {{msys}}/usr/bin/bash -lc "cd '{{justfile_directory()}}' && bash windows/build-libheif.sh"

[unix]
deps:
