const std = @import("std");

/// A string reader for testing.
pub const StringReader = struct {
    str: []const u8,
    cursor: u64 = 0,

    const Error = error{SeekError, EndOfStream};
    const Self = @This();
    const Reader = std.io.Reader(*Self, Error, read);

    pub fn read(self: *Self, dest: []u8) Error!usize {
        if (self.cursor >= self.str.len or dest.len == 0) {
            return 0;
        }
        const size = std.math.min(dest.len, self.str.len - self.cursor);
        std.mem.copy(u8, dest, self.str[self.cursor .. self.cursor + size]);
        self.cursor += size;
        return size;
    }

    pub fn readByte(self: *Self) Error!u8 {
        if (self.cursor >= self.str.len) {
            return Error.EndOfStream;
        }
        self.cursor += 1;
        return self.str[self.cursor];
    }

    pub fn getPos(self: *Self) Error!u64 {
        return self.cursor;
    }

    pub fn seekTo(self: *Self, offset: u64) Error!void {
        if (offset > self.str.len) {
            return Error.SeekError;
        }
        self.cursor = offset;
    }

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn close(self: *Self) void {
        // Nothing to do here.
    }
};
