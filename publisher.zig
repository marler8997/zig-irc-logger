//! Watches the output directory of zig-irc-logger for new files being "moved"
//! into it, which is the last step zig-irc-logger will do when saving a new
//! IRC message.
//!
//! Both at startup and when a new message is detected, publisher will take all
//! the new messages in order and add them to the zig-irc-logs git repo.
//!
//! Note that if this program stops or fails then it's not a big deal.  It will just
//! stop live updates from being published until it starts again, but IRC messages
//! will still be saved to disk by zig-irc-logger.  This program is designed to be
//! restarted and continue where it left off.
//!
const std = @import("std");
const os = std.os;
const linux = os.linux;
const inotify_event = linux.inotify_event;

const epoch = @import("epoch.zig");

var global_event_buf: [4096]u8 align(@alignOf(inotify_event)) = undefined;

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
        \\Usage: zig-irc-publisher --logger-dir DIR --repo DIR
        \\
    , .{});
}

pub fn main() !u8 {
    var arena_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = &arena_store.allocator;

    var logger_dir_option: ?[]const u8 = null;
    var repo_option: ?[]const u8 = null;
    {
        const args = (std.process.argsAlloc(arena) catch @panic("out of memory"))[1..];
        if (args.len == 0) {
            usage();
            return @as(u8, 1);
        }
        // don't free args
        var arg_index: usize = 0;
        while (arg_index < args.len) : (arg_index += 1) {
            const arg = args[arg_index];
            if (std.mem.eql(u8, arg, "--logger-dir")) {
                logger_dir_option = getArgOption(args, &arg_index);
            } else if (std.mem.eql(u8, arg, "--repo")) {
                repo_option = getArgOption(args, &arg_index);
            } else {
                std.log.err("unknown command-line arg '{s}'", .{arg});
                return 1;
            }
        }
    }
    const logger_dir = logger_dir_option orelse {
        std.log.err("missing '--logger-dir DIR' command-line option", .{});
        return 1;
    };
    const repo = repo_option orelse {
        std.log.err("missing '--repo DIR' command-line option", .{});
        return 1;
    };

    return go(logger_dir, repo);
}

pub fn go(logger_dir: []const u8, log_repo_path: []const u8) !u8 {

    // just keep this directory open
    var log_repo_dir = std.fs.cwd().openDir(log_repo_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("zig-irc-log repo '{s}' does not exist", .{log_repo_path});
            return 1;
        },
        else => return e,
    };
    //defer log_repo_dir.close();

    // double check log_repo_dir is a repo
    log_repo_dir.access(".git", .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("log repo '{s}' doesn't seem to be a GIT repo, missing .git folder", .{log_repo_path});
            return 1;
        },
        else => return e,
    };

    try publishFiles(logger_dir, log_repo_dir);

    const inotify_fd = try os.inotify_init1(0); // linux.IN_CLOEXEC??
    const watch_fd = os.inotify_add_watch(inotify_fd, logger_dir, linux.IN_MOVED_TO) catch |e| switch(e) {
        error.FileNotFound => {
            std.log.err("log directory '{s}' does not exist", .{logger_dir});
            return 1;
        },
        else => return e,
    };

    while (true) {
        const read_result = try std.os.read(inotify_fd, &global_event_buf);
        if (read_result == 0) {
            std.log.err("read on inotify_fd returned 0", .{});
            return error.INotifyDescriptorClosed;
        }
        var offset: usize = 0;
        while (true) {
            const available = read_result - offset;
            if (available < @sizeOf(inotify_event)) {
                std.log.err("read data cutoff before end of inotify_event struct (needed {}, got {})", .{
                    @sizeOf(inotify_event), available});
                return error.INotifyReadWrongLen;
            }
            const event = @ptrCast(*inotify_event, @alignCast(@alignOf(inotify_event), &global_event_buf[offset]));
            const event_size = @sizeOf(inotify_event) + event.len;
            if (available < event_size) {
                std.log.err("read data cutoff before end of inotify_event data (needed {}, got {})", .{
                    event_size, available});
                return error.INotifyReadWrongLen;
            }
            if (event.wd != watch_fd) {
                std.log.err("expected event on fd {} but got {}", .{watch_fd, event.wd});
                return error.WrongWatchFd;
            }
            if (event.mask != linux.IN_MOVED_TO) {
                std.log.err("expected event IN_MOVED_TO (0x{x}) but got 0x{x}", .{linux.IN_MOVED_TO, event.mask});
                return error.WrongEventMask;
            }
            const name = @intToPtr([*:0]u8, @ptrToInt(event) + @sizeOf(inotify_event));
            //handleNewFile(log_repo, name);
            try publishFiles(logger_dir, log_repo_dir);
            try pushRepoChange(log_repo_path);
            offset += event_size;
            if (offset == read_result)
                break;
        }
    }
}

