build:
  zig build --release=fast

move-exe target_name:
  mv ./zig-out/bin/wc {{target_name}}

run: build
  ./zig-out/bin/wc -lwm zhwiki-latest-all-titles

bench: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles"

bench_against other: build
  hyperfine "./zig-out/bin/wc -lwm zhwiki-latest-all-titles" "{{other}} -lwm zhwiki-latest-all-titles"

test:
  zig test src/main.zig -lc

bench_simple file: build
  hyperfine -N --style=color "./dfa-wc {{file}}" "wc {{file}}"

bench_all file: build
  hyperfine -N --style=color "./parallel-wc -lwc {{file}}" "./sequential-wc -lwc {{file}}" "wc -lwc {{file}}"