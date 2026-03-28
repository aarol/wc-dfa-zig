const std = @import("std");
const dfa = @import("dfa.zig");

const CHUNK_SIZE = 2_000_003; //3 bytes for UTF-8 overlap

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

pub fn processParallel(reader: *std.Io.Reader, allocator: std.mem.Allocator, num_cpu: usize) !dfa.Result {
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = num_cpu });
    defer thread_pool.deinit();

    // List to store chunks and their results
    var chunks = try allocator.alloc(ChunkData, num_cpu);
    defer allocator.free(chunks);

    var result_counts = try allocator.alloc(dfa.Result, num_cpu);
    defer allocator.free(result_counts);

    const table = dfa.gen_table();

    var total = dfa.Result{};

    var wg = std.Thread.WaitGroup{};
    var i: usize = 0;
    // var expected_end_state: u8 = dfa.State.WASSPACE;
    var prev_state: u8 = dfa.State.WASSPACE;
    var incomplete_loop = false;

    // Read file into chunks and spawn workers immediately
    while (true) {
        if (i < num_cpu and !incomplete_loop) {
            var chunk = &chunks[i];
            var bytes_read = try reader.readSliceShort(chunk.buffer[0 .. CHUNK_SIZE - 3]);

            if (bytes_read == 0) {
                incomplete_loop = true;
                continue;
            }

            const last_char_len, const overflow = lastCharLenAndOverflow(chunk.buffer[0..bytes_read]);
            if (overflow != 0) {
                // Read the overflow bytes to ensure we don't split a UTF-8 character
                bytes_read += try reader.readSliceShort(chunk.buffer[bytes_read .. bytes_read + overflow]);
            }

            chunk.size = bytes_read;

            wg.start();
            const task = CountTask{
                .chunk = chunk.buffer[0..chunk.size],
                .results_ptr = &result_counts[i],
                .start_state = prev_state,
                .table = &table,
                .wg = &wg,
            };
            try thread_pool.spawn(countWorker, .{task});

            // For the next chunk, determine the starting state based on the last character of the current chunk
            const last_char = std.unicode.utf8Decode(chunk.buffer[(chunk.size - last_char_len)..chunk.size]) catch 0;
            if (dfa.isWhitespace(last_char)) {
                prev_state = dfa.State.WASSPACE;
            } else {
                prev_state = dfa.State.WASWORD;
            }

            i += 1;
        } else {
            // Every thread is busy, wait for them to finish
            thread_pool.waitAndWork(&wg);
            wg.reset();

            if (i == 0) break;

            for (0..i) |j| {
                total.line_count += result_counts[j].line_count;
                total.word_count += result_counts[j].word_count;
                total.byte_count += result_counts[j].byte_count;
                total.char_count += result_counts[j].char_count;
            }

            i = 0;
            if (incomplete_loop) break;
        }
    }

    return total;
}

// Calculates the length of the last UTF-8 character and any how many bytes it overflows the buffer.
fn lastCharLenAndOverflow(buffer: []const u8) struct { usize, usize } {
    const last_idx = buffer.len - 1;
    for (0..4) |i| {
        const byte = buffer[last_idx - i];
        const blen = std.unicode.utf8ByteSequenceLength(byte) catch {
            continue;
        };
        return .{ blen, blen - i - 1 };
    }
    return .{ 0, 0 };
}

test "lastIndexUtf8Overflow" {
    var input = "Tent ⛺";
    const len = input.len;
    try std.testing.expectEqual(.{ 3, 0 }, lastCharLenAndOverflow(input[0..len]));
    try std.testing.expectEqual(.{ 3, 1 }, lastCharLenAndOverflow(input[0 .. len - 1]));
    try std.testing.expectEqual(.{ 3, 2 }, lastCharLenAndOverflow(input[0 .. len - 2]));
    try std.testing.expectEqual(.{ 1, 0 }, lastCharLenAndOverflow(input[0 .. len - 3]));
}