//fn handleNewFile(log_repo: []const u8, name_ptr: [*:0]u8) void {
//    const name = std.mem.spanZ(name_ptr);
//    if (std.mem.endsWith(u8, name, ".partial")) {
//        std.log.err("got an event for a .partial file? '{s}'", .{name});
//        // should we remove it?
//        return;
//    }
//    // make sure it is a valid timestamp
//    const timestamp = std.fmt.parseInt(i64, name, 10) catch |e| {
//        std.log.err("filename '{s}' is not a valid i64 timestamp", .{name});
//        // should we remove it? what should we do here?
//        return;
//    };
//    // TODO: add this new message to the git repo
//    // TODO: turn timestamp into year/month-dat.txt
//    std.log.info("TODO: handle new message '{}'", .{timestamp});
//}

fn publishFiles(logger_dir: []const u8, log_repo_dir: std.fs.Dir) !void {
    // TODO: maybe handle some of the openDir errors?
    var dir = try std.fs.cwd().openDir(logger_dir, .{.iterate=true});
    defer dir.close();

    const MinMax = struct {min: u32, max: u32};

    const min_max = blk: {
        var result: ?MinMax = null;
        var it = dir.iterate();
        // TODO: maybe handle some of the errors with it.next()?
        while (try it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".partial")) {
                std.log.info("[DEBUG] skipping '{s}'", .{entry.name});
                continue;
            }
            const msg_num = std.fmt.parseInt(u32, entry.name, 10) catch |e| {
                std.log.err("filename '{s}' is not a valid u32 integer", .{entry.name});
                // should we remove it? what should we do here? for now I'll just return an error
                return error.FilenameIsNotAnInteger;
            };
            if (result) |*r| {
                if (msg_num > r.max) {
                    r.max = msg_num;
                } else if (msg_num < r.min) {
                    r.min = msg_num;
                }
            } else {
                result = .{ .min = msg_num, .max = msg_num };
            }
        }
        if (result) |r| {
            break :blk r;
        }
        std.log.info("[DEBUG] there are no files to publish", .{});
        return;
    };

    {
        var i: u32 = min_max.min;
        while (true) : (i += 1) {
            var name_buf: [40]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{}", .{i}) catch unreachable;
            {
                const file = dir.openFile(name, .{}) catch |e| switch (e) {
                    error.FileNotFound => {
                        if (i == min_max.min or i == min_max.max) {
                            return e;
                        }
                        std.log.warn("missing log file '{s}'? This is possible if we don't finish removing old logs files.", .{name});
                        continue;
                    },
                    else => return e,
                };
                defer file.close();
                try publishFile(name, file, log_repo_dir);
            }
            try dir.deleteFile(name);

            if (i == min_max.max)
                break;
        }
    }
}

fn pushRepoChange(log_repo_path: []const u8) !void {
    var arena_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_store.deinit();
    const arena = &arena_store.allocator;

    std.log.info("[DEBUG] TODO: git commit/push\n", .{});
    // TODO: get files that have changed
    //       verify they are the files that we expect
    //
    const result = try std.ChildProcess.exec(.{
        .allocator = arena,
        .argv = &[_][]const u8 {
            "git",
            "status"
        },
        .cwd = log_repo_path,
        .env_map = null,
    });
    std.log.info("STDOUT: '{s}'\nSTDERR: '{s}'\n", .{result.stdout, result.stderr});
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("git process exited with code {}", .{code});
                return error.GitError;
            }
        },
        else => {
            std.log.err("git process failed with {}", .{result.term});
            return error.GitError;
        },
    }
}

