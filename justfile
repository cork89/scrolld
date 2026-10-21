build:
    mkdir -p bin
    odin build scrolld.odin -file -define:RAYLIB_SHARED=true -o:speed -out:bin/scrolld

run *args: build
    ./bin/scrolld {{args}}
