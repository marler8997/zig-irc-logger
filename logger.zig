//! Connects to the an irc channel and saves channel messages to a directory.
//!
//! Each message is written to its own file whose name taken from on an ongoing
//! counter. If the directory is emptied, then the counter is reset back to 0.
//! If the logger is restarted, it will check the files to restore the last counter
//! value it had before it stopped.
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

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    {
        const stderr = std.io.getStdErr().writer();
        const timestamp = getTimestamp() catch |err| std.debug.panic("failed to get timestamp: {}", .{err});
        const epoch_seconds = std.time.epoch.EpochSeconds { .secs = timestamp };
        const day_seconds = epoch_seconds.getDaySeconds();
        nosuspend stderr.print("{:0>2}:{:0>2}:{:0>2} ", .{
            @divTrunc(day_seconds.secs, 3600),
            @divTrunc(@mod(day_seconds.secs, 3600), 60),
            day_seconds.secs % 60,
        }) catch |err| std.debug.panic("failed to write to stderr: {}", .{err});
    }
    std.log.defaultLog(level, scope, format, args);
}

fn loggyWriteCmd(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    log_send.info("sending '" ++ fmt ++ "'", args);
    try writer.print(fmt ++ "\r\n", args);
}

fn getArgOption(args: [][]const u8, i: *usize) []const u8 {
    i.* = i.* + 1;
    if (i.* >= args.len) {
        std.log.err("option {s} requires an argument", .{args[i.* - 1]});
        std.os.exit(1);
    }
    return args[i.*];
}

pub fn usage() void {
    std.debug.print(
        \\Usage: irc-logger --server SERVER --user USER --channel NAME --dir DIR
        \\
    , .{});
}

pub fn main() !u8 {
    var arena_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_store.allocator();

    var server_option: ?[]const u8 = null;
    var user_option: ?[]const u8 = null;
    var channel_option: ?[]const u8 = null;
    var out_dir_option: ?[]const u8 = null;
    {
        const args = (std.process.argsAlloc(arena) catch @panic("out of memory"))[1..];
        if (args.len == 0) {
            usage();
            return 1;
        }
        // don't free args
        var arg_index: usize = 0;
        while (arg_index < args.len) : (arg_index += 1) {
            const arg = args[arg_index];
            if (std.mem.eql(u8, arg, "--server")) {
                server_option = getArgOption(args, &arg_index);
            } else if (std.mem.eql(u8, arg, "--user")) {
                user_option = getArgOption(args, &arg_index);
            } else if (std.mem.eql(u8, arg, "--channel")) {
                channel_option = getArgOption(args, &arg_index);
            } else if (std.mem.eql(u8, arg, "--dir")) {
                out_dir_option = getArgOption(args, &arg_index);
            } else {
                std.log.err("unknown command-line arg '{s}'", .{arg});
                return 1;
            }
        }
    }
    const server = server_option orelse {
        std.log.err("missing '--server SERVER' command-line option", .{});
        return 1;
    };
    const user = user_option orelse {
        std.log.err("missing '--user USER' command-line option", .{});
        return 1;
    };
    const channel = channel_option orelse {
        std.log.err("missing '--channel NAME' command-line option", .{});
        return 1;
    };
    const out_dir = out_dir_option orelse {
        std.log.err("missing '--dir DIR' command-line option", .{});
        return 1;
    };

    try go(server, user, channel, out_dir);
    @panic("unreachable");
}

