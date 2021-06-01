const std = @import("std");
const testing = std.testing;

pub const Msg = struct {
    prefix_limit: u16, // 0 means no prefix
    cmd: Command,
    middle_off: u16,
    trail_off: ?u16,

    pub const Command = union(enum) {
        name: Pos,
        code: u10,
    };
    pub const Pos = struct {
        offset: u16,
        limit: u16,
    };
};

fn isNumber(c: u8) bool {
    return c <= '9' and c >= '0';
}
fn isLetter(c: u8) bool {
    return (c <= 'Z' and c >= 'A') or (c >= 'a' and c <= 'z');
}

pub fn parseMsg(msg: []const u8) !Msg {
    std.debug.assert(msg.len > 0);
    std.debug.assert(msg.len < std.math.maxInt(u16));
    var result : Msg = undefined;

    const cmd_start = blk: {
        if (msg[0] == ':') {
            result.prefix_limit = @intCast(u16, std.mem.indexOfScalarPos(u8, msg, 1, ' ') orelse
                return error.MissingSpaceAfterMsgPrefix);
            var cmd_start: u16 = result.prefix_limit + 1;
            while (cmd_start < msg.len and msg[cmd_start] == ' ')
                cmd_start += 1;
            break :blk @intCast(u16, cmd_start);
        }
        result.prefix_limit = 0;
        break :blk 0;
    };

    if (cmd_start >= msg.len)
        return error.MissingCommand;

    result.middle_off = blk: {
        if (isNumber(msg[cmd_start])) {
            if (cmd_start + 3 >= msg.len)
                return error.EndedEarly;
            if (!isNumber(msg[cmd_start+1]) or !isNumber(msg[cmd_start+2]) or msg[cmd_start+3] != ' ')
                return error.InvalidCode;
            result.cmd = .{ .code = std.fmt.parseInt(u10, msg[cmd_start..cmd_start+3], 10) catch unreachable };
            break :blk cmd_start+4;
        }

        if (!isLetter(msg[cmd_start]))
            return error.InvalidCommand;
        var offset = cmd_start;
        while (true) {
            offset += 1;
            if (offset == msg.len)
                return error.EndedEarly;
            if (msg[offset] == ' ') {
                result.cmd = .{ .name = .{ .offset = cmd_start, .limit = offset }};
                break :blk offset + 1;
            }
            if (!isLetter(msg[offset]))
                return error.InvalidCommand;
        }
    };

    result.trail_off = null;
    {
        var off = result.middle_off;
        while (off < msg.len) : (off += 1) {
            if (msg[off] == ':') {
                result.trail_off = off + 1;
                break;
            }
        }
    }
    return result;
}

test "parse message" {
    try testing.expectError(error.MissingSpaceAfterMsgPrefix, parseMsg(":"));
    try testing.expectError(error.MissingSpaceAfterMsgPrefix, parseMsg(":foo"));

    //try testing.expectError(error.MissingCommand, parseMsg(""));
    try testing.expectError(error.MissingCommand, parseMsg(": "));
    try testing.expectError(error.MissingCommand, parseMsg(":foo "));

    try testing.expectError(error.EndedEarly, parseMsg("0"));
    try testing.expectError(error.EndedEarly, parseMsg("00"));
    try testing.expectError(error.EndedEarly, parseMsg("000"));
    //try testing.expectError(error.InvalidCode, parseMsg("0a"));
    try testing.expectError(error.InvalidCode, parseMsg("0a0 "));
    try testing.expectError(error.InvalidCode, parseMsg("00a "));
    //try testing.expectError(error.InvalidCode, parseMsg("000a"));

    try testing.expectError(error.InvalidCommand, parseMsg("!"));
    try testing.expectError(error.InvalidCommand, parseMsg("a!"));

    try testing.expectError(error.EndedEarly, parseMsg("a"));
    try testing.expectError(error.EndedEarly, parseMsg("ab"));

    try testing.expectEqual(try parseMsg(":foo NOTICE "), Msg {
        .prefix_limit = 4,
        .cmd = .{ .name = .{ .offset = 5, .limit = 11 } },
        .middle_off = 12,
        .trail_off = null,
    });
    try testing.expectEqual(try parseMsg("NOTICE "), Msg {
        .prefix_limit = 0,
        .cmd = .{ .name = .{ .offset = 0, .limit = 6 } },
        .middle_off = 7,
        .trail_off = null,
    });
    try testing.expectEqual(try parseMsg(":foo 094 "), Msg {
        .prefix_limit = 4,
        .cmd = .{ .code = 94 },
        .middle_off = 9,
        .trail_off = null,
    });
    try testing.expectEqual(try parseMsg("123 "), Msg {
        .prefix_limit = 0,
        .cmd = .{ .code = 123 },
        .middle_off = 4,
        .trail_off = null,
    });

    try testing.expectEqual(try parseMsg(":foo NOTICE :"), Msg {
        .prefix_limit = 4,
        .cmd = .{ .name = .{ .offset = 5, .limit = 11 } },
        .middle_off = 12,
        .trail_off = 13,
    });
    try testing.expectEqual(try parseMsg(":foo NOTICE bar:"), Msg {
        .prefix_limit = 4,
        .cmd = .{ .name = .{ .offset = 5, .limit = 11 } },
        .middle_off = 12,
        .trail_off = 16,
    });
}
