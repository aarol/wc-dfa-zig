# wc-dfa-zig

A highly optimized `wc` implementation in Zig, 4-16x faster than GNU `wc`. It achieves this by using a finite-state machine to process UTF-8 text byte-by-byte at constant speed without branching, and by implementing data parallelism to distribute the work across multiple CPU cores.

This is not intended as a complete replacement for the GNU or BSD `wc` programs. For example, the `--max-line-length` flag is not implemented. Additionally, it only supports ASCII and UTF-8 text, not UTF-16 or UTF-32.

If you find yourself needing to count the number of words in gigabytes of UTF-8 text, this program may be of use to you. Otherwise, it is just a fun exercise in optimization.

This program is built on [Robert Graham's wc2](https://github.com/robertdavidgraham/wc2/) program. It uses a finite-state-machine which processes UTF-8 text byte-by-byte at constant speed without any branching.

Here is what the core loop looks like:

```zig
const table: [State.STATE_MAX][256]u8 = gen_table();
var counts = [_]usize{0} ** State.STATE_MAX;
var state: usize = State.WASSPACE; // initial state
while (true) {
    const b = file.takeByte() catch break;
    state = table[state][b];
    counts[state] += 1;
}
```

Additionally, this program implements parallellism in [parallel.zig](src/parallel.zig) to distribute the work onto many cores, further \*quadrupling\* the speed of processing large files.

---

For the simple version of the state machine, see [simple.zig](./src/simple.zig). 

For the UTF-8 version of the state machine, see [dfa.zig](./src/dfa.zig).

For the parallel version, see [parallel.zig](./src/parallel.zig).

<!-- ## Benchmarks

Here are some benchmarks from the english and chinese wikipedia title dumps, which are 165MB text files with lots of words and lines. The `-lwm` flags tell the programs to count lines, words, and multibyte characters. 


| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `./parallel-wc -lwm enwiki-20260301-all-titles` | 136.2 ± 6.3 | 130.0 | 156.2 | 1.00 |
| `./sequential-wc -lwm enwiki-20260301-all-titles` | 351.6 ± 84.2 | 307.9 | 519.5 | 2.58 ± 0.63 |
| `wc -lwm enwiki-20260301-all-titles` | 476.4 ± 7.4 | 464.7 | 486.5 | 3.50 ± 0.17 |


| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `./parallel-wc -lwm zhwiki-latest-all-titles` | 156.9 ± 50.1 | 134.5 | 297.8 | 1.00 |
| `./sequential-wc -lwm zhwiki-latest-all-titles` | 310.9 ± 2.8 | 308.1 | 318.1 | 1.98 ± 0.63 |
| `wc -lwm zhwiki-latest-all-titles` | 1048.7 ± 10.8 | 1040.0 | 1069.4 | 6.68 ± 2.13 |

And here is the last benchmark with default `wc` flags (lines, words, bytes) and the same english wikipedia title dump:

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `./parallel-wc -lwc enwiki-20260301-all-titles` | 137.3 ± 6.1 | 130.2 | 152.5 | 1.00 |
| `./sequential-wc -lwc enwiki-20260301-all-titles` | 315.2 ± 4.7 | 312.1 | 328.1 | 2.30 ± 0.11 |
| `wc -lwc enwiki-20260301-all-titles` | 472.8 ± 5.7 | 466.9 | 485.6 | 3.44 ± 0.16 |

See the [justfile](./justfile) for testing the benchmarks yourself.

Tested on an AMD Ryzen 5 3600X 6-Core Processor in WSL (Windows Subsystem for Linux). -->
