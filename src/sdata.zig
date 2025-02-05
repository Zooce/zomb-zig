const std = @import("std");

pub const StreamTypeWidth = u7;

const base_number: StreamTypeWidth = 0x01;
pub const StreamTypeNumber = enum(StreamTypeWidth) {
    ObjectBegin = base_number << 0,
    ObjectEnd = base_number << 1,

    Key = base_number << 2,
    ObjectString = base_number << 3,

    ArrayBegin = base_number << 4,
    ArrayEnd = base_number << 5,

    ArrayString = base_number << 6,
};

pub const StreamType = union(StreamTypeNumber) {
    ObjectBegin: void,
    ObjectEnd: void,

    Key: []const u8,
    ObjectString: std.ArrayList(u8),

    ArrayBegin: void,
    ArrayEnd: void,

    ArrayString: std.ArrayList(u8),
};

// TODO: should I put the sstep function here?
const testing = std.testing;

test "sdata types test" {
    var stype: StreamType = .{ .Key = "hello" };
    try testing.expectEqualStrings("hello", stype.Key);
}


// test "basic sdata test" {
//     const input =
//         \\key = [
//         \\    hello
//         \\    {
//         \\        cool = beans
//         \\        never = [ 300 400 12 ]
//         \\    }
//         \\]
//         \\
//         ;


// }
