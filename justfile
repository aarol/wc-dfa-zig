build:
  zig build --release=fast


run: build
  ./zig-out/bin/wc -lwm zhwiki-latest-all-titles

bench: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles"

bench_against other: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles" "{{other}} -lwm zhwiki-latest-all-titles"
