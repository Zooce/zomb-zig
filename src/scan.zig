const std = @import("std");

pub fn Scanner(comptime InputType: type, max_buffer_size_: anytype) type {
    return struct {
        const Self = @This();

        const TestData = struct {
            read_count: usize = 0,
        };

        /// The input to read for scanning -- we own this for the following reasons:
        ///     1. The .offset field of a Token is based on where we are in the input. If some other
        ///        code owns the input, they have control over the input's underlying cursor from
        ///        calls like `input.seekTo`. We want control over the input's underlying cursor, thus
        ///        we want to own the input itself.
        ///     2. For same reason as #1, the current line number may also be faulty if some other
        ///        code owns the input and seeks past one or more newlines before the scanner does
        ///        another read.
        input: *InputType,

        /// Where we are in the input
        input_cursor: u64 = 0,

        /// The reader for the input
        reader: typeblk: {
            inline for (@typeInfo(InputType).Struct.decls) |decl| {
                if (std.mem.eql(u8, "reader", decl.name)) {
                    break :typeblk decl.data.Fn.return_type;
                }
            }
            @compileError("Unable to get reader type for Scanner");
        },

        /// The buffer which the input's reader will read to
        buffer: [max_buffer_size_]u8 = undefined,

        /// The current number of bytes read into the buffer
        buffer_size: usize = 0,

        /// Where we are in the current buffer
        buffer_cursor: usize = 0,

        /// Whether we've already encountered EOF - so we can skip unnecessary syscalls
        eof_in_buffer: bool = false,

        /// The line where the current token lives (we start at the first line)
        current_line: usize = 1,

        test_data: TestData = TestData{},

        pub fn init(input_: *InputType) Self {
            return Self{
                .input = input_,
                .reader = input_.reader(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.input.close();
        }

        /// Ensures that there are bytes in the buffer and advances the input and buffer cursors
        /// forward by one byte. If there are no more bytes to read from then this returns `null`
        /// otherwise it returns the byte previously pointed to by the buffer cursor.
        pub fn advance(self: *Self) ?u8 {
            if (!self.ensureBufferHasBytes()) {
                return null;
            }

            self.input_cursor += 1;
            self.buffer_cursor += 1;

            const byte = self.buffer[self.buffer_cursor - 1];
            if (byte == '\n') self.current_line += 1;
            return byte;
        }

        /// Returns the byte at the buffer cursor, or `null` if there aren't any more bytes to read
        /// or when we encounter an error while reading.
        pub fn peek(self: *Self) ?u8 {
            if (!self.ensureBufferHasBytes()) {
                return null;
            }
            return self.buffer[self.buffer_cursor];
        }

        /// Returns the byte after the buffer cursor, or `null` if there aren't any more bytes to
        /// read or when we encounter an error while reading.
        pub fn peekNext(self: *Self) ?u8 {
            if (self.buffer_cursor + 1 == self.buffer_size) {
                // this is a special case where we need to see one byte past the end of the buffer
                // but we don't want to mess anything up, so we reset back to our original position
                // after this "extended" read
                const orig_pos = self.input.getPos() catch |err| {
                    std.log.err("Unable to get input position: {}", .{err});
                    return null;
                };
                const byte = self.reader.readByte() catch |err| {
                    if (err != error.EndOfStream) {
                        std.log.err("Unable to read byte: {}", .{err});
                    }
                    return null;
                };
                self.input.seekTo(orig_pos) catch |err| {
                    std.log.err("Unable to seek to input's original position: {}", .{err});
                    return null;
                };
                return byte;
            }
            if (!self.ensureBufferHasBytes()) {
                return null;
            }
            return self.buffer[self.buffer_cursor + 1];
        }

        pub fn readFrom(self: *Self, start_: u64, size_: u64, arrayList_: *std.ArrayList(u8)) !u64 {
            const orig_pos = try self.input.getPos();
            try self.input.seekTo(start_);
            var buf: [1024]u8 = undefined;
            var remaining_bytes = size_;
            while (remaining_bytes > 0) {
                const bytes_read = try self.reader.read(&buf);
                const size = std.math.min(bytes_read, remaining_bytes);
                try arrayList_.appendSlice(buf[0..size]);
                remaining_bytes -= size;
            }
            self.input.seekTo(orig_pos) catch |err| {
                // if there's more for us to read, then this error puts us in a bad state, so return it
                if (!self.eof_in_buffer) {
                    return err;
                }
            };
            return size_ - remaining_bytes;
        }

        /// Fill the buffer with some bytes from the input's reader if necessary, and report whether
        /// there bytes left to read.
        fn ensureBufferHasBytes(self: *Self) bool {
            if (self.buffer_cursor == self.buffer_size and !self.eof_in_buffer) {
                if (self.reader.read(&self.buffer)) |count| {
                    self.buffer_size = count;
                } else |err| {
                    std.log.err("Encountered error while reading: {}", .{err});
                    self.buffer_size = 0;
                }
                self.buffer_cursor = 0;
                self.eof_in_buffer = self.buffer_size < max_buffer_size_;
                self.test_data.read_count += 1;
            }
            return self.buffer_cursor < self.buffer_size;
        }
    };
}

//==============================================================================
//
//
//
// Testing
//==============================================================================

const testing = std.testing;
const test_allocator = testing.allocator;
const StringReader = @import("string_reader.zig").StringReader;

const test_buffer_size: usize = 5;
const StringScanner = Scanner(StringReader, test_buffer_size);

test "scanner" {
    const str =
        \\Hello,
        \\ World!
    ;
    var string_reader = StringReader{ .str = str };
    var scanner = StringScanner.init(&string_reader);
    errdefer {
        std.log.err(
            \\
            \\input_cursor = {}
            \\buffer = {s}
            \\buffer_cursor = {}
            \\
        , .{
            scanner.input_cursor,
            scanner.buffer,
            scanner.buffer_cursor,
        });
    }
    defer scanner.deinit();

    try testing.expectEqual(@as(usize, 0), scanner.test_data.read_count);
    try testing.expectEqual(@as(usize, 1), scanner.current_line);
    try testing.expectEqual(false, scanner.eof_in_buffer);
    try testing.expectEqual(@as(u8, 'H'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'e'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'l'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'l'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'o'), scanner.peek().?);
    try testing.expectEqual(@as(u8, ','), scanner.peekNext().?);
    try testing.expectEqual(@as(u8, 'o'), scanner.advance().?);
    try testing.expectEqual(@as(usize, 1), scanner.test_data.read_count);
    try testing.expectEqual(@as(usize, 1), scanner.current_line);
    try testing.expectEqual(@as(u64, 5), scanner.input_cursor);
    try testing.expectEqual(@as(u64, 5), scanner.buffer_cursor);
    try testing.expectEqual(false, scanner.eof_in_buffer);
    try testing.expectEqual(@as(u8, ','), scanner.peek().?);
    try testing.expectEqual(@as(u8, '\n'), scanner.peekNext().?);
    try testing.expectEqual(@as(u8, ','), scanner.advance().?);
    try testing.expectEqual(@as(u8, '\n'), scanner.advance().?);
    try testing.expectEqual(@as(u8, ' '), scanner.advance().?);

    var slice = std.ArrayList(u8).init(test_allocator);
    defer slice.deinit();
    const bytes_read = try scanner.readFrom(2, 3, &slice);
    try testing.expectEqual(@as(usize, 3), bytes_read);
    try testing.expectEqual(@as(usize, 3), slice.items.len);
    try testing.expectEqual(@as(u64, 8), scanner.input_cursor);
    try testing.expectEqualStrings("llo", slice.items);

    try testing.expectEqual(@as(u8, 'W'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'o'), scanner.advance().?);
    try testing.expectEqual(@as(usize, 2), scanner.test_data.read_count);
    try testing.expectEqual(@as(usize, 2), scanner.current_line);
    try testing.expectEqual(@as(u64, 10), scanner.input_cursor);
    try testing.expectEqual(@as(u64, 5), scanner.buffer_cursor);
    try testing.expectEqual(false, scanner.eof_in_buffer);
    try testing.expectEqual(@as(u8, 'l'), scanner.peekNext().?);
    try testing.expectEqual(@as(u8, 'r'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'l'), scanner.advance().?);
    try testing.expectEqual(@as(u8, 'd'), scanner.advance().?);
    try testing.expectEqual(@as(u8, '!'), scanner.advance().?);
    try testing.expectEqual(@as(usize, 3), scanner.test_data.read_count);
    try testing.expectEqual(@as(usize, 2), scanner.current_line);
    try testing.expectEqual(true, scanner.eof_in_buffer);
    try testing.expectEqual(@as(?u8, null), scanner.peek());
    try testing.expectEqual(@as(?u8, null), scanner.peekNext());
    try testing.expectEqual(@as(?u8, null), scanner.advance());
    try testing.expectEqual(@as(usize, 3), scanner.test_data.read_count);
    try testing.expectEqual(@as(usize, 2), scanner.current_line);
    try testing.expectEqual(true, scanner.eof_in_buffer);
}
