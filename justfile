build:
    zig build --release=fast

build-exe target_name: build
    mv ./zig-out/bin/wc {{ target_name }}

run: build
    ./zig-out/bin/wc -lwm zhwiki-latest-all-titles

bench: build
    hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles"

bench_against other file="zhwiki-latest-all-titles": build
    hyperfine "./zig-out/bin/wc -lwm {{ file }}" "{{ other }} -lwm {{ file }}"

test:
    zig test src/main.zig -lc

bench_simple file: build
    hyperfine -N --style=color "./dfa-wc {{ file }}" "wc {{ file }}"

bench_all file:
    hyperfine -N --style=color --warmup 5 "./parallel-wc -lwc {{ file }}" "./sequential-wc -lwc {{ file }}" "wc -lwc {{ file }}" 
