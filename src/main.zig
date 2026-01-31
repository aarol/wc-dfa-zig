const std = @import("std");

pub fn main() !void {
    var wc_fn = &wc_dfa;
    var args = std.process.args();
    _ = args.next(); // skip program name
    var result = Result{
        .line_count = 0,
        .word_count = 0,
        .byte_count = 0,
    };
    var processed_files: usize = 0;
    while (args.next()) |arg| {
        std.debug.print("Processing file: {s}\n", .{arg});
        if (std.mem.eql(u8, arg, "--ref")) {
            wc_fn = &wc_ref;
            continue;
        }
        var file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
        defer file.close();
        var buf: [65536]u8 = undefined;
        var file_reader = file.reader(&buf);
        const reader = &file_reader.interface;
        const res = wc_fn(reader);
        result.line_count += res.line_count;
        result.word_count += res.word_count;
        result.byte_count += res.byte_count;
        processed_files += 1;
    }

    if (processed_files == 0) {
        var stdin_file = std.fs.File.stdin();
        var buf: [65536]u8 = undefined;
        var stdin = stdin_file.reader(&buf);
        const reader = &stdin.interface;
        const res = wc_fn(reader);
        result.line_count += res.line_count;
        result.word_count += res.word_count;
        result.byte_count += res.byte_count;
    }

    var stdout_buf = [_]u8{0} ** 65536;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.print("{d} {d} {d}\n", .{ result.line_count, result.word_count, result.byte_count });
    try stdout.interface.flush();
}

const Result = struct {
    line_count: usize,
    word_count: usize,
    byte_count: usize,
};

const State = struct { whitespace: usize = 0, newline: usize = 1, word: usize = 2, in_word: usize = 3 }{};
const Type = struct { character: usize = 0, whitespace: usize = 1, newline: usize = 2 }{};

pub fn gen_transition_table() [4][3]u8 {
    var table: [4][3]u8 = [4][3]u8{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };

    table[State.whitespace][Type.character] = State.word;
    table[State.whitespace][Type.whitespace] = State.whitespace;
    table[State.whitespace][Type.newline] = State.newline;

    table[State.newline][Type.character] = State.word;
    table[State.newline][Type.whitespace] = State.whitespace;
    table[State.newline][Type.newline] = State.newline;

    table[State.word][Type.character] = State.in_word;
    table[State.word][Type.whitespace] = State.whitespace;
    table[State.word][Type.newline] = State.newline;

    table[State.in_word][Type.character] = State.in_word;
    table[State.in_word][Type.whitespace] = State.whitespace;
    table[State.in_word][Type.newline] = State.newline;

    return table;
}

fn gen_char_type_table() [256]u8 {
    // Default to character
    var column: [256]u8 = [_]u8{Type.character} ** 256;
    for (0..256) |b| {
        if (std.ascii.isWhitespace(@intCast(b))) {
            column[b] = Type.whitespace;
        }
        if (b == '\n') {
            column[b] = Type.newline;
        }
    }
    return column;
}

pub fn wc_dfa(reader: *std.Io.Reader) Result {
    const table = comptime gen_transition_table();
    const column = comptime gen_char_type_table();

    var counts = [4]usize{ 0, 0, 0, 0 };
    var state: usize = 0;
    while (true) {
        const b = reader.takeByte() catch break;
        state = table[state][column[b]];
        counts[state] += 1;
    }
    return .{
        .line_count = counts[1],
        .word_count = counts[2],
        .byte_count = counts[0] + counts[1] + counts[2] + counts[3],
    };
}

pub fn wc_ref(reader: *std.Io.Reader) Result {
    var line_count: usize = 0;
    var word_count: usize = 0;
    var byte_count: usize = 0;

    var in_word: bool = false;

    while (true) {
        const b = reader.takeByte() catch break;
        byte_count += 1;
        switch (b) {
            '\n' => {
                line_count += 1;
                in_word = false;
            },
            '\r', '\t', ' ' => {
                in_word = false;
            },
            else => {
                const in_word2 = !std.ascii.isWhitespace(b);
                if (in_word2 and !in_word) {
                    word_count += 1;
                }
                in_word = in_word2;
            },
        }
    }
    return Result{
        .line_count = line_count,
        .word_count = word_count,
        .byte_count = byte_count,
    };
}

test "wc_dfa works as expected" {
    const test_data = "Hello, World!\nThis is a test.\n";
    var buffer: [64]u8 = undefined;
    var mem_file = std.testing.Reader.init(&buffer, &.{.{ .buffer = test_data }});
    const reader = &mem_file.interface;
    const result = wc_dfa(reader);
    try std.testing.expect(result.line_count == 2);
    try std.testing.expect(result.word_count == 6);
    try std.testing.expect(result.byte_count == test_data.len);
}
