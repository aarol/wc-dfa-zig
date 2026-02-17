const std = @import("std");
const parg = @import("parg");

const c = @cImport({
    @cInclude("wctype.h");
    @cInclude("locale.h");
});

const Opts = packed struct {
    count_lines: bool = false,
    count_words: bool = false,
    count_bytes: bool = false,
    count_chars: bool = false,
};

const ChunkData = struct {
    buffer: [CHUNK_SIZE]u8,
    size: usize,
};

const CountTask = struct {
    chunk: []const u8,
    start_state: u8,
    results_ptr: *Result,
    wg: *std.Thread.WaitGroup,
    table: *const Table,
};

const EndStateTask = struct {
    chunk: []const u8,
    results_ptr: *[32]u8,
    wg: *std.Thread.WaitGroup,
    table: *const CoalescedTable,
    uniques: *const Uniques,
    prev_char: u8,
};

fn countWorker(task: CountTask) void {
    defer task.wg.finish();

    var counts = [_]usize{0} ** State.STATE_MAX;
    var state = task.start_state;
    for (task.chunk) |b| {
        state = task.table[state][b];
        counts[state] += 1;
    }

    task.results_ptr.line_count = counts[State.NEWLINE];
    task.results_ptr.word_count = counts[State.NEWWORD];
    task.results_ptr.char_count = counts[0] + counts[1] + counts[2] + counts[3];
    var byte_count: usize = 0;
    for (0..State.STATE_MAX) |j| {
        byte_count += counts[j];
    }
    task.results_ptr.byte_count = byte_count;
}

const expect = std.testing.expect;

// This will be optimized to a SIMD gather instruction
fn gather(slice: S, index: S) S {
    const methods = struct {
        extern fn @"llvm.x86.avx2.pshuf.b"(@Vector(32, u8), @Vector(32, u8)) @Vector(32, u8);
    };
    const builtin = @import("builtin");
    if ((comptime std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))) {
        return methods.@"llvm.x86.avx2.pshuf.b"(slice, index);
    }

    var result: [32]u8 = undefined;
    comptime var vec_i = 0;
    inline while (vec_i < 32) : (vec_i += 1) {
        result[vec_i] = slice[index[vec_i]];
    }
    return result;
}

fn calc_end_states(task: EndStateTask) void {
    defer task.wg.finish();
    var prev_char = task.prev_char;

    var s: S = std.simd.iota(u8, 32);

    for (task.chunk) |b| {
        const t_active: S = task.table[prev_char][b][0..32].*;
        s = gather(t_active, s);

        prev_char = b;
    }

    const s_local: [32]u8 = s;
    for (0..32) |i| {
        task.results_ptr[i] = task.uniques[prev_char][s_local[i]];
    }
}

var thread_pool: std.Thread.Pool = undefined;

const CHUNK_SIZE = 2_000_000;

pub fn main() !void {
    var opts = Opts{};

    var total = Result{};

    const it = std.process.args();
    var p = parg.parse(it, .{});
    defer p.deinit();

    _ = p.nextValue();

    try thread_pool.init(.{ .allocator = std.heap.page_allocator });

    var files_processed: usize = 0;

    while (p.next()) |token| {
        switch (token) {
            .flag => |flag| {
                if (flag.isShort("l")) {
                    opts.count_lines = true;
                }
                if (flag.isShort("w")) {
                    opts.count_words = true;
                }
                if (flag.isShort("c")) {
                    opts.count_bytes = true;
                    opts.count_chars = false;
                }
                if (flag.isShort("m")) {
                    opts.count_chars = true;
                    opts.count_bytes = false;
                }
            },
            .arg => |arg| {
                if (opts == Opts{}) {
                    opts = Opts{
                        .count_lines = true,
                        .count_words = true,
                        .count_bytes = true,
                        .count_chars = false,
                    };
                }
                var file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
                defer file.close();
                const res = try processFile(&file);
                try printResult(opts, arg, res);
                total.line_count += res.line_count;
                total.word_count += res.word_count;
                total.byte_count += res.byte_count;
                total.char_count += res.char_count;
                files_processed += 1;
            },
            .unexpected_value => {
                return error.UnexpectedArgument;
            },
        }
    }

    if (files_processed == 0) {
        var stdin_file = std.fs.File.stdin();
        const res = try processFile(&stdin_file);
        try printResult(opts, "", res);
        total.line_count += res.line_count;
        total.word_count += res.word_count;
        total.byte_count += res.byte_count;
        total.char_count += res.char_count;
        files_processed += 1;
    }

    if (files_processed > 1) {
        try printResult(opts, "total", total);
    }
}

