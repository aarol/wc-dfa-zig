const std = @import("std");

const Result = @import("dfa.zig").Result;

const State = struct {
    whitespace: usize = 0,
    newline: usize = 1,
    word: usize = 2,
    in_word: usize = 3,
}{};
const Type = struct {
    character: usize = 0,
    whitespace: usize = 1,
    newline: usize = 2,
}{};

pub fn gen_transition_table() [4][3]u8 {
    var table: [4][3]u8 = undefined;

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

pub fn wc_simple(reader: *std.Io.Reader) Result {
    const table = gen_transition_table();
    const column = gen_char_type_table();

    var counts = [_]usize{0} ** 4;
    var state: usize = State.whitespace;
    while (true) {
        const b = reader.takeByte() catch break;
        state = table[state][column[b]];
        counts[state] += 1;
    }

    return .{
        .line_count = counts[State.newline],
        .word_count = counts[State.word],
        .char_count = 0,
        .byte_count = counts[0] + counts[1] + counts[2] + counts[3],
    };
}
