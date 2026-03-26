# wc in Zig

A highly optimized `wc` implementation in Zig, 3-6x faster than GNU `wc`.

This is not intended as a replacement for the GNU or BSD `wc` program. For example, `--max-line-length`, which prints the maximum display width, is not implemented.

Instead, this is intended as a demonstration of how to implement a high-performance `wc` program using finite-state machines and data parallelism.

This program is built on [Robert Graham's wc2](https://github.com/robertdavidgraham/wc2/) program. It uses a finite-state-machine which processes UTF-8 text byte-by-byte at ludicrous speed without any branching.

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

Additionally, this program implements the paper [Data-Parallel Finite-State Machines](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/asplos302-mytkowicz.pdf), which further **doubles** the speed of processing large files by processing many chunks in parallel.

## Benchmarks

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

Tested on an AMD Ryzen 5 3600X 6-Core Processor in WSL (Windows Subsystem for Linux).
