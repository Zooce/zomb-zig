const std = @import("std");

const util = @import("util.zig");

pub const ZValue = union(enum) {
    Object: std.StringArrayHashMap(ZValue),
    Array: std.ArrayList(ZValue),
    String: std.ArrayList(u8),

    pub fn format(value: ZValue, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }

    pub fn log(self: ZValue, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        switch (self) {
            .Object => |obj| {
                try writer.writeAll("ZValue.Object = {\n");
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try writer.print("{s} = ", .{entry.key_ptr.*});
                    try entry.value_ptr.*.log(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent * 2);
                try writer.writeAll("}\n");
            },
            .Array => |arr| {
                try writer.writeAll("ZValue.Array = [\n");
                for (arr.items) |item| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try item.log(writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent * 2);
                try writer.writeAll("]\n");
            },
            .String => |str| try writer.print("ZValue.String = {s}\n", .{str.items}),
        }
    }

    // TODO: is this even necessary? maybe for the case where an arena allocator wasn't used?
    pub fn deinit(self: *ZValue) void {
        switch (self) {
            .Object => |*obj| {
                var iter = obj.*.iterator();
                while (iter.next()) |*entry| {
                    entry.*.value_ptr.*.deinit();
                }
                obj.*.deinit();
            },
            .Array => |*arr| {
                for (arr.*.items) |*item| {
                    item.*.deinit();
                }
                arr.*.deinit();
            },
            .String => |*str| {
                str.*.deinit();
            },
        }
    }
};
pub const ZExpr = struct {
    const Self = @This();

    key: []const u8,
    args: ?std.StringArrayHashMap(ZExprArg) = null,
    accessors: ?std.ArrayList([]const u8) = null,
    batch_args_list: ?std.ArrayList(std.ArrayList(ConcatList)) = null,

    pub fn format(value: ZExpr, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }

    pub fn log(self: ZExpr, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        try writer.writeAll("ZExpr = {\n");

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.print("key = {s}\n", .{self.key});

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("args = ");
        if (self.args) |args| {
            try writer.writeAll("{\n");
            var iter = args.iterator();
            while (iter.next()) |entry| {
                try writer.writeByteNTimes(' ', (indent + 2) * 2);
                try writer.print("{s} = ", .{entry.key_ptr.*});
                try entry.value_ptr.*.log(writer, indent + 2);
            }
            try writer.writeByteNTimes(' ', (indent + 1) * 2);
            try writer.writeAll("}\n");
        } else {
            try writer.writeAll("null\n");
        }

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("accessors = ");
        if (self.accessors) |accessors| {
            try writer.writeAll("[\n");
            for (accessors.items) |accessor| {
                try writer.writeByteNTimes(' ', (indent + 2) * 2);
                try writer.print("{s}\n", .{accessor});
            }
            try writer.writeByteNTimes(' ', (indent + 1) * 2);
            try writer.writeAll("]\n");
        } else {
            try writer.writeAll("null\n");
        }

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("batch_args_set = ");
        if (self.batch_args_list) |batch_args_list| {
            try writer.writeAll("[\n");
            for (batch_args_list.items) |batch_args| {
                try writer.writeByteNTimes(' ', (indent + 2) * 2);
                try writer.writeAll("[\n");
                for (batch_args.items) |c_list| {
                    try writer.writeByteNTimes(' ', (indent + 3) * 2);
                    try logConcatList(c_list, writer, indent + 3);
                }
                try writer.writeByteNTimes(' ', (indent + 2) * 2);
                try writer.writeAll("]\n");
            }
            try writer.writeByteNTimes(' ', (indent + 1) * 2);
            try writer.writeAll("]\n");
        } else {
            try writer.writeAll("null\n");
        }

        try writer.writeByteNTimes(' ', indent * 2);
        try writer.writeAll("}\n");
    }

    pub fn setArgs
        ( self: *Self
        , allocator_: *std.mem.Allocator
        , args_: std.ArrayList(ZExprArg)
        , macros_: std.StringArrayHashMap(ZMacro)
        )
        !void
    {
        const macro = macros_.get(self.key) orelse return error.MacroKeyNotFound;
        self.args = std.StringArrayHashMap(ZExprArg).init(allocator_);
        for (macro.parameters.?.keys()) |key, i| {
            if (i < args_.items.len) {
                try self.args.?.putNoClobber(key, args_.items[i]);
            }
        }
    }

    pub fn evaluate
        ( self: Self
        , allocator_: *std.mem.Allocator
        , result_: *ZValue
        , init_result_: bool
        , ext_accessors_: ?[][]const u8
        , ctx_: ReductionContext
        )
        anyerror!bool
    {
        // get the macro for this expression
        const macro = ctx_.macros.get(self.key) orelse return error.MacroKeyNotFound;
        if (util.DEBUG) std.debug.print("evaluating macro -> {struct}", .{macro});

        // use the macro default args if necessary
        var expr_args: ?std.StringArrayHashMap(ConcatList) = null;
        defer {
            if (expr_args) |*eargs| {
                eargs.deinit();
            }
        }

        // set up a temporary list to concatenate our accessors and the external accessors
        var expr_accessors: ?std.ArrayList([]const u8) = null;
        defer {
            if (expr_accessors) |*accessors| {
                accessors.deinit();
            }
        }

        if (self.batch_args_list) |batch_args_list| {
            if (init_result_ and ext_accessors_ == null) {
                result_.* = .{ .Array = std.ArrayList(ZValue).init(allocator_) };
            }
            if (ext_accessors_) |eacs| {
                const idx = try std.fmt.parseUnsigned(usize, eacs[0], 10);
                expr_args = try self.exprArgs(allocator_, ctx_.expr_args, batch_args_list.items[idx], macro);
                const ctx = .{ .expr_args = expr_args, .macros = ctx_.macros };
                expr_accessors = try self.exprAccessors(allocator_, if (eacs.len > 1) eacs[1..] else null);
                return try reduce(allocator_, macro.value, result_, true, if (expr_accessors) |acs| acs.items else null, ctx);
            }
            for (batch_args_list.items) |batch_args| {
                expr_args = try self.exprArgs(allocator_, ctx_.expr_args, batch_args, macro);
                const ctx = .{ .expr_args = expr_args, .macros = ctx_.macros };
                var value: ZValue = undefined;
                _ = try reduce(allocator_, macro.value, &value, true, if (self.accessors) |acs| acs.items else null, ctx);
                try result_.*.Array.append(value);
            }
        } else {
            expr_args = try self.exprArgs(allocator_, ctx_.expr_args, null, macro);
            expr_accessors = try self.exprAccessors(allocator_, ext_accessors_);
            const ctx = .{ .expr_args = expr_args, .macros = ctx_.macros };
            if (expr_accessors) |acs| {
                return try reduce(allocator_, macro.value, result_, true, acs.items, ctx);
            } else {
                _ = try reduce(allocator_, macro.value, result_, init_result_, null, ctx);
            }
        }
        return true;
    }

    fn exprAccessors
        ( self: Self
        , allocator_: *std.mem.Allocator
        , ext_accessors_: ?[][]const u8
        )
        anyerror!?std.ArrayList([]const u8)
    {
        var expr_accessors: ?std.ArrayList([]const u8) = null;
        if (self.accessors != null or ext_accessors_ != null) {
            expr_accessors = std.ArrayList([]const u8).init(allocator_);
        }
        if (self.accessors) |acs| {
            for (acs.items) |acc| {
                try expr_accessors.?.append(acc);
            }
        }
        if (ext_accessors_) |eacs| {
            for (eacs) |eacc| {
                try expr_accessors.?.append(eacc);
            }
        }
        return expr_accessors;
    }

    fn exprArgs
        ( self: Self
        , allocator_: *std.mem.Allocator
        , ctx_args_: ?std.StringArrayHashMap(ConcatList)
        , batch_args_: ?std.ArrayList(ConcatList)
        , macro_: ZMacro
        )
        anyerror!?std.StringArrayHashMap(ConcatList)
    {
        if (self.args == null) {
            return null;
        }
        var expr_args = std.StringArrayHashMap(ConcatList).init(allocator_);
        var arg_iter = self.args.?.iterator();
        var bidx: usize = 0;
        while (arg_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            var res = try expr_args.getOrPut(key);
            if (res.found_existing) return error.DuplicateKey;
            res.value_ptr.* = ConcatList.init(allocator_);
            const val = entry.value_ptr.*;
            switch (val) {
                .CList => |*c_list| {
                    for (c_list.items) |item| {
                        switch (item) {
                            .Parameter => |p| {
                                for (ctx_args_.?.get(p).?.items) |p_item| {
                                    try res.value_ptr.*.append(p_item);
                                }
                            },
                            else => try res.value_ptr.*.append(item),
                        }
                    }
                },
                .BatchPlaceholder => {
                    for (batch_args_.?.items[bidx].items) |item| {
                        switch (item) {
                            .Parameter => |p| {
                                for (ctx_args_.?.get(p).?.items) |p_item| {
                                    try res.value_ptr.*.append(p_item);
                                }
                            },
                            else => try res.value_ptr.*.append(item),
                        }
                    }
                    bidx += 1;
                },
            }
        }

        // get the remaining default parameters
        if (self.args.?.count() < macro_.parameters.?.count()) {
            var def_arg_iter = macro_.parameters.?.iterator();
            while (def_arg_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (expr_args.contains(key)) {
                    continue;
                }
                const val = entry.value_ptr.*;
                if (val == null) {
                    return error.MissingDefaultValue;
                }
                try expr_args.putNoClobber(key, val.?);
            }
        }
        return expr_args;
    }
};
pub const ZExprArg = union(enum) {
    CList: ConcatList,
    BatchPlaceholder: void,

    pub fn format(value: ZExprArg, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }

    pub fn log(self: ZExprArg, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        try writer.writeAll("ZExprArg.");
        switch (self) {
            .CList => |list| try logConcatList(list, writer, indent),
            .BatchPlaceholder => try writer.writeAll("BatchPlaceholder\n"),
        }
    }
};
pub const ConcatItem = union(enum) {
    Object: std.StringArrayHashMap(ConcatList),
    Array: std.ArrayList(ConcatList),
    String: []const u8,
    Parameter: []const u8,
    Expression: ZExpr,

    pub fn format(value: ConcatItem, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }

    pub fn log(self: ConcatItem, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        switch (self) {
            .Object => |obj| {
                try writer.writeAll("ConcatItem.Object = {\n");
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try writer.print("{s} = ", .{entry.key_ptr.*});
                    try logConcatList(entry.value_ptr.*, writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent * 2);
                try writer.writeAll("}\n");
            },
            .Array => |arr| {
                try writer.writeAll("ConcatItem.Array = [\n");
                for (arr.items) |item| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try logConcatList(item, writer, indent + 1);
                }
                try writer.writeByteNTimes(' ', indent * 2);
                try writer.writeAll("]\n");
            },
            .String => |s| try writer.print("ConcatItem.String = {s}\n", .{s}),
            .Parameter => |p| try writer.print("ConcatItem.Parameter = {s}\n", .{p}),
            .Expression => |e| try e.log(writer, indent),
        }
    }
};
pub const ConcatList = std.ArrayList(ConcatItem);
fn logConcatList(list: ConcatList, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!util.DEBUG) return;
    try writer.writeAll("ConcatList = [\n");
    for (list.items) |citem| {
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try citem.log(writer, indent + 1);
    }
    try writer.writeByteNTimes(' ', indent * 2);
    try writer.writeAll("]\n");
}
pub const ZMacro = struct {
    parameters: ?std.StringArrayHashMap(?ConcatList) = null,
    value: ConcatList,

    pub fn format(value: ZMacro, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }

    pub fn log(self: ZMacro, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        try writer.writeAll("ZMacro = {\n");

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("parameters = ");
        if (self.parameters) |parameters| {
            try writer.writeAll("[\n");
            var iter = parameters.iterator();
            while (iter.next()) |entry| {
                try writer.writeByteNTimes(' ', (indent + 2) * 2);
                try writer.print("{s} = ", .{entry.key_ptr.*});
                if (entry.value_ptr.*) |default_value| {
                    try logConcatList(default_value, writer, indent + 2);
                } else {
                    try writer.writeAll("null\n");
                }
            }
            try writer.writeByteNTimes(' ', (indent + 1) * 2);
            try writer.writeAll("]\n");
        } else {
            try writer.writeAll("null\n");
        }

        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("value = ");
        try logConcatList(self.value, writer, indent + 1);

        try writer.writeByteNTimes(' ', indent * 2);
        try writer.writeAll("}\n");
    }
};
pub const ReductionContext = struct {
    expr_args: ?std.StringArrayHashMap(ConcatList) = null,
    macros: std.StringArrayHashMap(ZMacro),

    pub fn format(value: ReductionContext, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer);
    }

    pub fn log(self: ReductionContext, writer: anytype) std.os.WriteError!void {
        if (!util.DEBUG) return;
        try writer.writeAll("ReductionContext = {\n");

        try writer.writeAll("  expr_args = ");
        if (self.expr_args) |expr_args| {
            try writer.writeAll("{\n");
            var iter = expr_args.iterator();
            while (iter.next()) |entry| {
                try writer.print("    {s} = ", .{entry.key_ptr.*});
                try logConcatList(entry.value_ptr.*, writer, 3);
            }
        } else {
            try writer.writeAll("null\n");
        }

        try writer.writeAll("}\n");
    }
};
pub fn reduce
    ( allocator_: *std.mem.Allocator
    , concat_list_: ConcatList
    , result_: *ZValue
    , init_result_: bool
    , accessors_: ?[][]const u8
    , ctx_: ReductionContext
    )
    anyerror!bool
{
    if (util.DEBUG) {
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n---[Reducing ConcatList]---\n{struct}\n", .{ctx_});
        {
            try logConcatList(concat_list_, stderr, 0);
        }
        if (accessors_) |acs| {
            try stderr.writeAll("accessors = [\n");
            for (acs) |item| {
                try stderr.print("  {s}\n", .{item});
            }
            try stderr.writeAll("]\n");
        }
    }
    if (concat_list_.items.len == 0) {
        return error.CannotReduceEmptyConcatList;
    }
    const has_accessors = accessors_ != null and accessors_.?.len > 0;
    const array_index: usize = idxblk: {
        if (has_accessors) {
            break :idxblk std.fmt.parseUnsigned(usize, accessors_.?[0], 10) catch 0;
        }
        break :idxblk 0;
    };
    var array_size: usize = 0;
    for (concat_list_.items) |concat_item, i| {
        // we only want to initialize the result_ when:
        // 1. we're at the first concat item AND
        // 2. the caller wants it initialized AND
        // 3. there are no accessors left
        //      a. if there are accessors left, then there's no need to initialize the result yet since having accessors
        //         indicates that we want to drill down to get a specific value (i.e., there's no need to allocate
        //         memory for the 'outer/container' value of the actual value we want)
        const init_res = i == 0 and init_result_ and !has_accessors;
        switch (concat_item) {
            .Object => |obj| {
                if (init_res) {
                    result_.* = .{ .Object = std.StringArrayHashMap(ZValue).init(allocator_) };
                }
                var c_iter = obj.iterator();
                while (c_iter.next()) |c_entry| {
                    const key = c_entry.key_ptr.*;
                    if (has_accessors) {
                        // if this is NOT the key we're trying to access then let's check the next one
                        if (!std.mem.eql(u8, key, accessors_.?[0])) {
                            continue;
                        }
                        const accessors: ?[][]const u8 = if (accessors_.?.len > 1) accessors_.?[1..] else null;
                        return try reduce(allocator_, c_entry.value_ptr.*, result_, true, accessors, ctx_);
                    }
                    var val: ZValue = undefined;
                    _ = try reduce(allocator_, c_entry.value_ptr.*, &val, true, null, ctx_);
                    try result_.*.Object.putNoClobber(key, val);
                }
            },
            .Array => |arr| {
                if (init_res) {
                    result_.* = .{ .Array = std.ArrayList(ZValue).init(allocator_) };
                }
                array_size += arr.items.len;
                if (has_accessors) {
                    // if the array index is NOT within range then let's check the next concat item
                    if (array_index >= array_size) {
                        continue;
                    }
                    const accessors: ?[][]const u8 = if (accessors_.?.len > 1) accessors_.?[1..] else null;
                    return try reduce(allocator_, arr.items[array_index], result_, true, accessors, ctx_);
                }
                for (arr.items) |c_item| {
                    var val: ZValue = undefined;
                    _ = try reduce(allocator_, c_item, &val, true, null, ctx_);
                    try result_.*.Array.append(val);
                }
            },
            .String => |str| {
                if (has_accessors) return error.AttemptToAccessString;
                if (init_res) {
                    result_.* = .{ .String = std.ArrayList(u8).init(allocator_) };
                }
                try result_.*.String.appendSlice(str);
            },
            .Parameter => |par| {
                if (ctx_.expr_args) |args| {
                    const c_list = args.get(par) orelse return error.InvalidMacroParameter;
                    const did_reduce = try reduce(allocator_, c_list, result_, has_accessors or init_res, accessors_, ctx_);
                    if (has_accessors) {
                        return did_reduce;
                    }
                } else {
                    return error.NoParamArgsProvided;
                }
            },
            .Expression => |exp| {
                const did_evaluate = try exp.evaluate(allocator_, result_, has_accessors or init_res, accessors_, ctx_);
                if (has_accessors) {
                    return did_evaluate;
                }
            },
        }
    }

    if (util.DEBUG) {
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n---[Result]---\n{struct}\n", .{result_.*});
    }
    return true;
}

