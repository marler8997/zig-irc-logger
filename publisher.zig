const std = @import("std");
const os = std.os;
const linux = os.linux;
const inotify_event = linux.inotify_event;

var global_event_buf: [4096]u8 align(@alignOf(inotify_event)) = undefined;

pub fn main() !u8 {
    const out_dir_path = "zigtest-logs";
    const log_repo = "zig-irc-logs";

    try publishFiles(out_dir_path, log_repo);

    const inotify_fd = try os.inotify_init1(0);//linux.IN_NONBLOCK | linux.IN_CLOEXEC);
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
            try publishFiles(out_dir_path, log_repo);
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

fn publishFiles(out_dir_path: []const u8, log_repo: []const u8) !void {
    std.log.info("[DEBUG] publish files!!!", .{});

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
        std.log.info("[DEBUG] there are no files to publish???", .{});
        return;
    };

    {
        var i: u32 = min_max.min;
        while (true) : (i += 1) {
            var name_buf: [40]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{}", .{i}) catch unreachable;
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

            std.log.info("TODO: publish '{s}'", .{name});


            if (i == min_max.max)
                break;
        }
    }
    std.log.info("[DEBUG] files {}", .{min_max});
}
