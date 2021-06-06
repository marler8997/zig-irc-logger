const std = @import("std");
const os = std.os;
const linux = os.linux;
const inotify_event = linux.inotify_event;

const epoch = @import("epoch.zig");

var global_event_buf: [4096]u8 align(@alignOf(inotify_event)) = undefined;

pub fn main() !u8 {
    const out_dir_path = "zigtest-logs";
    //const log_repo_path = "zig-irc-logs-test-dir";
    const log_repo_path = "zig-irc-logs";

    // just keep this directory open
    var log_repo_dir = std.fs.cwd().openDir(log_repo_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("zig-irc-log repo '{s}' does not exist", .{log_repo_path});
            return 1;
        },
        else => return e,
    };
    //defer log_repo_dir.close();

    try publishFiles(out_dir_path, log_repo_dir);

    const inotify_fd = try os.inotify_init1(0); // linux.IN_CLOEXEC??
    const watch_fd = os.inotify_add_watch(inotify_fd, out_dir_path, linux.IN_MOVED_TO) catch |e| switch(e) {
        error.FileNotFound => {
            std.log.err("log directory '{s}' does not exist", .{out_dir_path});
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
            try publishFiles(out_dir_path, log_repo_dir);
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

fn publishFiles(out_dir_path: []const u8, log_repo_dir: std.fs.Dir) !void {
    // TODO: maybe handle some of the openDir errors?
    var dir = try std.fs.cwd().openDir(out_dir_path, .{.iterate=true});
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

    const year_day = ((epoch.EpochSeconds { .secs = timestamp }).getEpochDay()).calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var repo_filename_buf: [30]u8 = undefined;
    const repo_filename = std.fmt.bufPrint(&repo_filename_buf, "{}/{:0>2}-{:0>2}.txt", .{
        year_day.year, month_day.month_index+1, month_day.day_index+1}) catch unreachable;
    std.log.info("[DEBUG] {} > {s}", .{timestamp, repo_filename});

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