fn formatRepoLogFilename(buf: []u8, year_day: epoch.YearAndDay, month_day: epoch.MonthAndDay) usize {
    return (std.fmt.bufPrint(buf, "{}/{:0>2}-{:0>2}.txt", .{
        year_day.year, month_day.month.numeric(), month_day.day_index+1}) catch unreachable).len;
}

fn publishFile(filename: []const u8, file: std.fs.File, log_repo_dir: std.fs.Dir) !void {
    const text = try file.readToEndAlloc(std.heap.page_allocator, 8192);
    defer std.heap.page_allocator.free(text);

    const newline_index = std.mem.indexOf(u8, text, "\n") orelse {
        std.log.err("file '{s}' has no newline character", .{filename});
        return error.FileHasNoNewline;
    };
    const timestamp_string = text[0..newline_index];
    const timestamp = std.fmt.parseInt(u64, timestamp_string, 10) catch |e| {
        std.log.err("file does not start with a valid timestamp, found '{s}'", .{timestamp_string});
        return error.FileHasInvalidTimestamp;
    };

    const epoch_day = (epoch.EpochSeconds { .secs = timestamp }).getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const repo_log_file_buf_len = 30;

    var repo_filename_buf: [repo_log_file_buf_len]u8 = undefined;
    var repo_filename = repo_filename_buf[0..
        formatRepoLogFilename(&repo_filename_buf, year_day, month_day)];
    std.log.info("[DEBUG] {} > {s}", .{timestamp, repo_filename});

    // TODO: check if we are behind by a day, if we are, then add the new messages to the newest day.
    //       also check if we are behind by 2 days, if so, then report an error and quit.
    //       I think maintaining message order is more important than if the timestamps appear to
    //       be out of order as a result of daylight savings or a system clock update or something.
    var now_link_buf: [repo_log_file_buf_len]u8 = undefined;
    var now_link = blk: {
        break :blk log_repo_dir.readLink("now", &now_link_buf) catch |e| switch (e) {
            error.FileNotFound => {
                try log_repo_dir.symLink(repo_filename, "now", .{});
                break :blk try log_repo_dir.readLink("now", &now_link_buf);
            },
            else => return e,
        };
    };

    var tomorrow_filename_buf: [repo_log_file_buf_len]u8 = undefined;

    // TODO: write a test for this!!!!!!!!
    if (!std.mem.eql(u8, repo_filename, now_link)) {
        // If we are off by more than a day, then we might have a serious issue, quit
        const tomorrow = epoch.EpochDay { .day = epoch_day.day + 1 };
        const tomorrow_year_day = tomorrow.calculateYearDay();
        const tomorrow_filename = tomorrow_filename_buf[0..formatRepoLogFilename(&tomorrow_filename_buf,
            tomorrow_year_day, tomorrow_year_day.calculateMonthDay())];
        if (!std.mem.eql(u8, tomorrow_filename, now_link)) {
            std.log.err("got a timestamp '{s}' that is more than a day old from \"now\": '{s}'", .{repo_filename, now_link});
            // TODO: do something to tell publisher not to start until this timestamp issue is fixed
            return error.TimestampsMessedUp;
        }
        // update now link
        return error.ImplementUpdateNowLink;

        //repo_filename = tomorrow_filename;
    }

    {
        const log_file = blk: {
            var created_dir = false;
            while (true) {
                break :blk log_repo_dir.createFile(repo_filename, .{.truncate=false}) catch |e| {
                    if (e == error.FileNotFound and !created_dir) {
                        try log_repo_dir.makeDir(repo_filename[0..4]);
                        created_dir = true;
                        continue;
                    }
                    return e;
                };
            }
        };
        defer log_file.close();
        try log_file.seekFromEnd(0);
        try log_file.writer().print("{s}\n\n", .{text});
    }
}