/// These are the things that may be placed on the parse stack.
pub const StackElem = union(enum) {
    TopLevelObject: std.StringArrayHashMap(ZValue),
    Key: []const u8,
    CList: ConcatList,
    CItem: ConcatItem,
    Placeholder: void,
    ExprArgList: std.ArrayList(ZExprArg),
    BSet: std.ArrayList(std.ArrayList(ConcatList)),
    ParamMap: ?std.StringArrayHashMap(?ConcatList),
    MacroDeclParam: []const u8,

    pub fn format(value: StackElem, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try value.log(writer, 0);
    }
    pub fn log(self: StackElem, writer: anytype, indent: usize) std.os.WriteError!void {
        if (!util.DEBUG) return;
        switch (self) {
            .TopLevelObject => |obj| {
                const o = ZValue{ .Object = obj };
                try o.log(writer, indent);
            },
            .Key => |k| try writer.print("Key = {s}\n", .{k}),
            .CList => |l| {
                try logConcatList(l, writer, indent);
            },
            .CItem => |c| try c.log(writer, indent),
            .Placeholder => try writer.writeAll("Placeholder\n"),
            .ExprArgList => |elist| {
                try writer.writeAll("ExprArgList = [\n");
                for (elist.items) |eitem| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try eitem.log(writer, indent + 1);
                }
                try writer.writeAll("]\n");
            },
            .BSet => |bset| {
                try writer.writeAll("BSet = [\n");
                for (bset.items) |arr| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try writer.writeAll("[\n");
                    for (arr.items) |item| {
                        try writer.writeByteNTimes(' ', (indent + 2) * 2);
                        try logConcatList(item, writer, indent + 2);
                    }
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try writer.writeAll("]\n");
                }
                try writer.writeAll("]\n");
            },
            .ParamMap => |pm| {
                if (pm) |map| {
                    try writer.writeAll("ParamMap = {\n");
                    var iter = map.iterator();
                    while (iter.next()) |entry| {
                        try writer.writeByteNTimes(' ', (indent + 1) * 2);
                        try writer.print("{s} = ", .{entry.key_ptr.*});
                        if (entry.value_ptr.*) |c_list| {
                            try logConcatList(c_list, writer, indent + 1);
                        } else {
                            try writer.writeAll("null\n");
                        }
                    }
                    try writer.writeAll("}\n");
                } else {
                    try writer.writeAll("ParamMap = null\n");
                }
            },
            .MacroDeclParam => |p| try writer.print("MacroDeclParam = {s}\n", .{p}),
        }
    }
};

