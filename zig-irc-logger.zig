const std = @import("std");
const mem = std.mem;
const os = std.os;

const ssl = @import("ssl");

const irc = @import("irc.zig");

const log_setup_msg = std.log.scoped(.setup_msg);
const log_channel_msg = std.log.scoped(.channel_msg);
const log_send = std.log.scoped(.send);
const log_event = std.log.scoped(.event);

fn loggyWriteCmd(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    log_send.info("sending '" ++ fmt ++ "'", args);
    try writer.print(fmt ++ "\r\n", args);
}

pub fn main() u8 {
    go() catch |e| {
        std.log.err("{}", .{e});
        return 1;
    };
    unreachable;
}

pub fn go() !void {
    const user = "zig-irc-logger";
    //const login = Login { .pass = "some-password" };
    const login = null;
    const channel = "zig";

    const host: []const u8 = "irc.libera.chat";
    const allocator = std.heap.page_allocator;
    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);

    var stream_pinned: ssl.Stream.Pinned = undefined;
    var stream = try ssl.Stream.init(try std.net.tcpConnectToHost(allocator, host, ssl.irc_port), host, &stream_pinned);
    defer stream.deinit();
    const reader = stream.reader();
    const writer = stream.writer();

    var state = ClientState.init(user, login, channel);

    var data_len: usize = 0;

    while (true) {
        const read_len = try reader.read(buf[data_len..]);
        if (read_len == 0) {
            if (data_len > 0) {
                log_event.err("got end of stream with the following {} bytes left in buffer:\n{s}\n", .{data_len, buf[0..data_len]});
            }
            log_event.info("end of stream", .{});
            break;
        }
        const len = data_len + read_len;

        const check_start = if (data_len > 0) (data_len - 1) else 0;
        var newline_index = mem.indexOfPos(u8, buf, check_start, "\r\n") orelse {
            if (len == buf.len) {
                log_event.err("msg exceeded max size of {}\n", .{buf.len});
                return error.MsgTooBig;
            }
            data_len = len;
            continue;
        };
        var msg_start: usize = 0;
        while (true) {
            const msg = buf[msg_start..newline_index];
            const parsed = irc.parseMsg(msg) catch |e| {
                log_event.err("failed to parse the following message ({}):\n{s}\n", .{e, msg});
                return error.InvalidMsg;
            };
            try state.handleMsg(msg, parsed, writer);
            msg_start = newline_index + 2;
            if (msg_start == len) {
                data_len = 0;
                break;
            }
            newline_index = mem.indexOfPos(u8, buf[0..len], msg_start, "\r\n") orelse {
                data_len = len - msg_start;
                //try log_writer.print("[DEBUG] saving {} bytes... '{s}'\n", .{data_len, buf[msg_start..len]});
                mem.copy(u8, buf[0..data_len], buf[msg_start..len]);
                break;
            };
        }
    }
}

const Login = struct {
    pass: []const u8,
};

const ClientState = struct {
    const Stage = enum {
        setup,
        joined,
    };
    stage: Stage,
    user: []const u8,
    login: ?Login,
    channel: []const u8,

    pub fn init(user: []const u8, login: ?Login, channel: []const u8) ClientState {
        return .{
            .stage = .setup,
            .user = user,
            .login = login,
            .channel = channel,
        };
    }
    pub fn handleMsg(self: *ClientState, msg: []const u8, parsed: irc.Msg, writer: anytype) !void {
        switch (self.stage) {
            .setup => log_setup_msg.info("{s}", .{msg}),
            .joined => log_channel_msg.info("{s}", .{msg}),
        }
        const params = msg[parsed.middle_off..];
        const trail_opt: ?[]const u8 = if (parsed.trail_off) |off| msg[off..] else null;
        switch (parsed.cmd) {
            .name => |name_pos| {
                const name = msg[name_pos.offset..name_pos.limit];
                if (std.mem.eql(u8, "NOTICE", name)) {
                    if (trail_opt) |trail| {
                        if (mem.eql(u8, trail, "*** No Ident response")) {
                            log_event.info("Got 'No Ident response', sending user...", .{});
                            try loggyWriteCmd(writer, "NICK {s}", .{self.user});
                            try loggyWriteCmd(writer, "USER {s} * * :{0s}", .{self.user});
                        } else if (mem.startsWith(u8, trail, "You are now identified for ")) {
                            try loggyWriteCmd(writer, "JOIN #{s}", .{self.channel});
                        } else if (mem.startsWith(u8, trail, "Invalid password for ")) {
                            return error.InvalidPassword;
                        } else {
                            //log_event.warn("ignoring msg", .{});
                        }
                    }
                } else if (std.mem.eql(u8, "PING", name)) {
                    try loggyWriteCmd(writer, "PONG {s}", .{params});
                } else if (std.mem.eql(u8, "JOIN", name)) {
                    if (std.mem.startsWith(u8, params, "#") and std.mem.eql(u8, params[1..], self.channel)) {
                        self.stage = .joined;
                    } else {
                        log_event.err("expected to join '#{s}' but joined '{s}'?", .{self.channel, params});
                        return error.JoinedWrongChannel;
                    }
                } else {
                    //log_event.warn("ignoring msg", .{});
                }
            },
            .code => |code| {
                // TODO: handle code 433 (Nickname is already in use)
                if (code == 376) {
                    log_event.info("Got '376' '{s}', sending command to join #{s}...", .{params, self.channel});
                    if (self.login) |login| {
                        try loggyWriteCmd(writer, "PRIVMSG NickServ :identify {s}", .{login.pass});
                    } else {
                        try loggyWriteCmd(writer, "JOIN #{s}", .{self.channel});
                    }
                } else if (code == 477) {
                    return error.CannotJoinChannel;
                } else {
                    //log_event.warn("ignoring msg", .{});
                }
            },
        }
    }
};
