const std = @import("std");
const apple_pie = @import("apple_pie");

pub const io_mode = .evented;

pub const buffer_size: usize = 8192;
pub const request_buffer_size: usize = 4096;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try apple_pie.listenAndServe(
        &gpa.allocator,
        try std.net.Address.parseIp("0.0.0.0", 8080),
        index,
    );    
}

fn index(response: *apple_pie.Response, request: apple_pie.Request) !void {
    _ = request;
    const file = std.fs.cwd().openFile("logs/current", .{}) catch |openfile_error| {
        response.writer().print("Error: failed to open current irc logfile: {}\n", .{openfile_error}) catch {
            // TODO: what to do with this write error?
        };
        return;
    };
    defer file.close();

    // TODO: I could use linux sendfile syscall right?
    var buffer: [std.mem.page_size]u8 = undefined;
    while (true) {
        const len = file.read(&buffer) catch |read_file_error| {
            response.writer().print("\n!!! ERROR while sending file contents: {}!!!\n", .{read_file_error}) catch {
                // TODO: what to do with this write error?
            };
            return;
        };
        if (len == 0)
            break;
        response.writer().writeAll(buffer[0..len]) catch {
            // TODO: what to do with this write error?
            return;
        };
    }
}
