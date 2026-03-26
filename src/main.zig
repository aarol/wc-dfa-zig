const std = @import("std");
const parg = @import("parg");
const dfa = @import("dfa.zig");
const parallel = @import("parallel.zig");

const Opts = packed struct {
    count_lines: bool = false,
    count_words: bool = false,
    count_bytes: bool = false,
    count_chars: bool = false,
};

const BUF_SIZE = 65536;

pub fn main() !void {
    var opts = Opts{};

    var total = dfa.Result{};

    const it = std.process.args();
    var p = parg.parse(it, .{});
    defer p.deinit();

    _ = p.nextValue();

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

fn processFile(file: *std.fs.File) !dfa.Result {
    var buf: [BUF_SIZE]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    const num_cpu = std.Thread.getCpuCount() catch 1;
    if (num_cpu == 1) return dfa.wc_dfa(reader);
    return parallel.processParallel(reader);
}

fn printResult(opts: Opts, file: []const u8, result: dfa.Result) !void {
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

test "wc_dfa counts correctly" {
    const input = "Hello, 世界!\nThis is a test.\n";
    var reader = std.io.Reader.fixed(input);
    const result = try dfa.wc_dfa(&reader);
    try std.testing.expectEqual(2, result.line_count);
    try std.testing.expectEqual(6, result.word_count);
    try std.testing.expectEqual(31, result.byte_count);
    try std.testing.expectEqual(27, result.char_count);
}

test "parallel matches wc_dfa" {
    const n_repeats = 100000;
    const input =
        "Hello, 世界!\nThis is a test.\nSecond line with unicode: café\n";

    const total_len = input.len * n_repeats;
    var data = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(data);
    var offset: usize = 0;
    for (0..n_repeats) |_| {
        @memcpy(data[offset .. offset + input.len], input);
        offset += input.len;
    }
    var reader = std.io.Reader.fixed(data);

    const parallel_result = try parallel.processParallel(&reader);

    reader = std.io.Reader.fixed(data);
    const expected = try dfa.wc_dfa(&reader);

    try std.testing.expectEqual(expected.line_count, parallel_result.line_count);
    try std.testing.expectEqual(expected.word_count, parallel_result.word_count);
    try std.testing.expectEqual(expected.byte_count, parallel_result.byte_count);
    try std.testing.expectEqual(expected.char_count, parallel_result.char_count);
}
