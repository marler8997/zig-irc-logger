const std = @import("std");
const testing = std.testing;

// TODO: move this to builtin maybe?
pub fn mod(num: anytype, denom: comptime_int) UintFromMax(denom-1) {
    return @intCast(UintFromMax(denom-1), @mod(num, denom));
}
pub fn UintFromMax(comptime max_value: comptime_int) type {
    std.debug.assert(max_value >= 0);
    comptime var bits = 0;
    {
        comptime var s = max_value;
        inline while(s != 0) : (s >>= 1) {
            bits += 1;
        }
    }
    return std.meta.Int(.unsigned, bits);
}
test "UintFromMax" {
    try testing.expectEqual(u0, UintFromMax(0));
    try testing.expectEqual(u1, UintFromMax(1));
    try testing.expectEqual(u2, UintFromMax(2));
    try testing.expectEqual(u2, UintFromMax(3));
    try testing.expectEqual(u3, UintFromMax(4));
    try testing.expectEqual(u3, UintFromMax(7));
    try testing.expectEqual(u4, UintFromMax(8));
    try testing.expectEqual(u8, UintFromMax(255));
    try testing.expectEqual(u9, UintFromMax(256));
}
