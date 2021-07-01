const std = @import("std");

pub const irc_port = 6667;

pub const Stream = struct {
    pub const Pinned = struct {};
    net_stream: std.net.Stream,

    pub fn init(net_stream: std.net.Stream, serverName: []const u8, pinned: *Pinned) !Stream {
        _ = serverName;
        _ = pinned;
        return Stream { .net_stream = net_stream };
    }

    pub fn deinit(self: Stream) void {
        // TODO: net_stream.deinit() should be pass by value
        self.net_stream.close();
    }

    pub fn reader(self: *const Stream) std.net.Stream.Reader {
        return self.net_stream.reader();
    }
    pub fn writer(self: *const Stream) std.net.Stream.Writer {
        return self.net_stream.writer();
    }
};
