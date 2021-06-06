//! Connects to the #zig irc channel and saves channel messages to the
//! filesystem.
//!
//! Each message is written to it's own file whose name is determined by
//! its timestamp and whose contents is "FROM\nMSG".
//!
//! When this tool creates a new file, its filename will temporarily end with
//! ".partial".  This tells other tools that the logger is still writing to
//! the file and not to touch it.  Once the ".partial" extension has been
//! removed, the file is free to be used or even removed by another tool.
//!
//! Note that this tool is intentionally simple to minimize downtime.
//! It's design also facilitates multiple redundant clients saving files
//! to multiple output directories and allowing another tool to compare
//! and combine them to get the final output if one of them misses something.
//!
const std = @import("std");
const mem = std.mem;
const os = std.os;

const ssl = @import("ssl");

const irc = @import("irc.zig");

const log_msg = std.log.scoped(.msg);
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
    const host: []const u8 = "irc.libera.chat";
    const user = "zig-irc-logger";
    //const login = Login { .pass = "some-password" };
    const login = null;
    //const channel = "zig";
    const channel = "zigtest";

    const out_dir_path = channel ++ "-logs";

    // first clean the partial files in out_dir in case there were any leftover from a previous run
    try cleanPartialFiles(out_dir_path);

    const allocator = std.heap.page_allocator;
    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);

    var stream_pinned: ssl.Stream.Pinned = undefined;
    var stream = try ssl.Stream.init(try std.net.tcpConnectToHost(allocator, host, ssl.irc_port), host, &stream_pinned);
    defer stream.deinit();
    const reader = stream.reader();
    const writer = stream.writer();

    var state = ClientState.init(out_dir_path, user, login, channel);

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
    out_dir: []const u8,
    stage: Stage,
    user: []const u8,
    user_count: u16,
    login: ?Login,
    channel: []const u8,

    pub fn init(out_dir: []const u8, user: []const u8, login: ?Login, channel: []const u8) ClientState {
        return .{
            .out_dir = out_dir,
            .stage = .setup,
            .user = user,
            .user_count = 0,
            .login = login,
            .channel = channel,
        };
    }
    fn targetsMe(self: ClientState, target: []const u8) bool {
        return mem.eql(u8, target, "*") or mem.eql(u8, target, self.user);
    }
    fn handleMsg(self: *ClientState, msg: []const u8, parsed: irc.Msg, writer: anytype) !void {
        log_msg.info("{s}", .{msg});
        const params = msg[parsed.params_off..];
        switch (parsed.cmd) {
            .name => |name_pos| {
                const name = msg[name_pos.offset..name_pos.limit];
                if (mem.eql(u8, "NOTICE", name)) {
                    var param_it = irc.ParamIterator.initSlice(params);
                    const target = param_it.next() orelse {
                        log_event.err("NOTICE missing target param", .{});
                        return error.MalformedMessage;
                    };
                    const notice_msg = param_it.next() orelse {
                        log_event.err("NOTICE missing message param", .{});
                        return error.MalformedMessage;
                    };
                    if (null != param_it.next()) {
                        log_event.err("NOTICE got too many params", .{});
                        return error.MalformedMessage;
                    }
                    if (!self.targetsMe(target)) {
                        log_event.err("NOTICE targets '{s}' which isn't me?", .{target});
                        // TODO: I'm sure this can happen, just don't know what to do yet
                        return error.UnexpectedMessageTarget;
                    }
                    if (mem.eql(u8, notice_msg, "*** No Ident response")) {
                        log_event.info("Got 'No Ident response', sending user...", .{});
                        try loggyWriteCmd(writer, "NICK {s}", .{self.user});
                        try loggyWriteCmd(writer, "USER {s} * * :{0s}", .{self.user});
                    } else if (mem.startsWith(u8, notice_msg, "You are now identified for ")) {
                        try loggyWriteCmd(writer, "JOIN #{s}", .{self.channel});
                    } else if (mem.startsWith(u8, notice_msg, "Invalid password for ")) {
                        return error.InvalidPassword;
                    } else {
                        //log_event.warn("ignoring msg", .{});
                    }
                } else if (mem.eql(u8, "PING", name)) {
                    try loggyWriteCmd(writer, "PONG {s}", .{params});
                } else if (mem.eql(u8, "JOIN", name)) {
                    var param_it = irc.ParamIterator.initSlice(params);
                    const channels = param_it.next() orelse {
                        log_event.err("JOIN missing channels param", .{});
                        return error.MalformedMessage;
                    };
                    if (null != param_it.next()) {
                        log_event.err("JOIN got more params than expected", .{});
                        return error.UnexpectedMessage;
                    }
                    if (!mem.startsWith(u8, channels, "#") or !mem.eql(u8, channels[1..], self.channel)) {
                        log_event.err("expected to join '#{s}' but joined '{s}'?", .{self.channel, channels});
                        return error.JoinedWrongChannel;
                    }
                    self.stage = .joined;
                } else if (mem.eql(u8, "PRIVMSG", name)) {
                    var param_it = irc.ParamIterator.initSlice(params);
                    const target = param_it.next() orelse {
                        log_event.err("PRIVMSG missing target param", .{});
                        return error.MalformedMessage;
                    };
                    const private_msg = param_it.next() orelse {
                        log_event.err("PRIVMSG missing message param", .{});
                        return error.MalformedMessage;
                    };
                    if (null != param_it.next()) {
                        log_event.err("PRIVMSG got too many params", .{});
                        return error.MalformedMessage;
                    }
                    if (std.mem.startsWith(u8, target, "#") and std.mem.eql(u8, target[1..], self.channel)) {
                        const from = if (parsed.prefix_limit == 0) "???" else msg[1..parsed.prefix_limit];
                        //try self.channel_writer.print("{}\n{s}\n{s}\n\n", .{std.time.milliTimestamp(), from, private_msg});
                        try writeMsg(self.out_dir, from, private_msg);
                    } else {
                        log_event.warn("PRIVMSG to unknown target '{s}'", .{target});
                    }
                } else {
                    //log_event.warn("ignoring msg", .{});
                }
            },
            .code => |code| {
                if (code == 376) {
                    log_event.info("Got '376' '{s}', sending command to join #{s}...", .{params, self.channel});
                    if (self.login) |login| {
                        try loggyWriteCmd(writer, "PRIVMSG NickServ :identify {s}", .{login.pass});
                    } else {
                        try loggyWriteCmd(writer, "JOIN #{s}", .{self.channel});
                    }
                } else if (code == 433) { // nick already in use
                    self.user_count = self.user_count +% 1;
                    try loggyWriteCmd(writer, "NICK {s}{}", .{self.user, self.user_count});
                    try loggyWriteCmd(writer, "USER {s}{} * * :{0s}", .{self.user, self.user_count});
                } else if (code == 477) {
                    return error.CannotJoinChannel;
                } else {
                    //log_event.warn("ignoring msg", .{});
                }
            },
        }
    }
};