//======================================================================================================================
//======================================================================================================================
//======================================================================================================================
//
//
// TESTS
//
//
//======================================================================================================================
//======================================================================================================================
//======================================================================================================================

test "concat list of objects reduction - no macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // object 0
    var obj_0 = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    var c_list_0 = ConcatList.init(&arena.allocator);
    try c_list_0.append(.{ .String = "b" });
    try obj_0.Object.putNoClobber("a", c_list_0);

    // object 1
    var obj_1 = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    var c_list_1 = ConcatList.init(&arena.allocator);
    try c_list_1.append(.{ .String = "d" });
    try obj_1.Object.putNoClobber("c", c_list_1);

    // fill in the concat list
    // { a = b } + { c = d }
    var c_list = ConcatList.init(&arena.allocator);
    try c_list.append(obj_0);
    try c_list.append(obj_1);

    // we need a macro map to call reduce() - we know it won't be used in this test, so just make an empty one
    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
    // { a = b, c = d }
    var result: ZValue = undefined;
    const did_reduce = try reduce(&arena.allocator, c_list, &result, true, null, ctx);
    try std.testing.expect(did_reduce);

    // test the result
    try std.testing.expect(result == .Object);
    const b = result.Object.get("a") orelse return error.KeyNotFound;
    const d = result.Object.get("c") orelse return error.KeyNotFound;
    try std.testing.expectEqualStrings("b", b.String.items);
    try std.testing.expectEqualStrings("d", d.String.items);
}

