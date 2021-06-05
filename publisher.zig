const std = @import("std");
const os = std.os;
const linux = os.linux;
const inotify_event = linux.inotify_event;

var global_event_buf: [4096]u8 align(@alignOf(inotify_event)) = undefined;

pub fn main() !void {
    const out_dir_path = "logs";    

    const inotify_fd = try os.inotify_init1(0);//linux.IN_NONBLOCK | linux.IN_CLOEXEC);
    const watch_fd = try os.inotify_add_watch(inotify_fd, out_dir_path, linux.IN_MOVED_TO);

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
            handleNewFile(name);
            offset += event_size;
            if (offset == read_result)
                break;
        }
    }
}

fn handleNewFile(name: [*:0]u8) void {
    std.log.info("TODO: handle new message '{s}'", .{name});
}