fn makeNamePath(buf: []u8, out_dir_path: []const u8, timestamp: i64) usize {
    return (std.fmt.bufPrint(buf, "{s}/{}", .{out_dir_path, timestamp}) catch unreachable).len;
}

fn writeMsg(out_dir_path: []const u8, from: []const u8, msg: []const u8) !void {
    const MAX_FILENAME = 255;

    var name_buf: [MAX_FILENAME]u8 = undefined;
    var tmp_name_buf: [MAX_FILENAME]u8 = undefined;

    var timestamp = std.time.milliTimestamp();

    const name = name_buf[0..makeNamePath(&name_buf, out_dir_path, timestamp)];
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "{s}.partial", .{name}) catch unreachable;

    {
        const tmp_file = try std.fs.cwd().createFile(tmp_name, .{});
        defer tmp_file.close();
        try tmp_file.writer().print("{s}\n{s}", .{from, msg});
    }

    const simulate_existing_file_error = false;
    if (simulate_existing_file_error) {
        (std.fs.cwd().createFile(name, .{}) catch unreachable).close();
    }

    while (true) {
        // TODO: replace access call with rename with RENAME_NOREPLACE flag
        std.fs.cwd().access(name, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try std.fs.cwd().rename(tmp_name, name);
                break;
            },
            else => return e,
        };
        timestamp += 1;
        //log_event.info("moving log to next timestamp '{}' to resolve timestamp collision", .{timestamp});
        const new_name_len = makeNamePath(&name_buf, out_dir_path, timestamp);
        std.debug.assert(name.len == new_name_len);
    }
}

fn cleanPartialFiles(out_dir_path: []const u8) !void {
    var clean_count: usize = 0;
    var dir = try std.fs.cwd().openDir(out_dir_path, .{.iterate=true});
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".partial")) {
            std.log.info("removing '{s}/{s}'", .{out_dir_path, entry.name});
            try dir.deleteFile(entry.name);
            clean_count += 1;
        }
    }
    std.log.info("removed {} '.partial' files from '{s}' directory", .{clean_count, out_dir_path});
}
