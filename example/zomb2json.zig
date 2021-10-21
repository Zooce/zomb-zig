//! zomb2json
//!
//! This program takes a .zomb file and converts it to a .json file.
//!
//! Run this from zomb-zig/ using the command `zig build example`

const std = @import("std");
const json = std.json;

const zomb = @import("zomb");


pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.allocator;
    var input_file_contents = std.ArrayList(u8).init(alloc);
    defer input_file_contents.deinit();

    {
        const args = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, args);

        const path: []const u8 = if (args.len >= 2) args[1] else "example/test.zomb";

        const file = try std.fs.cwd().openFile(path, .{ .read = true });
        defer file.close();
        std.log.info("Reading from {s}", .{path});

        const max_file_size = if (args.len >= 3) try std.fmt.parseUnsigned(usize, args[2], 10) else 100_000_000;

        try file.reader().readAllArrayList(&input_file_contents, max_file_size);
    }

    var zomb_parser = zomb.Parser.init(input_file_contents.items, std.heap.page_allocator);
    defer zomb_parser.deinit();

    const z = try zomb_parser.parse(std.heap.page_allocator);
    defer z.deinit();

    var output_file = try std.fs.cwd().createFile("example/zomb.json", .{});
    defer output_file.close();

    var jsonWriter = json.writeStream(output_file.writer(), zomb.max_nested_depth);
    jsonWriter.whitespace = json.StringifyOptions.Whitespace{};

    try zombValueToJson(zomb.ZValue{ .Object = z.map }, &jsonWriter);
}

fn zombValueToJson(value_: zomb.ZValue, jw_: anytype) anyerror!void {
    switch (value_) {
        .Object => |hash_map| {
            try jw_.beginObject();

            var iter = hash_map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                try jw_.objectField(key);

                const val = entry.value_ptr.*;
                try zombValueToJson(val, jw_);
            }

            try jw_.endObject();
        },
        .Array => |array_list| {
            try jw_.beginArray();

            for (array_list.items) |item| {
                try jw_.arrayElem();
                try zombValueToJson(item, jw_);
            }

            try jw_.endArray();
        },
        .String => |slice| {
            try jw_.emitString(slice.items);
        },
    }
}
