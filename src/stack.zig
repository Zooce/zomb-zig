const std = @import("std");

const ZValue = @import("data.zig").ZValue;
const ZExpr = @import("data.zig").ZExpr;
const ZExprArg = @import("data.zig").ZExprArg;
const ZMacro = @import("data.zig").ZMacro;
const ConcatItem = @import("data.zig").ConcatItem;
const ConcatList = @import("data.zig").ConcatList;

const ReductionContext = @import("data.zig").ReductionContext;
const reduce = @import("data.zig").reduce;

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

pub const Stack = struct {
    const Self = @This();

    stack: std.ArrayList(StackElem),

    pub fn init(allocator_: *std.mem.Allocator) Self {
        return Self{
            .stack = std.ArrayList(StackElem).init(allocator_),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stack.deinit();
    }

    pub fn push(self: *Self, elem_: StackElem) !void {
        try self.stack.append(elem_);
    }

    pub fn consumeObjectEntry(self: *Self, allocator_: ?*std.mem.Allocator, macros_: std.StringArrayHashMap(ZMacro)) !void {
        const c_list = self.stack.pop().CList;
        const key = self.stack.pop().Key;
        switch (self.top().?) {
            .Val => |*val| switch (val.*) {
                .Object => |*obj| {
                    const val: ZValue = undefined;
                    try reduce(allocator_.?, c_list, &val, true, null, .{ .macros = macros_ });
                    try obj.*.putNoClobber(key, val);
                },
                else => return error.UnexpectedStackValue,
            },
            .CItem => |*citem| switch (citem.*) {
                .Object => |*obj| {
                    try obj.*.putNoClobber(key, c_list);
                },
                else => return error.UnexpectedStackValue,
            },
            else => return error.UnexpectedStackValue,
        }
    }

    pub fn consumeArrayItem(self: *Self, allocator_: ?*std.mem.Allocator, macros_: std.StringArrayHashMap(ZMacro)) !void {
        const c_list = self.stack.pop().CList;
        switch (self.top().?) {
            .Val => |*val| switch (val.*) {
                .Array => |*arr| {
                    const val: ZValue = undefined;
                    try reduce(allocator_.?, c_list, &val, true, null, .{ .macros = macros_ });
                    try arr.*.append(val);
                },
                else => return error.UnexpectedStackValue,
            },
            .CItem => |*citem| switch (citem.*) {
                .Array => |*arr| {
                    try arr.*.append(c_list);
                },
                else => return error.UnexpectedStackValue,
            },
            else => return error.UnexpectedStackValue,
        }
    }

    pub fn top(self: Self) ?*StackElem {
        if (self.stack.items.len == 0) {
            return null;
        }
        return &self.stack.items[self.stack.items.len - 1];
    }

    pub fn size(self: Self) usize {
        return self.stack.items.len;
    }
};