const BUF_SIZE = 65536;
fn processFile(file: *std.fs.File) !Result {
    const num_cpu = std.Thread.getCpuCount() catch 1;

    if (num_cpu == 1) return processSingleThreaded(file);

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prev_chunk_end_state: u8 = State.WASSPACE;
    // List to store chunks and their results
    var chunks = try allocator.alloc(ChunkData, num_cpu);
    defer allocator.free(chunks);

    var states = try allocator.alloc(u8, num_cpu);
    defer allocator.free(states);

    // Store pointers to heap-allocated result arrays to avoid invalidation on ArrayList growth
    var end_state_results = try allocator.alloc([32]u8, num_cpu);
    defer allocator.free(end_state_results);

    var result_counts = try allocator.alloc(Result, num_cpu);
    defer allocator.free(result_counts);

    const table = gen_table();
    build_coalesce_table(&table);

    var total = Result{};

    // Read file into chunks and spawn workers immediately
    var wg = std.Thread.WaitGroup{};
    var i: usize = 0;
    var prev_char: u8 = ' ';
    var incomplete_loop = false;
    while (true) {
        if (i < num_cpu and !incomplete_loop) {
            var chunk = &chunks[i];
            const bytes_read = try file.read(&chunk.buffer);
            chunk.size = bytes_read;
            if (bytes_read == 0) {
                incomplete_loop = true;
                continue;
            }

            wg.start();
            const task = EndStateTask{
                .chunk = chunk.buffer[0..chunk.size],
                .results_ptr = &end_state_results[i],
                .wg = &wg,
                .prev_char = prev_char,
                .table = &coalesced_table,
                .uniques = &uniques,
            };
            try thread_pool.spawn(calc_end_states, .{task});
            prev_char = chunk.buffer[chunk.size - 1];

            i += 1;
        } else {
            // Every thread is busy, wait for them to finish
            thread_pool.waitAndWork(&wg);

            // var end = std.time.microTimestamp();
            // std.debug.print("First phase took {d} ms\n", .{@divTrunc(end - start, 1000)});
            // start = std.time.microTimestamp();
            wg.reset();

            // Now we can set the start states for each chunk
            // based on the end states of the previous chunks
            states[0] = prev_chunk_end_state;
            for (1..i) |j| {
                const prev_ch = if (j == 1) 0 else chunks[j - 2].buffer[chunks[j - 2].size - 1];
                const local_idx = global_to_local[prev_ch][states[j - 1]];

                states[j] = end_state_results[j - 1][local_idx];
            }
            const final_prev_char = chunks[i - 1].buffer[chunks[i - 1].size - 1];
            const final_local_idx = global_to_local[final_prev_char][states[i - 1]];

            prev_chunk_end_state = end_state_results[i - 1][final_local_idx];

            wg.startMany(i);

            // Now, calculate the results for each chunk with the correct start states
            for (0..i) |j| {
                const task = CountTask{
                    .chunk = chunks[j].buffer[0..chunks[j].size],
                    .start_state = states[j],
                    .results_ptr = &result_counts[j],
                    .wg = &wg,
                    .table = &table,
                };
                try thread_pool.spawn(countWorker, .{task});
            }

            thread_pool.waitAndWork(&wg);

            // end = std.time.microTimestamp();
            // std.debug.print("Ssecond phase took {d} ms\n", .{@divTrunc(end - start, 1000)});

            for (0..i) |j| {
                total.line_count += result_counts[j].line_count;
                total.word_count += result_counts[j].word_count;
                total.byte_count += result_counts[j].byte_count;
                total.char_count += result_counts[j].char_count;
            }

            wg.reset();
            i = 0;

            if (incomplete_loop) break;
        }
    }

    return total;
}

