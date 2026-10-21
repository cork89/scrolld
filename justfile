exe := if os_family() == "windows" { ".exe" } else { "" }
msys := env("MSYS2_ROOT", "C:/msys64")

build: deps
    mkdir -p bin
    odin build . -define:RAYLIB_SHARED=true -o:speed -out:bin/scrolld{{exe}}

run *args: build
    ./bin/scrolld{{exe}} {{args}}

# Installs webp and libheif from MSYS2, generates their import libraries, and
# copies every DLL the exe loads (raylib's from Odin, the rest from MSYS2) into bin/.
[windows]
deps:
    {{msys}}/usr/bin/bash -lc "pacman -S --needed --noconfirm mingw-w64-ucrt-x86_64-libwebp mingw-w64-ucrt-x86_64-libheif"
    zig dlltool -m i386:x86-64 -d windows/webp.def -l windows/webp.lib
    zig dlltool -m i386:x86-64 -d windows/heif.def -l windows/heif.lib
    mkdir -p bin
    cp "$(odin root)/vendor/raylib/windows/raylib.dll" bin/
    { echo /ucrt64/bin/libwebp-7.dll; echo /ucrt64/bin/libheif.dll; {{msys}}/usr/bin/bash -lc "ldd /ucrt64/bin/libwebp-7.dll /ucrt64/bin/libheif.dll"; } | grep -o '/ucrt64/bin/[^ ]*\.dll' | while read -r dll; do cp "{{msys}}$dll" bin/ || exit 1; done

[unix]
deps:
