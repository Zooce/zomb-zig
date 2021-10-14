const std = @import("std");
const StateMachine = @import("state_machine.zig").StateMachine;

pub const ZValue = union(enum) {
    Object: std.StringArrayHashMap(ZValue),
    Array: std.ArrayList(ZValue),
    String: std.ArrayList(u8),
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
        var all_accessors: ?std.ArrayList([]const u8) = null;
        if (self.accessors != null or ext_accessors_ != null) {
            all_accessors = std.ArrayList([]const u8).init(allocator_);
        }
        defer {
            if (all_accessors) |accessors| {
                accessors.deinit();
            }
        }
        if (self.accessors.items) |acs| {
            for (acs) |acc| {
                try all_accessors.append(acc);
            }
        }
        if (ext_accessors_) |eacs| {
            for (eacs) |eacc| {
                try all_accessors.append(eacc);
            }
        }

        const macro = macros_.get(self.key) orelse return error.MacroKeyNotFound;
        if (self.batch_args_list) |batch_args_list| {
            if (init_result_ and all_accessors == null) {
                result_ = .{ .Array = std.ArrayList(ZValue).init(allocator_) };
            }
            const accessor_index: ?usize = idxblk: {
                if (ext_accessors_) |eacs| {
                    break :idxblk try std.fmt.parseUnsigned(usize, eacs[0], 10);
                } else {
                    break :idxblk null;
                }
            };
            for (batch_args_list) |args, i| {
                if (accessor_index) |idx| if (idx != i) continue;
                const ctx = .{ .expr_args = self.args, .batch_args = args, .macros = macros_ };
                if (all_accessors) |acs| {
                    const accessors: ?[][]const u8 = if (acs.items.len > 1) acs.items[1..] else null;
                    return try reduce(allocator_, macro.value, result_, true, accessors, ctx);
                } else {
                    var value: ZValue = undefined;
                    _ = try reduce(allocator_, macro.value, &value, true, null, ctx);
                    try result_.Array.append(value);
                }
            }
        } else {
            const ctx = .{ .expr_args = self.args, .batch_args = null, .macros = macros_ };
            if (all_accessors) |acs| {
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
    expr_args: ?std.StringArrayHashMap(ZExprArg),
    batch_args: ?std.ArrayList(ConcatList),
    macros: std.StringArrayHashMap(ZMacro),
};
pub fn reduce
    ( allocator_: *std.mem.Allocator
    , concat_list_: ConcatList
    , result_: *ZValue
    , init_result_: bool
    , accessors_: ?[][]const u8
    , ctx_: ReductionContext
    ) anyerror!void
{
    // TODO: also deal with accessors
    _ = accessors_;
    if (concat_list_.items.len == 0) {
        return error.CannotReduceEmptyConcatList;
    }
    for (concat_list_) |concat_item, i| {
        const init_res = i == 0 and init_result_; // TODO: and ( accessors_ == null or accessors_.?.len == 0 )
        switch (concat_item) {
            .Object => |obj| {
                if (init_res) {
                    result_.* = .{ .Object = std.StringArrayHashMap(ZValue).init(allocator_) };
                }
                var citer = obj.iterator();
                while (citer.next()) |centry| {
                    const key = centry.key_ptr.*;
                    // TODO: if we have accessors and this key does not match the current accessor, continue
                    var val: ZValue = undefined;
                    // TODO: if we have more than one accessor pass the rest to reduce otherwise pass null
                    try reduce(allocator_, centry.value_ptr.*, &val, true, ctx_);
                    try result_.*.Object.putNoClobber(key, val);
                    // TODO: if we have accessors, return
                }
                // TODO: if we have accessors and we didn't find a match, continue to the next concat item
            },
            .Array => |arr| {
                if (init_res) {
                    result_.* = .{ .Array = std.ArrayList(ZValue).init(allocator_) };
                }
                for (arr) |citem| {
                    // TODO: if we have accessors and this index does not match the current accessor, continue
                    var val: ZValue = undefined;
                    // TODO: if we have more than one accessor pass the rest to reduce otherwise pass null
                    try reduce(allocator_, citem, &val, true, ctx_);
                    try result_.*.Array.append(val);
                    // TODO: if we have accessors, return
                }
                // TODO: if we have accessors and we didn't find a match, continue to the next concat item
            },
            .String => |str| {
                // TODO: if we have accessors, continue to the next concat item
                if (init_res) {
                    result_.* = .{ .String = std.ArrayList(u8).init(allocator_) };
                }
                try result_.*.String.appendSlice(str);
            },
            .Parameter => |par| {
                if (ctx_.expr_args) |args| {
                    const clist = blk: {
                        const arg = args.get(par) orelse return error.InvalidMacroParameter;
                        switch (arg) {
                            .CList => |clist| break :blk clist,
                            .BatchPlaceholder => break :blk ctx_.batch_args.?[args.getIndex(par)],
                        }
                    };
                    // TODO: pass the accessors along
                    // TODO: if we have more than one accessor pass the rest to reduce otherwise pass null
                    try reduce(allocator_, clist, result_, init_res, ctx_);
                    // TODO: if we have accessors, we need to know if this reduction actually reduced the clist, and if so then return
                } else {
                    return error.NoParamArgsProvided;
                }
            },
            .Expression => |exp| {
                // TODO: pass the accessors along
                // TODO: if we have more than one accessor pass the rest to evaluate otherwise pass null
                try exp.evaluate(allocator_, result_, init_res, ctx_.macros);
                // TODO: if we have accessors, we need to know if this evaluation actually succeeded, and if so then return
            },
        }
    }
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

// test "concat list reduction" {
//     var clist = .{ .CList = ConcatList.init(std.testing.allocator) };
//     try clist.CList.append(.{});
// }