fn processSingleThreaded(file: *std.fs.File) !Result {
    var buf: [BUF_SIZE]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;
    return wc_dfa(reader);
}

fn printResult(opts: Opts, file: []const u8, result: Result) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    if (opts.count_lines) {
        try stdout.interface.print("{d} ", .{result.line_count});
    }
    if (opts.count_words) {
        try stdout.interface.print("{d} ", .{result.word_count});
    }
    if (opts.count_bytes) {
        try stdout.interface.print("{d} ", .{result.byte_count});
    }
    if (opts.count_chars) {
        try stdout.interface.print("{d} ", .{result.char_count});
    }
    try stdout.interface.print("{s}\n", .{file});
    try stdout.interface.flush();
}

const Result = struct {
    line_count: usize = 0,
    word_count: usize = 0,
    byte_count: usize = 0,
    char_count: usize = 0,
};

const Utf8Type = struct {
    DUO2_xx: u8 = 0,
    DUO2_C2: u8 = 1,
    TRI2_E0: u8 = 2,
    TRI2_E1: u8 = 3,
    TRI2_E2: u8 = 4,
    TRI2_E3: u8 = 5,
    TRI2_ED: u8 = 6,
    TRI2_EE: u8 = 7,
    TRI2_xx: u8 = 8,
    TRI3_E0_xx: u8 = 9,
    TRI3_E1_xx: u8 = 10,
    TRI3_E1_9a: u8 = 11,
    TRI3_E2_80: u8 = 12,
    TRI3_E2_81: u8 = 13,
    TRI3_E2_xx: u8 = 14,
    TRI3_E3_80: u8 = 15,
    TRI3_E3_81: u8 = 16,
    TRI3_E3_xx: u8 = 17,
    TRI3_Ed_xx: u8 = 18,
    TRI3_Ee_xx: u8 = 19,
    TRI3_xx_xx: u8 = 20,
    QUAD2_xx: u8 = 21,
    QUAD2_F0: u8 = 22,
    QUAD2_F4: u8 = 23,
    QUAD3_xx_xx: u8 = 24,
    QUAD3_F0_xx: u8 = 25,
    QUAD3_F4_xx: u8 = 26,
    QUAD4_xx_xx_xx: u8 = 27,
    QUAD4_F0_xx_xx: u8 = 28,
    QUAD4_F4_xx_xx: u8 = 29,
    ILLEGAL: u8 = 30,
}{};

// ILLEGAL is at index 30, so we can calculate:
// UWORD = USPACE + ILLEGAL + 1 = 4 + 30 + 1 = 35
// STATE_MAX = UWORD + ILLEGAL + 1 = 35 + 30 + 1 = 66
// There are a lot of states between USPACE, UWORD and STATE_MAX that are not represented here.
// These are the unicode multibyte states defined in Type.
const State = struct {
    WASSPACE: usize = 0,
    NEWLINE: usize = 1,
    NEWWORD: usize = 2,
    WASWORD: usize = 3,
    USPACE: usize = 4,
    UWORD: usize = 35,
    STATE_MAX: usize = 66,
}{};

