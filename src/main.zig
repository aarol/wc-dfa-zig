const std = @import("std");

const c = @cImport({
    @cInclude("wctype.h");
    @cInclude("locale.h");
});

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name
    var result = Result{
        .line_count = 0,
        .word_count = 0,
        .byte_count = 0,
    };
    var processed_files: usize = 0;
    while (args.next()) |arg| {
        var file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
        defer file.close();
        var buf: [65536]u8 = undefined;
        var file_reader = file.reader(&buf);
        const reader = &file_reader.interface;
        const res = wc_dfa(reader);
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
        const res = wc_dfa(reader);
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

const Type = struct {
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
// There are a lot of states between USPACE and UWORD that are not represented here.
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

pub fn build_basic(row: *[256]u8, default_state: u8, ubase: u8) void {
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        if ((b & 0x80) != 0) {
            if ((b & 0xE0) == 0xC0) {
                // 110x xxxx - unicode 2 byte sequence
                if (b < 0xC2) {
                    row[b] = ubase + @as(u8, Type.ILLEGAL);
                } else if (b == 0xC2) {
                    row[b] = ubase + @as(u8, Type.DUO2_C2);
                } else {
                    row[b] = ubase + @as(u8, Type.DUO2_xx);
                }
            } else if ((b & 0xF0) == 0xE0) {
                // 1110 xxxx - unicode 3 byte sequence
                switch (b) {
                    0xE0 => row[b] = ubase + @as(u8, Type.TRI2_E0),
                    0xE1 => row[b] = ubase + @as(u8, Type.TRI2_E1),
                    0xE2 => row[b] = ubase + @as(u8, Type.TRI2_E2),
                    0xE3 => row[b] = ubase + @as(u8, Type.TRI2_E3),
                    0xED => row[b] = ubase + @as(u8, Type.TRI2_ED),
                    0xEE => row[b] = ubase + @as(u8, Type.TRI2_EE),
                    else => row[b] = ubase + @as(u8, Type.TRI2_xx),
                }
            } else if ((b & 0xF8) == 0xF0) {
                if (b >= 0xF5) {
                    row[b] = ubase + @as(u8, Type.ILLEGAL);
                } else if (b == 0xF0) {
                    row[b] = ubase + @as(u8, Type.QUAD2_F0);
                } else if (b == 0xF4) {
                    row[b] = ubase + @as(u8, Type.QUAD2_F4);
                } else {
                    row[b] = ubase + @as(u8, Type.QUAD2_xx);
                }
            } else {
                row[b] = ubase + @as(u8, Type.ILLEGAL);
            }
        } else if (b == '\n') {
            row[b] = State.NEWLINE;
        } else if (std.ascii.isWhitespace(b)) {
            row[b] = State.WASSPACE;
        } else {
            row[b] = default_state;
        }
    }
}

const Table = [State.STATE_MAX][256]u8;

fn build_WASSPACE(row: *[256]u8) void {
    build_basic(row, State.NEWWORD, State.USPACE);
}

fn build_WASWORD(row: *[256]u8) void {
    build_basic(row, State.WASWORD, State.UWORD);
}

fn build_urow(table: *Table, ubase: u8, id: u8, init_next: u8) void {
    var next: u8 = init_next;
    const default_state = table[ubase + Type.ILLEGAL][0];
    if (next == 0) {
        next = default_state;
    } else {
        next = ubase + next;
    }

    @memcpy(&table[ubase + id], &table[ubase + Type.ILLEGAL]);

    for (0x80..0xC0) |i| {
        table[ubase + id][i] = next;
    }

    for (0xC0..0x100) |i| {
        table[ubase + id][i] = ubase + @as(u8, Type.ILLEGAL);
    }
}

fn build_unicode(table: *Table, default_state: u8, ubase: u8) void {
    build_basic(&table[ubase + Type.ILLEGAL], default_state, ubase);

    // Two byte
    build_urow(table, ubase, Type.DUO2_xx, 0);
    build_urow(table, ubase, Type.DUO2_C2, 0);

    // Three byte
    build_urow(table, ubase, Type.TRI2_E0, Type.TRI3_E0_xx);
    build_urow(table, ubase, Type.TRI2_E1, Type.TRI3_E1_xx);
    build_urow(table, ubase, Type.TRI2_E2, Type.TRI3_E2_xx);
    build_urow(table, ubase, Type.TRI2_E3, Type.TRI3_E3_xx);
    build_urow(table, ubase, Type.TRI2_ED, Type.TRI3_Ed_xx);
    build_urow(table, ubase, Type.TRI2_EE, Type.TRI3_Ee_xx);
    build_urow(table, ubase, Type.TRI2_xx, Type.TRI3_xx_xx);

    build_urow(table, ubase, Type.TRI3_E0_xx, 0);
    build_urow(table, ubase, Type.TRI3_E1_xx, 0);
    build_urow(table, ubase, Type.TRI3_E1_9a, 0);
    build_urow(table, ubase, Type.TRI3_E2_80, 0);
    build_urow(table, ubase, Type.TRI3_E2_81, 0);
    build_urow(table, ubase, Type.TRI3_E2_xx, 0);
    build_urow(table, ubase, Type.TRI3_E3_80, 0);
    build_urow(table, ubase, Type.TRI3_E3_81, 0);
    build_urow(table, ubase, Type.TRI3_E3_xx, 0);
    build_urow(table, ubase, Type.TRI3_Ed_xx, 0);
    build_urow(table, ubase, Type.TRI3_Ee_xx, 0);
    build_urow(table, ubase, Type.TRI3_xx_xx, 0);

    table[ubase + Type.TRI2_E1][0x9a] = ubase + Type.TRI3_E1_9a;
    table[ubase + Type.TRI2_E2][0x80] = ubase + @as(u8, Type.TRI3_E2_80);
    table[ubase + Type.TRI2_E2][0x81] = ubase + @as(u8, Type.TRI3_E2_81);
    table[ubase + Type.TRI2_E3][0x80] = ubase + @as(u8, Type.TRI3_E3_80);
    table[ubase + Type.TRI2_E3][0x81] = ubase + @as(u8, Type.TRI3_E3_81);

    // Four byte
    build_urow(table, ubase, Type.QUAD2_xx, Type.QUAD3_xx_xx);
    build_urow(table, ubase, Type.QUAD2_F0, Type.QUAD3_F0_xx);
    build_urow(table, ubase, Type.QUAD2_F4, Type.QUAD3_F4_xx);

    build_urow(table, ubase, Type.QUAD3_xx_xx, Type.QUAD4_xx_xx_xx);
    build_urow(table, ubase, Type.QUAD3_F0_xx, Type.QUAD4_F0_xx_xx);
    build_urow(table, ubase, Type.QUAD3_F4_xx, Type.QUAD4_F4_xx_xx);

    build_urow(table, ubase, Type.QUAD4_xx_xx_xx, 0);
    build_urow(table, ubase, Type.QUAD4_F0_xx_xx, 0);
    build_urow(table, ubase, Type.QUAD4_F4_xx_xx, 0);

    // Mark unicode spaces
    if (c.iswspace(0x0085) != 0) {
        table[ubase + Type.DUO2_C2][0x85] = State.WASSPACE;
    }
    if (c.iswspace(0x00A0) != 0) {
        table[ubase + Type.DUO2_C2][0xA0] = State.WASSPACE;
    }
    if (c.iswspace(0x1680) != 0) {
        table[ubase + Type.TRI3_E1_9a][0x80] = State.WASSPACE;
    }
    for (0x2000..0x200c) |i| {
        if (c.iswspace(@as(c.wint_t, @intCast(i))) != 0) {
            table[ubase + Type.TRI3_E2_80][0x80 + (i & 0x6F)] = State.WASSPACE;
        }
    }

    if (c.iswspace(0x2028) != 0)
        table[ubase + Type.TRI3_E2_80][0xA8] = State.WASSPACE;
    if (c.iswspace(0x2029) != 0)
        table[ubase + Type.TRI3_E2_80][0xA9] = State.WASSPACE;
    if (c.iswspace(0x202F) != 0)
        table[ubase + Type.TRI3_E2_80][0xAF] = State.WASSPACE;
    if (c.iswspace(0x205F) != 0)
        table[ubase + Type.TRI3_E2_81][0x9F] = State.WASSPACE;
    if (c.iswspace(0x3000) != 0)
        table[ubase + Type.TRI3_E3_80][0x80] = State.WASSPACE;

    // Mark illegal sequences

    // The following need to be marked as illegal because they can
    // be represented with a shorter string. In other words,
    // 0xC0 0x81 is the same as 0x01, so needs to be marked as an
    // illegal sequence

    for (0x80..0xA0) |i| {
        table[ubase + Type.TRI2_E0][i] = ubase + @as(u8, Type.ILLEGAL);
    }
    for (0x80..0x90) |i| {
        table[ubase + Type.QUAD2_F0][i] = ubase + @as(u8, Type.ILLEGAL);
    }
    // Exceeds max possible size of unicode character
    for (0x90..0xC0) |i| {
        table[ubase + Type.QUAD2_F4][i] = ubase + @as(u8, Type.ILLEGAL);
    }
    // Surrogate space
    for (0xA0..0xC0) |i| {
        table[ubase + Type.TRI2_ED][i] = ubase + @as(u8, Type.ILLEGAL);
    }
}

pub fn gen_table() [State.STATE_MAX][256]u8 {
    @setEvalBranchQuota(10000);
    _ = c.setlocale(c.LC_ALL, "");
    var table: [State.STATE_MAX][256]u8 = undefined;
    build_WASSPACE(&table[State.WASSPACE]);
    build_WASSPACE(&table[State.NEWLINE]);
    build_WASWORD(&table[State.WASWORD]);
    build_WASWORD(&table[State.NEWWORD]);
    build_unicode(&table, State.NEWWORD, State.USPACE);
    build_unicode(&table, State.WASWORD, State.UWORD);
    return table;
}

pub fn wc_dfa(reader: *std.Io.Reader) Result {
    const table = gen_table();

    var counts = [_]usize{0} ** State.STATE_MAX;
    var state: usize = State.WASSPACE;
    while (true) {
        const b = reader.takeByte() catch break;
        state = table[state][b];
        counts[state] += 1;
    }
    return .{
        .line_count = counts[State.NEWLINE],
        .word_count = counts[State.NEWWORD],
        .byte_count = counts[0] + counts[1] + counts[2] + counts[3],
    };
}