test "concat list of arrays reduction - no macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // array 0
    var arr_0 = .{ .Array = std.ArrayList(ConcatList).init(&arena.allocator) };
    var c_list_0 = ConcatList.init(&arena.allocator);
    try c_list_0.append(.{ .String = "a" });
    try arr_0.Array.append(c_list_0);

    // array 1
    var arr_1 = .{ .Array = std.ArrayList(ConcatList).init(&arena.allocator) };
    var c_list_1 = ConcatList.init(&arena.allocator);
    try c_list_1.append(.{ .String = "b" });
    try arr_1.Array.append(c_list_1);

    // fill in the concat list
    // [ a ] + [ b ]
    var c_list = ConcatList.init(&arena.allocator);
    try c_list.append(arr_0);
    try c_list.append(arr_1);

    // we need a macro map to call reduce() - we know it won't be used in this test, so just make an empty one
    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
    // [ a, b ]
    var result: ZValue = undefined;
    const did_reduce = try reduce(&arena.allocator, c_list, &result, true, null, ctx);
    try std.testing.expect(did_reduce);

    // test the result
    try std.testing.expect(result == .Array);
    try std.testing.expectEqualStrings("a", result.Array.items[0].String.items);
    try std.testing.expectEqualStrings("b", result.Array.items[1].String.items);
}