pub fn build_first_byte_states(row: *[256]u8, base_state: u8, word_state: u8) void {
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        if ((b & 0x80) != 0) { // Starts with 1xxxxxxx
            if ((b & 0xE0) == 0xC0) {
                // 110x xxxx - unicode 2 byte sequence
                if (b < 0xC2) {
                    row[b] = base_state + @as(u8, Utf8Type.ILLEGAL);
                } else if (b == 0xC2) {
                    row[b] = base_state + @as(u8, Utf8Type.DUO2_C2);
                } else {
                    row[b] = base_state + @as(u8, Utf8Type.DUO2_xx);
                }
            } else if ((b & 0xF0) == 0xE0) {
                // 1110 xxxx - unicode 3 byte sequence
                switch (b) {
                    0xE0 => row[b] = base_state + @as(u8, Utf8Type.TRI2_E0),
                    0xE1 => row[b] = base_state + @as(u8, Utf8Type.TRI2_E1),
                    0xE2 => row[b] = base_state + @as(u8, Utf8Type.TRI2_E2),
                    0xE3 => row[b] = base_state + @as(u8, Utf8Type.TRI2_E3),
                    0xED => row[b] = base_state + @as(u8, Utf8Type.TRI2_ED),
                    0xEE => row[b] = base_state + @as(u8, Utf8Type.TRI2_EE),
                    else => row[b] = base_state + @as(u8, Utf8Type.TRI2_xx),
                }
            } else if ((b & 0xF8) == 0xF0) {
                // 1111 0xxx - unicode 4 byte sequence
                if (b >= 0xF5) {
                    row[b] = base_state + @as(u8, Utf8Type.ILLEGAL);
                } else if (b == 0xF0) {
                    row[b] = base_state + @as(u8, Utf8Type.QUAD2_F0);
                } else if (b == 0xF4) {
                    row[b] = base_state + @as(u8, Utf8Type.QUAD2_F4);
                } else {
                    row[b] = base_state + @as(u8, Utf8Type.QUAD2_xx);
                }
            } else {
                row[b] = base_state + @as(u8, Utf8Type.ILLEGAL);
            }
            // Unicode 1 byte sequences
        } else if (b == '\n') {
            row[b] = State.NEWLINE;
        } else if (std.ascii.isWhitespace(b)) {
            row[b] = State.WASSPACE;
        } else {
            row[b] = word_state;
        }
    }
}

const Table = [State.STATE_MAX][256]u8;

fn build_utf8_state_row(table: *Table, unicode_base: u8, id: u8, init_next: ?u8) void {
    var next: u8 = 0;
    const default_state = table[unicode_base + Utf8Type.ILLEGAL][0];
    if (init_next) |n| {
        next = unicode_base + n;
    } else {
        next = default_state;
    }

    @memcpy(&table[unicode_base + id], &table[unicode_base + Utf8Type.ILLEGAL]);

    for (0x80..0xC0) |i| {
        table[unicode_base + id][i] = next;
    }

    for (0xC0..0x100) |i| {
        table[unicode_base + id][i] = unicode_base + @as(u8, Utf8Type.ILLEGAL);
    }
}

