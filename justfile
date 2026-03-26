build:
  zig build --release=fast

run: build
  ./zig-out/bin/wc -lwm zhwiki-latest-all-titles

bench: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles"

bench_against other: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles" "{{other}} -lwm zhwiki-latest-all-titles"

test:
  zig test src/main.zig -lc

bench_all file: build
  hyperfine -N --export-markdown=bench.md "./parallel-wc -lwc {{file}}" "./sequential-wc -lwc {{file}}" "wc -lwc {{file}}"