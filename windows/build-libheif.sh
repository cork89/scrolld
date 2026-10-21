#!/usr/bin/env bash
# Builds windows/libheif.dll: libheif with only the libde265 HEVC decoder (all
# scrolld needs for HEIC), with libde265 and the GCC runtime linked in, so it is
# one self-contained DLL. Run from the repo root through MSYS2 (`just libheif`).
set -euo pipefail

version=1.23.6
sha256=4484346dc5995319dbc11e3a1c35d0a2ec46511ce370900869337fd2c7033125

export MSYSTEM=UCRT64
export PATH=/ucrt64/bin:$PATH
pacman -S --needed --noconfirm \
	mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja \
	mingw-w64-ucrt-x86_64-libde265

out=$PWD/windows
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

curl -sfLO https://github.com/strukturag/libheif/releases/download/v$version/libheif-$version.tar.gz
echo "$sha256 *libheif-$version.tar.gz" | sha256sum -c -
tar xzf libheif-$version.tar.gz

off=""
for codec in X265 KVAZAAR UVG266 VVDEC VVENC X264 OpenH264_DECODER DAV1D AOM_DECODER AOM_ENCODER \
	SvtEnc RAV1E JPEG_DECODER JPEG_ENCODER OpenJPEG_DECODER OpenJPEG_ENCODER FFMPEG_DECODER OPENJPH_ENCODER; do
	off="$off -DWITH_$codec=OFF"
done

# LIBDE265_STATIC_BUILD drops de265.h's dllimport so libde265.a links in.
cmake -S libheif-$version -B build -G Ninja $off \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=ON \
	-DBUILD_TESTING=OFF \
	-DWITH_EXAMPLES=OFF \
	-DWITH_GDK_PIXBUF=OFF \
	-DENABLE_PLUGIN_LOADING=OFF \
	-DWITH_HEADER_COMPRESSION=OFF \
	-DWITH_LIBSHARPYUV=OFF \
	-DWITH_LIBDE265=ON \
	-DWITH_LIBDE265_PLUGIN=OFF \
	-DLIBDE265_LIBRARY=/ucrt64/lib/libde265.a \
	-DCMAKE_CXX_FLAGS=-DLIBDE265_STATIC_BUILD \
	-DCMAKE_SHARED_LINKER_FLAGS=-static
cmake --build build

cp build/libheif/libheif.dll "$out/libheif.dll"
strip "$out/libheif.dll"
cp libheif-$version/COPYING "$out/libheif-COPYING"