/// Builds a state transition table for UTF-8 byte sequence validation.
/// The DFA tracks:
/// - UTF-8 multi-byte sequences (2, 3, and 4 byte sequences)
/// - Word boundaries (whitespace vs non-whitespace)
/// - Newlines
/// - Invalid UTF-8 sequences
fn build_unicode(table: *Table, base_state: u8, word_state: u8) void {
    // Set the illegal state for this unicode base area.
    // This will keep us in the same state if we encounter a malformed UTF-8 sequence.
    // And also act as a "default state" for other states to copy from.
    build_first_byte_states(&table[base_state + Utf8Type.ILLEGAL], base_state, word_state);

    // Two byte
    build_utf8_state_row(table, base_state, Utf8Type.DUO2_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.DUO2_C2, null);

    // Three byte
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_E0, Utf8Type.TRI3_E0_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_E1, Utf8Type.TRI3_E1_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_E2, Utf8Type.TRI3_E2_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_E3, Utf8Type.TRI3_E3_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_ED, Utf8Type.TRI3_Ed_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_EE, Utf8Type.TRI3_Ee_xx);
    build_utf8_state_row(table, base_state, Utf8Type.TRI2_xx, Utf8Type.TRI3_xx_xx);

    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E0_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E1_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E1_9a, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E2_80, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E2_81, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E2_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E3_80, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E3_81, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_E3_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_Ed_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_Ee_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.TRI3_xx_xx, null);

    table[base_state + Utf8Type.TRI2_E1][0x9a] = base_state + Utf8Type.TRI3_E1_9a;
    table[base_state + Utf8Type.TRI2_E2][0x80] = base_state + @as(u8, Utf8Type.TRI3_E2_80);
    table[base_state + Utf8Type.TRI2_E2][0x81] = base_state + @as(u8, Utf8Type.TRI3_E2_81);
    table[base_state + Utf8Type.TRI2_E3][0x80] = base_state + @as(u8, Utf8Type.TRI3_E3_80);
    table[base_state + Utf8Type.TRI2_E3][0x81] = base_state + @as(u8, Utf8Type.TRI3_E3_81);

    // Four byte
    build_utf8_state_row(table, base_state, Utf8Type.QUAD2_xx, Utf8Type.QUAD3_xx_xx);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD2_F0, Utf8Type.QUAD3_F0_xx);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD2_F4, Utf8Type.QUAD3_F4_xx);

    build_utf8_state_row(table, base_state, Utf8Type.QUAD3_xx_xx, Utf8Type.QUAD4_xx_xx_xx);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD3_F0_xx, Utf8Type.QUAD4_F0_xx_xx);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD3_F4_xx, Utf8Type.QUAD4_F4_xx_xx);

    build_utf8_state_row(table, base_state, Utf8Type.QUAD4_xx_xx_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD4_F0_xx_xx, null);
    build_utf8_state_row(table, base_state, Utf8Type.QUAD4_F4_xx_xx, null);

    // Mark unicode spaces
    if (c.iswspace(0x0085) != 0) {
        table[base_state + Utf8Type.DUO2_C2][0x85] = State.WASSPACE;
    }
    if (c.iswspace(0x00A0) != 0) {
        table[base_state + Utf8Type.DUO2_C2][0xA0] = State.WASSPACE;
    }
    if (c.iswspace(0x1680) != 0) {
        table[base_state + Utf8Type.TRI3_E1_9a][0x80] = State.WASSPACE;
    }
    for (0x2000..0x200c) |i| {
        if (c.iswspace(@as(c.wint_t, @intCast(i))) != 0) {
            table[base_state + Utf8Type.TRI3_E2_80][0x80 + (i & 0x6F)] = State.WASSPACE;
        }
    }

    if (c.iswspace(0x2028) != 0)
        table[base_state + Utf8Type.TRI3_E2_80][0xA8] = State.WASSPACE;
    if (c.iswspace(0x2029) != 0)
        table[base_state + Utf8Type.TRI3_E2_80][0xA9] = State.WASSPACE;
    if (c.iswspace(0x202F) != 0)
        table[base_state + Utf8Type.TRI3_E2_80][0xAF] = State.WASSPACE;
    if (c.iswspace(0x205F) != 0)
        table[base_state + Utf8Type.TRI3_E2_81][0x9F] = State.WASSPACE;
    if (c.iswspace(0x3000) != 0)
        table[base_state + Utf8Type.TRI3_E3_80][0x80] = State.WASSPACE;

    // Mark illegal sequences

    // The following need to be marked as illegal because they can
    // be represented with a shorter string. In other words,
    // 0xC0 0x81 is the same as 0x01, so needs to be marked as an
    // illegal sequence

    for (0x80..0xA0) |i| {
        table[base_state + Utf8Type.TRI2_E0][i] = base_state + @as(u8, Utf8Type.ILLEGAL);
    }
    for (0x80..0x90) |i| {
        table[base_state + Utf8Type.QUAD2_F0][i] = base_state + @as(u8, Utf8Type.ILLEGAL);
    }
    // Exceeds max possible size of unicode character
    for (0x90..0xC0) |i| {
        table[base_state + Utf8Type.QUAD2_F4][i] = base_state + @as(u8, Utf8Type.ILLEGAL);
    }
    // Surrogate space
    for (0xA0..0xC0) |i| {
        table[base_state + Utf8Type.TRI2_ED][i] = base_state + @as(u8, Utf8Type.ILLEGAL);
    }
}