pub fn go(server: []const u8, user: []const u8, channel: []const u8, out_dir_path: []const u8) !void {
    //const login = Login { .pass = "some-password" };
    const login = null;

    // first clean the partial files in out_dir in case there were any leftover from a previous run
    var next_msg_num = try cleanPartialFilesAndFindNextMsgNum(out_dir_path);
    log_event.info("next msg num is {}", .{next_msg_num});

    var buf = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(buf);


    var stream_pinned: ssl.Stream.Pinned = undefined;
    var stream = blk: {
        var a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer a.deinit();
        break :blk try ssl.Stream.init(try std.net.tcpConnectToHost(a.allocator(), server, ssl.irc_port), server, &stream_pinned);
    };
    defer stream.deinit();
    const reader = stream.reader();
    const writer = stream.writer();

    var state = ClientState.init(out_dir_path, next_msg_num, user, login, channel, try getTimestamp());
    var data_len: usize = 0;

    while (true) {
        while (true) {
            const timeout_seconds = state.getPingTimeout(try getTimestamp());
            // note: this only works with ssl disabled at the moment
            switch (try waitFdTimeoutMillis(stream.net_stream.handle, @intCast(i32, timeout_seconds * 1000))) {
                .fd_ready => break,
                .timeout => try state.hitPingTimeout(server, writer),
            }
        }

        const read_len = try reader.read(buf[data_len..]);
        if (read_len == 0) {
            if (data_len > 0) {
                log_event.err("got end of stream with the following {} bytes left in buffer:\n{s}\n", .{data_len, buf[0..data_len]});
            }
            log_event.info("end of stream", .{});
            break;
        }
        const read_time = try getTimestamp();
        state.ping_state = .{ .normal = .{ .ping_time = read_time + max_silence_seconds } };

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
            try state.handleMsg(read_time, msg, parsed, writer);
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

fn waitFdTimeoutMillis(fd: std.os.fd_t, millis_timeout: i32) !enum { fd_ready, timeout } {
    var fds = [_]std.os.pollfd { .{
        .fd = fd,
        .events = std.os.POLL.IN,
        .revents = 0,
    } };
    const result = try std.os.poll(&fds, millis_timeout);
    return switch (result) {
        0 => .timeout,
        1 => .fd_ready,
        else => unreachable,
    };
}

const Login = struct {
    pass: []const u8,
};

const max_silence_seconds = 60;
const pong_response_timeout = 20;

const ClientState = struct {
    const Stage = enum {
        setup,
        joined,
    };
    out_dir: []const u8,
    next_msg_num: u32,
    stage: Stage,
    user: []const u8,
    user_count: u16,
    login: ?Login,
    channel: []const u8,
    ping_state: union(enum) {
        normal: struct {
            ping_time: u64,
        },
        sent: struct {
            give_up_time: u64,
        },
    },

    pub fn init(
        out_dir: []const u8,
        next_msg_num: u32,
        user: []const u8,
        login: ?Login,
        channel: []const u8,
        timestamp: u64,
    ) ClientState {
        return .{
            .out_dir = out_dir,
            .next_msg_num = next_msg_num,
            .stage = .setup,
            .user = user,
            .user_count = 0,
            .login = login,
            .channel = channel,
            .ping_state = .{ .normal = .{ .ping_time = timestamp + max_silence_seconds } },
        };
    }

    pub fn getPingTimeout(self: ClientState, now: u64) u31 {
        const event_time = switch (self.ping_state) {
            .normal => |state| state.ping_time,
            .sent => |state| state.give_up_time,
        };
        if (now >= event_time) return 0;
        return @intCast(u31, event_time - now);
    }

    pub fn hitPingTimeout(self: *ClientState, server: []const u8, writer: anytype) !void {
        switch (self.ping_state) {
            .normal => {
                log_event.info("nothing received for {} seconds, sending ping", .{max_silence_seconds});
                // TODO: not sure if the 'host' is the right thing to send here
                try loggyWriteCmd(writer, "PING {s}", .{server});
                self.ping_state = .{ .sent = .{
                    .give_up_time = ((try getTimestamp()) + pong_response_timeout),
                } };
            },
            .sent => {
                log_event.err("server didn't respond to ping, we must be disconnected", .{});
                return error.NoPingResponse;
            },
        }
    }

    fn targetsMe(self: ClientState, target: []const u8) bool {
        return mem.eql(u8, target, "*") or mem.eql(u8, target, self.user) or mem.eql(u8, target, "$$*");
    }
    fn handleMsg(self: *ClientState, read_time: u64, msg: []const u8, parsed: irc.Msg, writer: anytype) !void {
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
                } else if (mem.eql(u8, "PONG", name)) {
                    // this would have been in response to a ping, just getting data
                    // will be enough to reset the ping timeout so we don't need any
                    // special handling for this
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

                        if (self.next_msg_num != 0 and try dirIsEmpty(self.out_dir)) {
                            log_event.info("reset msg counter from {} back to 0", .{self.next_msg_num});
                            self.next_msg_num = 0;
                        }
                        try writeMsg(self.out_dir, self.next_msg_num, read_time, from, private_msg);
                        self.next_msg_num += 1;
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

fn getTimestamp() !u64 {
    var ts: os.timespec = undefined;
    try os.clock_gettime(os.CLOCK.REALTIME, &ts);
    return @intCast(u64, ts.tv_sec);
}

fn makeNamePath(buf: []u8, out_dir_path: []const u8, msg_num: u32) usize {
    return (std.fmt.bufPrint(buf, "{s}/{}", .{out_dir_path, msg_num}) catch unreachable).len;
}

fn writeMsg(out_dir_path: []const u8, msg_num: u32, timestamp: u64, from: []const u8, msg: []const u8) !void {
    const MAX_FILENAME = 255;

    var name_buf: [MAX_FILENAME]u8 = undefined;
    var tmp_name_buf: [MAX_FILENAME]u8 = undefined;

    const name = name_buf[0..makeNamePath(&name_buf, out_dir_path, msg_num)];
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "{s}.partial", .{name}) catch unreachable;

    {
        const tmp_file = try std.fs.cwd().createFile(tmp_name, .{});
        defer tmp_file.close();
        try tmp_file.writer().print("{}\n{s}\n{s}", .{timestamp, from, msg});
    }

    const simulate_existing_file_error = false;
    if (simulate_existing_file_error) {
        (std.fs.cwd().createFile(name, .{}) catch unreachable).close();
    }

    try std.fs.cwd().rename(tmp_name, name);
}

fn dirIsEmpty(path: []const u8) !bool {
    var dir = try std.fs.cwd().openIterableDir(path, .{.access_sub_paths=true});
    defer dir.close();
    var it = dir.iterate();
    return if (try it.next()) |_| false else true;
}

fn cleanPartialFilesAndFindNextMsgNum(out_dir_path: []const u8) !u32 {
    var next_msg_num: u32 = 0;
    var clean_count: usize = 0;
    var it_dir = std.fs.cwd().openIterableDir(out_dir_path, .{.access_sub_paths=true}) catch |err| switch(err) {
        error.FileNotFound => {
            std.log.err("--dir option '{s}' does not exist, giving up in case it was a typo", .{out_dir_path});
            std.os.exit(0xff);
        },
        else => |e| return e,
    };
    defer it_dir.close();
    var it = it_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".partial")) {
            std.log.info("removing '{s}/{s}'", .{out_dir_path, entry.name});
            try it_dir.dir.deleteFile(entry.name);
            clean_count += 1;
        } else {
            const num = std.fmt.parseInt(u32, entry.name, 10) catch {
                std.log.err("filename '{s}' is not a valid u32", .{entry.name});
                return error.InvalidFilenameInOutDir;
            };
            if (num >= next_msg_num) {
                next_msg_num = num + 1;
            }
        }
    }
    std.log.info("removed {} '.partial' files from '{s}' directory", .{clean_count, out_dir_path});
    return next_msg_num;
}