test "concat list of strings reduction - no macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // fill in the concat list
    // "a" + "b"
    var c_list = ConcatList.init(&arena.allocator);
    try c_list.append(.{ .String = "a" });
    try c_list.append(.{ .String = "b" });

    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
    // "ab"
    var result: ZValue = undefined;
    const did_reduce = try reduce(&arena.allocator, c_list, &result, true, null, ctx);
    try std.testing.expect(did_reduce);

    // test the result
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("ab", result.String.items);
}

test "macro expression evaluation - no accessors no batching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $greet(name) = "Hello, " + %name + "!"
    var value = ConcatList.init(&arena.allocator);
    try value.append(.{ .String = "Hello, " });
    try value.append(.{ .Parameter = "name" });
    try value.append(.{ .String = "!" });
    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("name", null);
    const macro = ZMacro{ .parameters = parameters, .value = value };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("greet", macro);

    // expression
    var c_list = ConcatList.init(&arena.allocator);
    try c_list.append(.{ .String = "Zooce" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("name", .{ .CList = c_list });
    const expr = ZExpr{ .key = "greet", .args = args };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // "Hello, Zooce!"
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("Hello, Zooce!", result.String.items);
}

test "macro expression object single accessor evaluation - no batching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $color(alpha) = {
    //     black = #000000 + %alpha
    //     red = #ff0000 + %alpha
    // }
    var black_val = ConcatList.init(&arena.allocator);
    try black_val.append(.{ .String = "#000000" });
    try black_val.append(.{ .Parameter = "alpha" });
    var red_val = ConcatList.init(&arena.allocator);
    try red_val.append(.{ .String = "#ff0000" });
    try red_val.append(.{ .Parameter = "alpha" });
    var color_obj = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    try color_obj.Object.putNoClobber("black", black_val);
    try color_obj.Object.putNoClobber("red", red_val);
    var color_val = ConcatList.init(&arena.allocator);
    try color_val.append(color_obj);

    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("alpha", null);
    const macro = ZMacro{ .parameters = parameters, .value = color_val };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("color", macro);

    // expression
    var alpha = ConcatList.init(&arena.allocator);
    try alpha.append(.{ .String = "ff" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("alpha", .{ .CList = alpha });
    var accessors = std.ArrayList([]const u8).init(&arena.allocator);
    try accessors.append("black");
    const expr = ZExpr{ .key = "color", .args = args, .accessors = accessors };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // "#000000ff"
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("#000000ff", result.String.items);
}

test "macro expression array single accessor evaluation - no batching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $jobs(name) = [
    //     %name + " - dog walker"
    //     %name + " - engineer"
    // ]
    var dog_walker_val = ConcatList.init(&arena.allocator);
    try dog_walker_val.append(.{ .Parameter = "name" });
    try dog_walker_val.append(.{ .String = " - dog walker" });
    var engineer_val = ConcatList.init(&arena.allocator);
    try engineer_val.append(.{ .Parameter = "name" });
    try engineer_val.append(.{ .String = " - engineer" });
    var jobs_obj = .{ .Array = std.ArrayList(ConcatList).init(&arena.allocator) };
    try jobs_obj.Array.append(dog_walker_val);
    try jobs_obj.Array.append(engineer_val);
    var jobs_val = ConcatList.init(&arena.allocator);
    try jobs_val.append(jobs_obj);

    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("name", null);
    const macro = ZMacro{ .parameters = parameters, .value = jobs_val };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("jobs", macro);

    // expression
    var name = ConcatList.init(&arena.allocator);
    try name.append(.{ .String = "Zooce" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("name", .{ .CList = name });
    var accessors = std.ArrayList([]const u8).init(&arena.allocator);
    try accessors.append("1");
    const expr = ZExpr{ .key = "jobs", .args = args, .accessors = accessors };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // "Zooce - engineer"
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("Zooce - engineer", result.String.items);
}

test "macro expression multiple accessor evaluation - no batching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $macro(p1) = {
    //     k1 = [ a b %p1 ]
    //     k2 = "hello dude"
    // }
    var a = ConcatList.init(&arena.allocator);
    try a.append(.{ .String = "a" });
    var b = ConcatList.init(&arena.allocator);
    try b.append(.{ .String = "b" });
    var p = ConcatList.init(&arena.allocator);
    try p.append(.{ .Parameter = "p1" });
    var k1_arr = .{ .Array = std.ArrayList(ConcatList).init(&arena.allocator) };
    try k1_arr.Array.append(a);
    try k1_arr.Array.append(b);
    try k1_arr.Array.append(p);
    var k1_val = ConcatList.init(&arena.allocator);
    try k1_val.append(k1_arr);
    var k2_val = ConcatList.init(&arena.allocator);
    try k2_val.append(.{ .String = "hello dude" });
    var macro_obj = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    try macro_obj.Object.putNoClobber("k1", k1_val);
    try macro_obj.Object.putNoClobber("k2", k2_val);
    var macro_val = ConcatList.init(&arena.allocator);
    try macro_val.append(macro_obj);

    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("p1", null);
    const macro = ZMacro{ .parameters = parameters, .value = macro_val };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("macro", macro);

    // expression
    var p1 = ConcatList.init(&arena.allocator);
    try p1.append(.{ .String = "Zooce" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("p1", .{ .CList = p1 });
    var accessors = std.ArrayList([]const u8).init(&arena.allocator);
    try accessors.append("k1");
    try accessors.append("1");
    const expr = ZExpr{ .key = "macro", .args = args, .accessors = accessors };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // "b"
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("b", result.String.items);
}

test "macro expression with default value evaluation - no accessors no batching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $greet(name, ack = "Hello") = %ack + ", " + %name + "!"
    var value = ConcatList.init(&arena.allocator);
    try value.append(.{ .Parameter = "ack" });
    try value.append(.{ .String = ", " });
    try value.append(.{ .Parameter = "name" });
    try value.append(.{ .String = "!" });
    var ack = ConcatList.init(&arena.allocator);
    try ack.append(.{ .String = "Hello" });
    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("name", null);
    try parameters.putNoClobber("ack", ack);
    const macro = ZMacro{ .parameters = parameters, .value = value };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("greet", macro);

    // expression
    var name_arg = ConcatList.init(&arena.allocator);
    try name_arg.append(.{ .String = "Zooce" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("name", .{ .CList = name_arg });
    const expr = ZExpr{ .key = "greet", .args = args };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // "Hello, Zooce!"
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("Hello, Zooce!", result.String.items);
}

test "batched macro expression evaluation - no accessors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $color(alpha, beta) = #ff0000 + %alpha + %beta
    var value = ConcatList.init(&arena.allocator);
    try value.append(.{ .String = "#ff0000" });
    try value.append(.{ .Parameter = "alpha" });
    try value.append(.{ .Parameter = "beta" });

    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("alpha", null);
    try parameters.putNoClobber("beta", null);
    const macro = ZMacro{ .parameters = parameters, .value = value };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("color", macro);

    // expression
    // $color(?, ff) % [
    //     [ 07 ]
    //     [ ff ]
    // ]
    var alpha1 = ConcatList.init(&arena.allocator);
    try alpha1.append(.{ .String = "07" });
    var alpha1_batch = std.ArrayList(ConcatList).init(&arena.allocator);
    try alpha1_batch.append(alpha1);
    var alpha2 = ConcatList.init(&arena.allocator);
    try alpha2.append(.{ .String = "ff" });
    var alpha2_batch = std.ArrayList(ConcatList).init(&arena.allocator);
    try alpha2_batch.append(alpha2);
    var batch_args_list = std.ArrayList(std.ArrayList(ConcatList)).init(&arena.allocator);
    try batch_args_list.append(alpha1_batch);
    try batch_args_list.append(alpha2_batch);
    var beta = ConcatList.init(&arena.allocator);
    try beta.append(.{ .String = "ff" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("alpha", .BatchPlaceholder);
    try args.putNoClobber("beta", .{ .CList = beta });
    const expr = ZExpr{ .key = "color", .args = args, .batch_args_list = batch_args_list };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // [ "#ff000007ff", "#ff0000ffff" ]
    try std.testing.expect(result == .Array);
    try std.testing.expectEqual(@as(usize, 2), result.Array.items.len);
    try std.testing.expectEqualStrings("#ff000007ff", result.Array.items[0].String.items);
    try std.testing.expectEqualStrings("#ff0000ffff", result.Array.items[1].String.items);
}

test "batched macro expression evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // macro
    // $color(alpha, beta) = {
    //     black = #000000 + %alpha + %beta
    //     red = #ff0000 + %alpha + %beta
    // }
    var black_val = ConcatList.init(&arena.allocator);
    try black_val.append(.{ .String = "#000000" });
    try black_val.append(.{ .Parameter = "alpha" });
    try black_val.append(.{ .Parameter = "beta" });
    var red_val = ConcatList.init(&arena.allocator);
    try red_val.append(.{ .String = "#ff0000" });
    try red_val.append(.{ .Parameter = "alpha" });
    try red_val.append(.{ .Parameter = "beta" });
    var color_obj = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    try color_obj.Object.putNoClobber("black", black_val);
    try color_obj.Object.putNoClobber("red", red_val);
    var color_val = ConcatList.init(&arena.allocator);
    try color_val.append(color_obj);

    var parameters = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try parameters.putNoClobber("alpha", null);
    try parameters.putNoClobber("beta", null);
    const macro = ZMacro{ .parameters = parameters, .value = color_val };

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);
    try macros.putNoClobber("color", macro);

    // expression
    // $color(?, ff).black % [
    //     [ 07 ]
    //     [ ff ]
    // ]
    var alpha1 = ConcatList.init(&arena.allocator);
    try alpha1.append(.{ .String = "07" });
    var alpha1_batch = std.ArrayList(ConcatList).init(&arena.allocator);
    try alpha1_batch.append(alpha1);
    var alpha2 = ConcatList.init(&arena.allocator);
    try alpha2.append(.{ .String = "ff" });
    var alpha2_batch = std.ArrayList(ConcatList).init(&arena.allocator);
    try alpha2_batch.append(alpha2);
    var batch_args_list = std.ArrayList(std.ArrayList(ConcatList)).init(&arena.allocator);
    try batch_args_list.append(alpha1_batch);
    try batch_args_list.append(alpha2_batch);
    var beta = ConcatList.init(&arena.allocator);
    try beta.append(.{ .String = "ff" });
    var args = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args.putNoClobber("alpha", .BatchPlaceholder);
    try args.putNoClobber("beta", .{ .CList = beta });
    var accessors = std.ArrayList([]const u8).init(&arena.allocator);
    try accessors.append("black");
    const expr = ZExpr{ .key = "color", .args = args, .accessors = accessors, .batch_args_list = batch_args_list };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // [ "#00000007ff", "#000000ffff" ]
    try std.testing.expect(result == .Array);
    try std.testing.expectEqual(@as(usize, 2), result.Array.items.len);
    try std.testing.expectEqualStrings("#00000007ff", result.Array.items[0].String.items);
    try std.testing.expectEqualStrings("#000000ffff", result.Array.items[1].String.items);
}

test "crazy batched macro expression inside another macro expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator);

    // macro a
    // $macro_a(a, b, c, d = "AF") = %a + %b + %c + %d
    var a_val = ConcatList.init(&arena.allocator);
    try a_val.append(.{ .Parameter = "a" });
    try a_val.append(.{ .Parameter = "b" });
    try a_val.append(.{ .Parameter = "c" });
    try a_val.append(.{ .Parameter = "d" });
    var a_params = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try a_params.putNoClobber("a", null);
    try a_params.putNoClobber("b", null);
    try a_params.putNoClobber("c", null);
    var d_par_def = ConcatList.init(&arena.allocator);
    try d_par_def.append(.{ .String = "AF" });
    try a_params.putNoClobber("d", d_par_def);
    const macro_a = ZMacro{ .parameters = a_params, .value = a_val };
    try macros.putNoClobber("macro_a", macro_a);

    // macro b
    // $macro_b(param) = {
    //     key = $macro_a(%param, ?, "Hello, World!") % [
    //         [ 100 ] [ %param ] [ 10000 ]
    //     ]
    // }
    var arg_1 = ConcatList.init(&arena.allocator);
    try arg_1.append(.{ .Parameter = "param" });
    var arg_3 = ConcatList.init(&arena.allocator);
    try arg_3.append(.{ .String = "Hello, World!" });
    var args_a = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args_a.putNoClobber("a", .{ .CList = arg_1 });
    try args_a.putNoClobber("b", .BatchPlaceholder);
    try args_a.putNoClobber("c", .{ .CList = arg_3 });
    var batch_1 = ConcatList.init(&arena.allocator);
    try batch_1.append(.{ .String = "100" });
    var batch_set_1 = std.ArrayList(ConcatList).init(&arena.allocator);
    try batch_set_1.append(batch_1);
    var batch_2 = ConcatList.init(&arena.allocator);
    try batch_2.append(.{ .Parameter = "param" });
    var batch_set_2 = std.ArrayList(ConcatList).init(&arena.allocator);
    try batch_set_2.append(batch_2);
    var batch_3 = ConcatList.init(&arena.allocator);
    try batch_3.append(.{ .String = "10000" });
    var batch_set_3 = std.ArrayList(ConcatList).init(&arena.allocator);
    try batch_set_3.append(batch_3);
    var batch_args_list = std.ArrayList(std.ArrayList(ConcatList)).init(&arena.allocator);
    try batch_args_list.append(batch_set_1);
    try batch_args_list.append(batch_set_2);
    try batch_args_list.append(batch_set_3);
    const key_expr = ZExpr{ .key = "macro_a", .args = args_a, .batch_args_list = batch_args_list };
    var key_val = ConcatList.init(&arena.allocator);
    try key_val.append(.{ .Expression = key_expr });
    var obj = .{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    try obj.Object.putNoClobber("key", key_val );
    var b_val = ConcatList.init(&arena.allocator);
    try b_val.append(obj);
    var b_params = std.StringArrayHashMap(?ConcatList).init(&arena.allocator);
    try b_params.putNoClobber("param", null);
    const macro_b = ZMacro{ .parameters = b_params, .value = b_val };
    try macros.putNoClobber("macro_b", macro_b);

    // expression
    // $macro_b("Zooce")
    var param = ConcatList.init(&arena.allocator);
    try param.append(.{ .String = "Zooce" });
    var args_b = std.StringArrayHashMap(ZExprArg).init(&arena.allocator);
    try args_b.putNoClobber("param", .{ .CList = param });
    const expr = ZExpr{ .key = "macro_b", .args = args_b };

    // evaluate the expression
    var result: ZValue = undefined;
    const did_evaluate = try expr.evaluate(&arena.allocator, &result, true, null, .{ .macros = macros });
    try std.testing.expect(did_evaluate);

    // test the result
    // { key = [ "Zooce100Hello, WorldAF", "ZooceZooceHello, WorldAF", "Zooce10000Hello, WorldAF" ] }
    try std.testing.expect(result == .Object);
    try std.testing.expectEqual(@as(usize, 1), result.Object.count());
    const key_arr = result.Object.get("key") orelse return error.KeyNotFound;
    try std.testing.expect(key_arr == .Array);
    try std.testing.expectEqual(@as(usize, 3), key_arr.Array.items.len);
    try std.testing.expectEqualStrings("Zooce100Hello, World!AF", key_arr.Array.items[0].String.items);
    try std.testing.expectEqualStrings("ZooceZooceHello, World!AF", key_arr.Array.items[1].String.items);
    try std.testing.expectEqualStrings("Zooce10000Hello, World!AF", key_arr.Array.items[2].String.items);
}

test "debug printing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const item_1 = ConcatItem{ .String = "item 1" };
    const item_2 = ConcatItem{ .String = "item 2" };
    var item_list = ConcatList.init(&arena.allocator);
    try item_list.append(item_1);
    try item_list.append(item_2);
    var c_arr = ConcatItem{ .Array = std.ArrayList(ConcatList).init(&arena.allocator) };
    try c_arr.Array.append(item_list);
    var arr_list = ConcatList.init(&arena.allocator);
    try arr_list.append(c_arr);
    var c_obj = ConcatItem{ .Object = std.StringArrayHashMap(ConcatList).init(&arena.allocator) };
    try c_obj.Object.putNoClobber("key", arr_list);

    std.debug.print("\n{union}\n", .{c_obj});
}
