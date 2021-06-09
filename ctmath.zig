const std = @import("std");
const testing = std.testing;
const IntFittingRange = std.math.IntFittingRange;

pub fn comptimeMod(num: anytype, denom: comptime_int) IntFittingRange(0, denom-1) {
    return @intCast(IntFittingRange(0, denom-1), @mod(num, denom));
}
