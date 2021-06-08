const std = @import("std");
const testing = std.testing;

// TODO: move this to builtin maybe?
pub fn mod(num: anytype, denom: comptime_int) std.math.IntFittingRange(0, denom-1) {
    return @intCast(std.math.IntFittingRange(0, denom-1), @mod(num, denom));
}