const S = @Vector(32, u8);
const Uniques = [256][32]u8;
const GlobalToLocal = [256][State.STATE_MAX]u8;
const CoalescedTable = [256][256][32]u8;

var coalesced_table = std.mem.zeroes(CoalescedTable);
var global_to_local = std.mem.zeroes(GlobalToLocal);
var uniques: Uniques = std.mem.zeroes(Uniques);

pub fn build_coalesce_table(table: *const Table) void {
    // var uniques = [_][32]u8{[_]u8{0} ** 32} ** 256;
    var unique_counts = [_]usize{0} ** 256;
    // var global_to_local = std.mem.zeroes([256][State.STATE_MAX]u8);

    for (0..256) |ch| {
        for (0..State.STATE_MAX) |s| {
            const dest = table[s][ch];
            var found = false;
            for (uniques[ch]) |existing| {
                if (existing == dest) {
                    found = true;
                }
            }
            if (!found) {
                uniques[ch][unique_counts[ch]] = dest;
                global_to_local[ch][s] = @intCast(unique_counts[ch]);
                unique_counts[ch] += 1;
            }
        }
        if (unique_counts[ch] > 32) {
            std.debug.print("Too many unique states for byte {d}: {d}\n", .{ ch, unique_counts[ch] });
        }
    }

    for (0..256) |prev| {
        for (0..256) |curr| {
            for (0..32) |i| {
                const global_state = uniques[prev][i];
                const next_global = table[global_state][curr];

                var next_local: isize = -1;
                for (0..32) |j| {
                    if (uniques[curr][j] == next_global) {
                        next_local = @intCast(j);
                        break;
                    }
                }

                coalesced_table[prev][curr][i] = @intCast(next_local);
            }
        }
    }
    return;
}

pub fn gen_table() [State.STATE_MAX][256]u8 {
    @setEvalBranchQuota(10000);
    _ = c.setlocale(c.LC_ALL, "");
    var table: [State.STATE_MAX][256]u8 = undefined;
    // Row, base state, word state
    // In WASSPACE and NEWLINE states, non-whitespace ASCII goes to NEWWORD
    build_first_byte_states(&table[State.WASSPACE], State.USPACE, State.NEWWORD);
    build_first_byte_states(&table[State.NEWLINE], State.USPACE, State.NEWWORD);
    // In WASWORD and NEWWORD states, non-whitespace ASCII goes to WASWORD
    build_first_byte_states(&table[State.WASWORD], State.UWORD, State.WASWORD);
    build_first_byte_states(&table[State.NEWWORD], State.UWORD, State.WASWORD);
    // Unicode multi-byte sequences get their own states,
    // "USPACE" being multi-bytes sequences that started in WASSPACE or NEWLINE,
    // and "UWORD" being multi-byte sequences that started in WASWORD or NEWWORD.
    build_unicode(&table, State.USPACE, State.NEWWORD);
    build_unicode(&table, State.UWORD, State.WASWORD);
    return table;
}

pub fn wc_dfa(reader: *std.Io.Reader) !Result {
    const table = gen_table();
    var counts = [_]usize{0} ** State.STATE_MAX;
    var state: usize = State.WASSPACE;
    while (true) {
        const b = reader.takeByte() catch break;
        state = table[state][b];
        counts[state] += 1;
    }

    var byte_count: usize = 0;
    for (0..State.STATE_MAX) |i| {
        byte_count += counts[i];
    }

    return .{
        .line_count = counts[State.NEWLINE],
        .word_count = counts[State.NEWWORD],
        .char_count = counts[0] + counts[1] + counts[2] + counts[3],
        .byte_count = byte_count,
    };
}

test "wc_dfa counts lines, words, and bytes correctly" {
    const input = "Hello, 世界!\nThis is a test.\n";
    var reader = std.io.Reader.fixed(input);
    const result = wc_dfa(&reader);
    try std.testing.expectEqual(2, result.line_count);
    try std.testing.expectEqual(6, result.word_count);
    try std.testing.expectEqual(31, result.byte_count);
    try std.testing.expectEqual(27, result.char_count);
}
