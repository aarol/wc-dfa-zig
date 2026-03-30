const std = @import("std");
const dfa = @import("dfa.zig");

const CHUNK_SIZE = 2_000_003; // 2 MB + 3 bytes for UTF-8 overlap

const ChunkData = struct {
    buffer: [CHUNK_SIZE]u8,
    size: usize,

    fn lastByte(self: Task) u8 {
        return self.buffer[self.size - 1];
    }
};

const WorkerParams = struct {
    item_queue: *TaskQueue,
    free_queue: *TaskQueue,
    results_ptr: *dfa.Result,
    result_wg: *std.Thread.WaitGroup,
};

const Task = struct {
    chunk: ?*ChunkData,
    start_state: u8,
    table: *const dfa.Table,
};

pub fn processParallel(reader: *std.Io.Reader, allocator: std.mem.Allocator, num_cpu: usize) !dfa.Result {
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = num_cpu });
    defer thread_pool.deinit();

    // List to store chunks and their results
    const chunks = try allocator.alloc(ChunkData, num_cpu);
    defer allocator.free(chunks);

    var result_counts = try allocator.alloc(dfa.Result, num_cpu);
    defer allocator.free(result_counts);

    const table = dfa.gen_table();

    var item_queue = try TaskQueue.init(allocator, num_cpu);
    defer item_queue.deinit();
    var free_queue = try TaskQueue.init(allocator, num_cpu);
    defer free_queue.deinit();
    var result_wg = std.Thread.WaitGroup{};

    for (0..num_cpu) |i| {
        free_queue.push(Task{
            .chunk = &chunks[i],
            .table = &table,
            .start_state = 0,
        });

        try thread_pool.spawn(worker, .{WorkerParams{
            .item_queue = &item_queue,
            .free_queue = &free_queue,
            .results_ptr = &result_counts[i],
            .result_wg = &result_wg,
        }});
    }

    var num_bytes: usize = 0;
    var start_state: u8 = dfa.State.WASSPACE;

    // Read file into chunks and spawn workers immediately
    while (true) {
        var task = free_queue.pop();
        var bytes_read = try reader.readSliceShort(task.chunk.?.buffer[0 .. CHUNK_SIZE - 3]);

        if (bytes_read == 0) {
            break;
        }

        const last_char_len, const overflow = lastCharLenAndOverflow(task.chunk.?.buffer[0..bytes_read]);
        if (overflow != 0) {
            // Read the overflow bytes to ensure we don't split a UTF-8 character
            bytes_read += try reader.readSliceShort(task.chunk.?.buffer[bytes_read .. bytes_read + overflow]);
        }

        task.chunk.?.size = bytes_read;
        num_bytes += bytes_read;

        task.start_state = start_state;

        item_queue.push(task);

        // For the next chunk, determine the starting state based on the last character of the current chunk
        const last_char = std.unicode.utf8Decode(task.chunk.?.buffer[(task.chunk.?.size - last_char_len)..task.chunk.?.size]) catch 0;
        if (dfa.isWhitespace(last_char)) {
            start_state = dfa.State.WASSPACE;
        } else {
            start_state = dfa.State.WASWORD;
        }
    }
    result_wg.startMany(num_cpu);

    item_queue.finish(); // Signal workers to finish after all tasks are enqueued

    result_wg.wait(); // Wait for all workers to finish processing

    var total = dfa.Result{};
    for (result_counts) |res| {
        total.word_count += res.word_count;
        total.line_count += res.line_count;
        total.char_count += res.char_count;
    }
    total.byte_count = num_bytes;

    return total;
}

fn worker(params: WorkerParams) void {
    defer params.result_wg.finish();

    var counts = [_]usize{0} ** dfa.State.STATE_MAX;
    while (true) {
        const task = params.item_queue.pop();
        if (task.chunk == null) {
            break; // No more tasks, exit worker
        }

        var state = task.start_state;
        for (task.chunk.?.buffer[0..task.chunk.?.size]) |b| {
            state = task.table[state][b];
            counts[state] += 1;
        }
        params.free_queue.push(task);
    }

    params.results_ptr.* = dfa.Result{
        .word_count = counts[dfa.State.NEWWORD],
        .line_count = counts[dfa.State.NEWLINE],
        .char_count = counts[0] + counts[1] + counts[2] + counts[3],
        .byte_count = 0, // Calculated in main thread
    };
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

const atomic = std.atomic;

const TaskQueue = struct {
    const Self = @This();
    buffer: []Task,
    allocator: std.mem.Allocator,
    write_idx: atomic.Value(usize) = .init(0),
    read_idx: atomic.Value(usize) = .init(0),

    items_sem: std.Thread.Semaphore,
    spaces_sem: std.Thread.Semaphore,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        return Self{
            .allocator = allocator,
            .buffer = try allocator.alloc(Task, capacity),
            .items_sem = std.Thread.Semaphore{ .permits = 0 },
            .spaces_sem = std.Thread.Semaphore{ .permits = capacity },
        };
    }

    pub fn push(self: *Self, task: Task) void {
        self.spaces_sem.wait();
        const w = self.write_idx.fetchAdd(1, .monotonic);
        self.buffer[w % self.buffer.len] = task;
        self.items_sem.post();
    }

    pub fn pop(self: *Self) Task {
        while (true) {
            self.items_sem.wait();
            const r = self.read_idx.load(.monotonic);
            // Try to claim the index
            if (self.read_idx.cmpxchgWeak(r, r + 1, .acquire, .monotonic)) |_| {
                self.items_sem.post(); // Lost race, put permit back
                continue;
            }
            const task = self.buffer[r % self.buffer.len];
            self.spaces_sem.post();
            return task;
        }
    }

    pub fn finish(self: *Self) void {
        for (0..self.buffer.len) |_| {
            self.push(Task{
                .chunk = null,
                .start_state = 0,
                .table = undefined,
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }
};

test "lastIndexUtf8Overflow" {
    var input = "Tent ⛺";
    const len = input.len;
    try std.testing.expectEqual(.{ 3, 0 }, lastCharLenAndOverflow(input[0..len]));
    try std.testing.expectEqual(.{ 3, 1 }, lastCharLenAndOverflow(input[0 .. len - 1]));
    try std.testing.expectEqual(.{ 3, 2 }, lastCharLenAndOverflow(input[0 .. len - 2]));
    try std.testing.expectEqual(.{ 1, 0 }, lastCharLenAndOverflow(input[0 .. len - 3]));
}
