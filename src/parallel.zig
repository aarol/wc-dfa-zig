const std = @import("std");
const dfa = @import("dfa.zig");

const CHUNK_SIZE = 2_000_000;

const ChunkData = struct {
    buffer: [CHUNK_SIZE]u8,
    size: usize,

    fn lastByte(self: ChunkData) u8 {
        return self.buffer[self.size - 1];
    }
};

const CountTask = struct {
    chunk: []const u8,
    start_state: u8,
    results_ptr: *dfa.Result,
    wg: *std.Thread.WaitGroup,
    table: *const dfa.Table,
};

const ChunkProcessingTask = struct {
    chunk: []const u8,
    results_ptr: *[32]u8,
    wg: *std.Thread.WaitGroup,
    table: *const dfa.CoalescedTable,
    uniques: *const dfa.Uniques,
    prev_char: u8,
};

const S = @Vector(32, u8);

fn gather(slice: S, index: S) S {
    // This will be optimized to a series of SIMD shuffle instructions
    var result: [32]u8 = undefined;
    comptime var vec_i = 0;
    inline while (vec_i < 32) : (vec_i += 1) {
        result[vec_i] = slice[index[vec_i]];
    }
    return result;
}

/// From every possible starting state, calculates what the end state would be for the given chunk.
/// Thanks to range coalescing, there are only 32 possible starting states.
fn chunkWorker(task: ChunkProcessingTask) void {
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

fn countWorker(task: CountTask) void {
    defer task.wg.finish();

    var counts = [_]usize{0} ** dfa.State.STATE_MAX;
    var state = task.start_state;
    for (task.chunk) |b| {
        state = task.table[state][b];
        counts[state] += 1;
    }

    task.results_ptr.line_count = counts[dfa.State.NEWLINE];
    task.results_ptr.word_count = counts[dfa.State.NEWWORD];
    task.results_ptr.char_count = counts[0] + counts[1] + counts[2] + counts[3];

    var byte_count: usize = 0;
    for (0..dfa.State.STATE_MAX) |j| {
        byte_count += counts[j];
    }
    task.results_ptr.byte_count = byte_count;
}

pub fn processParallel(reader: *std.Io.Reader) !dfa.Result {
    const num_cpu = std.Thread.getCpuCount() catch 1;
    // const num_cpu = 1;

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = std.heap.page_allocator });
    defer thread_pool.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prev_chunk_end_state: u8 = dfa.State.WASSPACE;

    // List to store chunks and their results
    var chunks = try allocator.alloc(ChunkData, num_cpu);
    defer allocator.free(chunks);

    var states = try allocator.alloc(u8, num_cpu);
    defer allocator.free(states);

    // Store pointers to heap-allocated result arrays. They will be set to undefined first.
    var end_state_results = try allocator.alloc([32]u8, num_cpu);
    defer allocator.free(end_state_results);

    var result_counts = try allocator.alloc(dfa.Result, num_cpu);
    defer allocator.free(result_counts);

    const table = dfa.gen_table();
    dfa.build_coalesce_table(&table);

    var total = dfa.Result{};

    var wg = std.Thread.WaitGroup{};
    var i: usize = 0;
    var prev_char: u8 = ' ';
    var incomplete_loop = false;

    // Read file into chunks and spawn workers immediately
    while (true) {
        if (i < num_cpu and !incomplete_loop) {
            var chunk = &chunks[i];
            const bytes_read = try reader.readSliceShort(&chunk.buffer);
            chunk.size = bytes_read;

            if (bytes_read == 0) {
                incomplete_loop = true;
                continue;
            }

            wg.start();
            const task = ChunkProcessingTask{
                .chunk = chunk.buffer[0..chunk.size],
                .results_ptr = &end_state_results[i],
                .wg = &wg,
                .prev_char = prev_char,
                .table = &dfa.coalesced_table,
                .uniques = &dfa.uniques,
            };
            try thread_pool.spawn(chunkWorker, .{task});
            prev_char = chunk.buffer[chunk.size - 1];
            i += 1;
        } else {
            // Every thread is busy, wait for them to finish
            thread_pool.waitAndWork(&wg);
            wg.reset();

            if (i == 0) break;

            // Now we can set the start states for each chunk
            // based on the end states of the previous chunks
            states[0] = prev_chunk_end_state;
            for (1..i) |j| {
                const prev_ch = chunks[j - 1].lastByte();
                const local_idx = dfa.global_to_local[prev_ch][states[j - 1]];
                states[j] = end_state_results[j - 1][local_idx];
            }

            const final_prev_char = chunks[i - 1].lastByte();
            const final_local_idx = dfa.global_to_local[final_prev_char][states[i - 1]];
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
