const std = @import("std");

pub const Result = struct {
    line_count: usize = 0,
    word_count: usize = 0,
    byte_count: usize = 0,
    char_count: usize = 0,
};

pub fn wc_dfa(reader: *std.Io.Reader) Result {
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

const Utf8State = struct {
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

// There are a lot of states between USPACE, UWORD and STATE_MAX that are not represented here.
// These are the unicode multibyte states defined in Type.
pub const State = struct {
    WASSPACE: usize = 0,
    NEWLINE: usize = 1,
    NEWWORD: usize = 2,
    WASWORD: usize = 3,
    USPACE: usize = 4,
    UWORD: usize = 35, // State.USPACE + Utf8State.ILLEGAL + 1
    STATE_MAX: usize = 66, //  State.UWORD + Utf8State.ILLEGAL + 1,
}{};

pub fn gen_table() [State.STATE_MAX][256]u8 {
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

pub fn build_first_byte_states(row: *[256]u8, base_state: u8, word_state: u8) void {
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        if ((b & 0x80) != 0) {
            if ((b & 0xE0) == 0xC0) {
                // 110x xxxx - unicode 2 byte sequence
                if (b < 0xC2) {
                    row[b] = base_state + Utf8State.ILLEGAL;
                } else if (b == 0xC2) {
                    row[b] = base_state + Utf8State.DUO2_C2;
                } else {
                    row[b] = base_state + Utf8State.DUO2_xx;
                }
            } else if ((b & 0xF0) == 0xE0) {
                // 1110 xxxx - unicode 3 byte sequence
                switch (b) {
                    0xE0 => row[b] = base_state + Utf8State.TRI2_E0,
                    0xE1 => row[b] = base_state + Utf8State.TRI2_E1,
                    0xE2 => row[b] = base_state + Utf8State.TRI2_E2,
                    0xE3 => row[b] = base_state + Utf8State.TRI2_E3,
                    0xED => row[b] = base_state + Utf8State.TRI2_ED,
                    0xEE => row[b] = base_state + Utf8State.TRI2_EE,
                    else => row[b] = base_state + Utf8State.TRI2_xx,
                }
            } else if ((b & 0xF8) == 0xF0) {
                // 1111 0xxx - unicode 4 byte sequence
                if (b >= 0xF5) {
                    row[b] = base_state + Utf8State.ILLEGAL;
                } else if (b == 0xF0) {
                    row[b] = base_state + Utf8State.QUAD2_F0;
                } else if (b == 0xF4) {
                    row[b] = base_state + Utf8State.QUAD2_F4;
                } else {
                    row[b] = base_state + Utf8State.QUAD2_xx;
                }
            } else {
                row[b] = base_state + Utf8State.ILLEGAL;
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

pub const Table = [State.STATE_MAX][256]u8;

fn build_utf8_state_row(table: *Table, unicode_base: u8, id: u8, init_next: ?u8) void {
    var next: u8 = 0;
    const default_state = table[unicode_base + Utf8State.ILLEGAL][0];
    if (init_next) |n| {
        next = unicode_base + n;
    } else {
        next = default_state;
    }

    @memcpy(&table[unicode_base + id], &table[unicode_base + Utf8State.ILLEGAL]);

    for (0x80..0xC0) |i| {
        table[unicode_base + id][i] = next;
    }

    for (0xC0..0x100) |i| {
        table[unicode_base + id][i] = unicode_base + Utf8State.ILLEGAL;
    }
}

/// Adds UTF-8 continuation byte transitions to the table.
fn build_unicode(table: *Table, base_state: u8, word_state: u8) void {
    // Set the illegal state for this unicode base area.
    // This will keep us in the same state if we encounter a malformed UTF-8 sequence.
    // And also act as a "default state" for other states to copy from.
    build_first_byte_states(&table[base_state + Utf8State.ILLEGAL], base_state, word_state);

    // Two bytes
    // `null` for `init_next` means to use the default state, which is to stay in the same unicode state (WASWORD or NEWWORD).
    build_utf8_state_row(table, base_state, Utf8State.DUO2_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.DUO2_C2, null);

    // Three bytes
    build_utf8_state_row(table, base_state, Utf8State.TRI2_E0, Utf8State.TRI3_E0_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_E1, Utf8State.TRI3_E1_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_E2, Utf8State.TRI3_E2_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_E3, Utf8State.TRI3_E3_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_ED, Utf8State.TRI3_Ed_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_EE, Utf8State.TRI3_Ee_xx);
    build_utf8_state_row(table, base_state, Utf8State.TRI2_xx, Utf8State.TRI3_xx_xx);

    build_utf8_state_row(table, base_state, Utf8State.TRI3_E0_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E1_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E1_9a, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E2_80, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E2_81, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E2_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E3_80, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E3_81, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_E3_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_Ed_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_Ee_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.TRI3_xx_xx, null);

    table[base_state + Utf8State.TRI2_E1][0x9a] = base_state + Utf8State.TRI3_E1_9a;
    table[base_state + Utf8State.TRI2_E2][0x80] = base_state + Utf8State.TRI3_E2_80;
    table[base_state + Utf8State.TRI2_E2][0x81] = base_state + Utf8State.TRI3_E2_81;
    table[base_state + Utf8State.TRI2_E3][0x80] = base_state + Utf8State.TRI3_E3_80;
    table[base_state + Utf8State.TRI2_E3][0x81] = base_state + Utf8State.TRI3_E3_81;

    // Four bytes
    build_utf8_state_row(table, base_state, Utf8State.QUAD2_xx, Utf8State.QUAD3_xx_xx);
    build_utf8_state_row(table, base_state, Utf8State.QUAD2_F0, Utf8State.QUAD3_F0_xx);
    build_utf8_state_row(table, base_state, Utf8State.QUAD2_F4, Utf8State.QUAD3_F4_xx);

    build_utf8_state_row(table, base_state, Utf8State.QUAD3_xx_xx, Utf8State.QUAD4_xx_xx_xx);
    build_utf8_state_row(table, base_state, Utf8State.QUAD3_F0_xx, Utf8State.QUAD4_F0_xx_xx);
    build_utf8_state_row(table, base_state, Utf8State.QUAD3_F4_xx, Utf8State.QUAD4_F4_xx_xx);

    build_utf8_state_row(table, base_state, Utf8State.QUAD4_xx_xx_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.QUAD4_F0_xx_xx, null);
    build_utf8_state_row(table, base_state, Utf8State.QUAD4_F4_xx_xx, null);

    // Mark unicode spaces

    // Even though 0x85 (NEXT LINE) is technically a newline,
    // GNU wc only counts \n as a newline, so we'll follow that convention.
    table[base_state + Utf8State.DUO2_C2][0x85] = State.WASSPACE;

    table[base_state + Utf8State.DUO2_C2][0xA0] = State.WASSPACE;

    table[base_state + Utf8State.TRI3_E1_9a][0x80] = State.WASSPACE;

    for (0x2000..0x200c) |i| {
        table[base_state + Utf8State.TRI3_E2_80][0x80 + (i & 0x6F)] = State.WASSPACE;
    }

    table[base_state + Utf8State.TRI3_E2_80][0xA8] = State.WASSPACE;
    table[base_state + Utf8State.TRI3_E2_80][0xA9] = State.WASSPACE;
    table[base_state + Utf8State.TRI3_E2_80][0xAF] = State.WASSPACE;
    table[base_state + Utf8State.TRI3_E2_81][0x9F] = State.WASSPACE;
    table[base_state + Utf8State.TRI3_E3_80][0x80] = State.WASSPACE;

    // Mark illegal sequences

    // The following need to be marked as illegal because they can
    // be represented with a shorter string. In other words,
    // 0xC0 0x81 is the same as 0x01, so needs to be marked as an
    // illegal sequence
    for (0x80..0xA0) |i| {
        table[base_state + Utf8State.TRI2_E0][i] = base_state + Utf8State.ILLEGAL;
    }
    for (0x80..0x90) |i| {
        table[base_state + Utf8State.QUAD2_F0][i] = base_state + Utf8State.ILLEGAL;
    }
    // Exceeds max possible size of unicode character
    for (0x90..0xC0) |i| {
        table[base_state + Utf8State.QUAD2_F4][i] = base_state + Utf8State.ILLEGAL;
    }
    // Surrogate space
    for (0xA0..0xC0) |i| {
        table[base_state + Utf8State.TRI2_ED][i] = base_state + Utf8State.ILLEGAL;
    }
}

pub fn isWhitespace(table: [State.STATE_MAX][256]u8, cp: u21) bool {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, encoded[0..]) catch return false;
    var state: usize = State.WASWORD;
    for (encoded[0..len]) |b| {
        state = table[state][b];
    }
    return state == State.WASSPACE or state == State.NEWLINE;
}
