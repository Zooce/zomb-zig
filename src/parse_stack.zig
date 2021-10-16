const std = @import("std");
const StateMachine = @import("state_machine.zig").StateMachine;

pub const ZValue = union(enum) {
    Object: std.StringArrayHashMap(ZValue),
    Array: std.ArrayList(ZValue),
    String: std.ArrayList(u8),

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
    key: []const u8,
    args: ?std.StringArrayHashMap(ZExprArg) = null,
    accessors: ?std.ArrayList([]const u8) = null,
    batch_args_list: ?std.ArrayList(std.ArrayList(ConcatList)) = null,

    pub fn evaluate
        ( self: @This()
        , allocator_: *std.mem.Allocator
        , result_: *ZValue
        , init_result_: bool
        , ext_accessors_: ?[][]const u8
        , macros_: std.StringArrayHashMap(ZMacro)
        ) anyerror!bool
    {
        // set up a temporary list to concatenate our args and the external args
        var next_accessors: ?std.ArrayList([]const u8) = null;
        if (self.accessors != null or ext_accessors_ != null) {
            next_accessors = std.ArrayList([]const u8).init(allocator_);
        }
        defer {
            if (next_accessors) |accessors| {
                accessors.deinit();
            }
        }
        if (self.accessors) |acs| {
            for (acs.items) |acc| {
                try next_accessors.?.append(acc);
            }
        }
        if (ext_accessors_) |eacs| {
            for (eacs) |eacc| {
                try next_accessors.?.append(eacc);
            }
        }

        const macro = macros_.get(self.key) orelse return error.MacroKeyNotFound;
        if (self.batch_args_list) |batch_args_list| {
            if (init_result_ and next_accessors == null) {
                result_.* = .{ .Array = std.ArrayList(ZValue).init(allocator_) };
            }
            const accessor_index: ?usize = idxblk: {
                if (ext_accessors_) |eacs| {
                    break :idxblk try std.fmt.parseUnsigned(usize, eacs[0], 10);
                } else {
                    break :idxblk null;
                }
            };
            for (batch_args_list.items) |args, i| {
                if (accessor_index) |idx| if (idx != i) continue;
                const ctx = .{ .expr_args = self.args, .batch_args = args, .macros = macros_ };
                if (next_accessors) |acs| {
                    const accessors: ?[][]const u8 = if (acs.items.len > 1) acs.items[1..] else null;
                    return try reduce(allocator_, macro.value, result_, true, accessors, ctx);
                } else {
                    var value: ZValue = undefined;
                    _ = try reduce(allocator_, macro.value, &value, true, null, ctx);
                    try result_.*.Array.append(value);
                }
            }
        } else {
            const ctx = .{ .expr_args = self.args, .batch_args = null, .macros = macros_ };
            if (next_accessors) |acs| {
                const accessors: ?[][]const u8 = if (acs.items.len > 1) acs.items[1..] else null;
                return try reduce(allocator_, macro.value, result_, true, accessors, ctx);
            } else {
                _ = try reduce(allocator_, macro.value, result_, init_result_, null, ctx);
            }
        }
        return true;
    }
};
pub const ZExprArg = union(enum) {
    CList: ConcatList,
    BatchPlaceholder: void,
};
pub const ConcatItem = union(enum) {
    Object: std.StringArrayHashMap(ConcatList),
    Array: std.ArrayList(ConcatList),
    String: []const u8,
    Parameter: []const u8,
    Expression: ZExpr,
};
pub const ConcatList = std.ArrayList(ConcatItem);
pub const ZMacro = struct {
    const Self = @This();

    parameters: ?std.ArrayList([]const u8),
    value: ConcatList,
};
pub const ReductionContext = struct {
    expr_args: ?std.StringArrayHashMap(ZExprArg) = null,
    batch_args: ?std.ArrayList(ConcatList) = null,
    macros: std.StringArrayHashMap(ZMacro),
};
pub fn reduce
    ( allocator_: *std.mem.Allocator
    , concat_list_: ConcatList
    , result_: *ZValue
    , init_result_: bool
    , accessors_: ?[][]const u8
    , ctx_: ReductionContext
    ) anyerror!bool
{
    // TODO: also deal with accessors
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
                    const c_list = blk: {
                        const arg = args.get(par) orelse return error.InvalidMacroParameter;
                        switch (arg) {
                            .CList => |c_list| break :blk c_list,
                            .BatchPlaceholder => break :blk ctx_.batch_args.?.items[args.getIndex(par).?],
                        }
                    };
                    const did_reduce = try reduce(allocator_, c_list, result_, if (has_accessors) true else init_res, accessors_, ctx_);
                    if (has_accessors) {
                        return did_reduce;
                    }
                } else {
                    return error.NoParamArgsProvided;
                }
            },
            .Expression => |exp| {
                const did_evaluate = try exp.evaluate(allocator_, result_, if (has_accessors) true else init_res, accessors_, ctx_.macros);
                if (has_accessors) {
                    return did_evaluate;
                }
            },
        }
    }
    return true;
}
/// These are the things that may be placed on the parse stack.
pub const StackElem = union(enum) {
    Key: []const u8,

    // non-macro decl
    Val: ZValue,
    ExprArgList: std.ArrayList(ZExprArg),

    // limbo
    Expr: ZExpr,
    BSet: std.ArrayList(std.ArrayList(ConcatList)),
    BList: std.ArrayList(ConcatList),

    // macro-decl
    CList: ConcatList,
    CItem: ConcatItem,
    CExprArgList: std.ArrayList(ConcatList),
};

test "stack" {
    var stack = std.ArrayList(StackElem).init(std.testing.allocator);
    defer stack.deinit();
}

test "concat list of objects reduction - no macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c_list = ConcatList.init(&arena.allocator);

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
    try c_list.append(obj_0);
    try c_list.append(obj_1);

    // we need a macro map to call reduce() - we know it won't be used in this test, so just make an empty one
    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
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
    var c_list = ConcatList.init(&arena.allocator);

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
    try c_list.append(arr_0);
    try c_list.append(arr_1);

    // we need a macro map to call reduce() - we know it won't be used in this test, so just make an empty one
    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
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
    var c_list = ConcatList.init(&arena.allocator);

    // fill in the concat list
    try c_list.append(.{ .String = "a" });
    try c_list.append(.{ .String = "b" });

    const ctx = .{ .macros = std.StringArrayHashMap(ZMacro).init(&arena.allocator) };

    // get the result
    var result: ZValue = undefined;
    const did_reduce = try reduce(&arena.allocator, c_list, &result, true, null, ctx);
    try std.testing.expect(did_reduce);

    // test the result
    try std.testing.expect(result == .String);
    try std.testing.expectEqualStrings("ab", result.String.items);
}
