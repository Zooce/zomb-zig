const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const TokenType = @import("token.zig").TokenType;
const Token = @import("token.zig").Token;
const State = @import("state_machine.zig").State;
const StateMachine = @import("state_machine.zig").StateMachine;

pub const ZombValue = union(enum) {
    Object: std.StringArrayHashMap(ZombValue),
    Array: std.ArrayList(ZombValue),
    String: std.ArrayList(u8),

    // fn access(self: ZombValue, alloc_: *std.mem.Allocator, accessors_: [][]const u8) anyerror!ZombValue {
    //     if (accessors_.len == 0) {
    //         return self;
    //     }
    //     var result: ZombValue = undefined;
    //     switch (self) {
    //         .Object => |obj| {
    //             const acc = accessors_[0];
    //             const entry = obj.getEntry(acc) orelse return error.KeyNotFound;
    //             if (accessors_.len > 1) {
    //                 return entry.value_ptr.*.access(accessors_[1..], alloc_);
    //             } else {
    //                 result = entry.value_ptr.*;
    //             }
    //         },
    //         .Array => |arr| {
    //             const idx = try std.fmt.parseUnsigned(usize, accessors_[0], 10);
    //             if (accessors_.len > 1) {
    //                 return arr.items[idx].access(accessors_[1..], alloc_);
    //             } else {
    //                 result = arr.items[idx];
    //             }
    //         },
    //         .String => return error.CannotUseAccessorForString,
    //     }
    //     switch (result) {
    //         .Object => |*robj| {
    //             var obj = std.StringArrayHashMap(ZombValue).init(alloc_);
    //             var iter = robj.iterator();
    //             while (iter.next()) |entry| {
    //                 const key = entry.key_ptr.*;
    //                 const val = entry.value_ptr.*;
    //             }
    //         }
    //     }
    // }

    fn copy(self: ZombValue, alloc_: *std.mem.Allocator) anyerror!ZombValue {
        var copy_val: ZombValue = undefined;
        switch (self) {
            .Object => |obj| {
                copy_val = .{ .Object = std.StringArrayHashMap(ZombValue).init(alloc_) };
                errdefer copy_val.Object.deinit();
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = try entry.value_ptr.*.copy(alloc_);
                    try copy_val.Object.putNoClobber(key, val);
                }
            },
            .Array => |arr| {
                copy_val = .{ .Array = std.ArrayList(ZombValue).init(alloc_) };
                errdefer copy_val.Array.deinit();
                for (arr.items) |item| {
                    try copy_val.Array.append(try item.copy(alloc_));
                }
            },
            .String => |str| {
                copy_val = .{ .String = std.ArrayList(u8).init(alloc_) };
                errdefer copy_val.String.deinit();
                try copy_val.String.appendSlice(str.items);
            },
        }
        return copy_val;
    }
};

pub const ZombMacroExpr = struct {
    key: []const u8,
    args: ?std.ArrayList(ExprArgType) = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const ExprArgType = union(enum) {
    Value: ZombValue,
    BatchPlaceholder: void, // TODO: maybe this should be an index or even the parameter name
};

const ZombStackType = union(enum) {
    Value: ZombValue,
    Expr: ZombMacroExpr,
    ExprArgs: std.ArrayList(ExprArgType),
    ExprArg: ExprArgType,
    Key: []const u8,
};

const ZombMacroValueMap = std.StringArrayHashMap(ZombMacroValue);
const ZombMacroValueArray = std.ArrayList(ZombMacroValue);
const ZombMacroDeclExpr = struct {
    key: []const u8,
    args: ?std.ArrayList(DeclExprArgType) = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const DeclExprArgType = union(enum) {
    Value: ZombMacroValue,
    BatchPlaceholder: void, // TODO: maybe this should be an index or even the parameter name
};

const ZombMacroObjectValue = union(enum) {
    Object: ZombMacroValueMap,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroArrayValue = union(enum) {
    Array: ZombMacroValueArray,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroStringValue = union(enum) {
    String: []const u8,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroDeclExprValue = union(enum) {
    Expr: ZombMacroDeclExpr,
    Parameter: []const u8,
};

const ZombMacroArg = union(enum) {
    Value: ZombValue,
    Parameter: []const u8,
};

const ZombMacroValue = union(enum) {
    ObjectList: std.ArrayList(ZombMacroObjectValue),
    ArrayList: std.ArrayList(ZombMacroArrayValue),
    StringList: std.ArrayList(ZombMacroStringValue),
    ExprList: std.ArrayList(ZombMacroDeclExprValue),

    /// This should be converted to one of the types above upon parsing the first
    /// non-Parameter type.
    ParameterList: std.ArrayList([]const u8),

    // TODO: change args_ to ?
    fn toZombValue(self: ZombMacroValue, alloc_: *std.mem.Allocator, params_: ?[][]const u8, args_: ?[]ExprArgType, macros_: std.StringArrayHashMap(ZombMacro), accessors_: ?[][]const u8) anyerror!ZombValue {
        const has_accessors = accessors_ != null and accessors_.?.len > 0;
        var value: ZombValue = undefined;
        switch (self) {
            .ObjectList => |object_list| {
                if (!has_accessors) {
                    // if we have accessors, there's no need to allocate memory for this entire object because we only
                    // want a part of it, so we'll allocate only the memory needed for the part we want to access
                    value = .{ .Object = std.StringArrayHashMap(ZombValue).init(alloc_) };
                }
                errdefer {
                    if (!has_accessors) {
                        value.Object.deinit();
                    }
                }
                for (object_list.items) |macro_object| {
                    switch (macro_object) {
                        .Object => |obj| {
                            var iter = obj.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (has_accessors) {
                                    if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                        continue;
                                    }
                                    if (accessors_.?.len > 1) {
                                        return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                    } else {
                                        return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                    }
                                }
                                // if we're here, then it means we have no accessors and we want the entire object
                                const val = try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Parameter => |p| {
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            var iter = args_.?[idx].Value.Object.iterator(); // TODO: what if this index is a batch placeholder ?
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (e.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(.{ .Value = try v.toZombValue(alloc_, params_, args_, macros_, null) });
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                // we need to evaluate this expression (we're expecting an object) and then we need to
                                // find the key for the accessor we're looking for
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                const expr_val = try macro.value.toZombValue(&temp_arena.allocator,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                // if (e.accessors) |accessors| {
                                //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                //     expr_val = try expr_val.access(accessors.items);
                                // }
                                var iter = expr_val.Object.iterator();
                                while (iter.next()) |entry| {
                                    const key = entry.key_ptr.*;
                                    if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                        continue;
                                    }
                                    return entry.value_ptr.*.copy(alloc_);
                                }
                            } else {
                                var expr_val = try macro.value.toZombValue(alloc_,
                                    if (macro.params) |p| p.keys() else null,
                                    if (args) |a| a.items else null,
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                var iter = expr_val.Object.iterator();
                                while (iter.next()) |entry| {
                                    const key = entry.key_ptr.*;
                                    const val = entry.value_ptr.*;
                                    try value.Object.putNoClobber(key, val);
                                }
                            }
                        },
                    }
                }
            },
            .ArrayList => |array_list| {
                if (!has_accessors) {
                    value = .{ .Array = std.ArrayList(ZombValue).init(alloc_) };
                }
                errdefer {
                    if (!has_accessors) {
                        value.Array.deinit();
                    }
                }
                const index: usize = idxblk: {
                    if (has_accessors) {
                        break :idxblk try std.fmt.parseUnsigned(usize, accessors_.?[0], 10);
                    }
                    break :idxblk 0;
                };
                var size: usize = 0;
                for (array_list.items) |macro_array| {
                    switch (macro_array) {
                        .Array => |arr| {
                            if (has_accessors) {
                                size += arr.items.len;
                                if (index >= size) {
                                    continue;
                                }
                                if (accessors_.?.len > 1) {
                                    return try arr.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                } else {
                                    return try arr.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                }
                            }
                            // if we're here, then we have no accessors and we just want the entire array
                            for (arr.items) |item| {
                                const val = try item.toZombValue(alloc_, params_, args_, macros_, null);
                                try value.Array.append(val);
                            }
                        },
                        .Parameter => |p| {
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            for (args_.?[idx].Value.Array.items) |val| {
                                try value.Array.append(val);
                            }
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (e.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(.{ .Value = try v.toZombValue(alloc_, params_, args_, macros_, null) });
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                const expr_val = try macro.value.toZombValue(&temp_arena.allocator,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                size += expr_val.Array.items.len;
                                if (index >= size) {
                                    continue;
                                }
                                // TODO: handle accessors on a ZombValue
                                // if (accessors_.?.len > 1) {
                                //     return try expr_val.Array.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                // } else {
                                //     return try expr_val.Array.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                // }
                            }

                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_,
                                if (e.accessors) |acc| acc.items else null);
                            // if (e.accessors) |accessors| {
                            //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                            //     expr_val = try expr_val.access(accessors.items);
                            // }
                            for (expr_val.Array.items) |item| {
                                try value.Array.append(item);
                            }
                        },
                    }
                }
            },
            .StringList => |string_list| {
                if (has_accessors) {
                    return error.CannotUseAccessorForString;
                }
                value = .{ .String = std.ArrayList(u8).init(alloc_) };
                errdefer value.String.deinit();
                for (string_list.items) |string| {
                    switch (string) {
                        .String => |str| try value.String.appendSlice(str),
                        .Parameter => |p| {
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            try value.String.appendSlice(args_.?[idx].Value.String.items);
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (e.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(.{ .Value = try v.toZombValue(alloc_, params_, args_, macros_, null) });
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_,
                                if (e.accessors) |acc| acc.items else null);
                            // if (e.accessors) |accessors| {
                            //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                            //     expr_val = try expr_val.access(accessors.items);
                            // }
                            try value.String.appendSlice(expr_val.String.items);
                        },
                    }
                }
            },
            .ParameterList => |param_list| {
                if (has_accessors) {
                    return error.CannotUseAccessorForParameter;
                }
                var allocated = false;
                errdefer { // TODO: is this necessary for this case?
                    if (allocated) {
                        switch (value) {
                            .Object => value.Object.deinit(),
                            .Array => value.Array.deinit(),
                            .String => value.String.deinit(),
                        }
                    }
                }
                for (param_list.items) |param, i| {
                    const idx = try indexOfString(params_.?, param);
                    const arg = args_.?[idx]; // TODO: what if this is a Parameter?
                    if (i == 0) {
                        // TODO: is this making a copy of the arg or is it a pointer to the arg itself?
                        // TODO: what if this is a placeholder instead of a value?
                        value = arg.Value;
                        allocated = true;
                        continue;
                    }
                    // TODO: what if arg is a placeholder?
                    switch (value) {
                        .Object => |*object| {
                            var iter = arg.Value.Object.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try object.*.putNoClobber(key, val);
                            }
                        },
                        .Array => |*array| {
                            for (arg.Value.Array.items) |item| {
                                try array.*.append(item);
                            }
                        },
                        .String => |*string| {
                            try string.*.appendSlice(arg.Value.String.items);
                        },
                    }
                }
            },
            .ExprList => |expr_list| {
                var allocated = false;
                errdefer { // TODO: is this necessary for this case?
                    if (allocated) {
                        switch (value) {
                            .Object => value.Object.deinit(),
                            .Array => value.Array.deinit(),
                            .String => value.String.deinit(),
                        }
                    }
                }
                var size: usize = 0; // in case this expr list is evaluated to an array
                for (expr_list.items) |macro_expr, i| {
                    switch (macro_expr) {
                        .Expr => |expr| {
                            const args = getargs: {
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (expr.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(.{ .Value = try v.toZombValue(alloc_, params_, args_, macros_, null) });
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(expr.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                // we need to evaluate this expression (we're expecting an object) and then we need to
                                // find the key for the accessor we're looking for
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                var expr_val = try macro.value.toZombValue(alloc_,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (expr.accessors) |acc| acc.items else null);
                                // if (expr.accessors) |accessors| {
                                //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                //     expr_val = try expr_val.access(accessors.items);
                                // }
                                if (i == 0) {
                                    value = expr_val;
                                    allocated = true;
                                    continue;
                                }
                                switch (expr_val) {
                                    .Object => |object| {
                                        var iter = object.iterator();
                                        while (iter.next()) |entry| {
                                            const key = entry.key_ptr.*;
                                            if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                                continue;
                                            }
                                            // TODO: handle accessors on ZombValue
                                            // if (accessors_.?.len > 1) {
                                            //     return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                            // } else {
                                            //     return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                            // }
                                        }
                                    },
                                    .Array => |array| {
                                        size += array.items.len;
                                        const index = try std.fmt.parseUnsigned(usize, accessors_.?[0], 10);
                                        if (index >= size) {
                                            continue;
                                        }
                                        // TODO: handle accessors on ZombValue
                                        // if (accessors_.?.len > 1) {
                                        //     return try array.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                        // } else {
                                        //     return try array.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                        // }
                                    },
                                    .String => return error.CannotUseAccessorForString,
                                }
                            }
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_,
                                if (expr.accessors) |acc| acc.items else null);
                            // if (expr.accessors) |accessors| {
                            //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                            //     expr_val = try expr_val.access(accessors.items);
                            // }
                            if (i == 0) {
                                value = expr_val;
                                allocated = true;
                                continue;
                            }
                            switch (value) {
                                .Object => |*object| {
                                    var iter = expr_val.Object.iterator();
                                    while (iter.next()) |entry| {
                                        const key = entry.key_ptr.*;
                                        const val = entry.value_ptr.*;
                                        try object.*.putNoClobber(key, val);
                                    }
                                },
                                .Array => |*array| {
                                    for (expr_val.Array.items) |item| {
                                        try array.*.append(item);
                                    }
                                },
                                .String => |*string| {
                                    try string.*.appendSlice(expr_val.String.items);
                                },
                            }
                        },
                        .Parameter => |p| {
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
                            const idx = try indexOfString(params_.?, p);
                            var arg = args_.?[idx];
                            // TODO: what if arg is a placeholder?
                            if (i == 0) {
                                value = arg.Value;
                                allocated = true;
                                continue;
                            }
                            switch (value) {
                                .Object => |*object| {
                                    var iter = arg.Value.Object.iterator();
                                    while (iter.next()) |entry| {
                                        const key = entry.key_ptr.*;
                                        const val = entry.value_ptr.*;
                                        try object.*.putNoClobber(key, val);
                                    }
                                },
                                .Array => |*array| {
                                    for (arg.Value.Array.items) |item| {
                                        try array.*.append(item);
                                    }
                                },
                                .String => |*string| {
                                    try string.*.appendSlice(arg.Value.String.items);
                                },
                            }
                        },
                    }
                }
            }
        }
        return value;
    }
};

fn indexOfString(source_: [][]const u8, target_: []const u8) !usize {
    for (source_) |item, i| {
        if (std.mem.eql(u8, item, target_)) {
            return i;
        }
    }
    return error.NoIndexForString;
}

const ZombMacroStackType = union(enum) {
    List: ZombMacroValue,
    Object: ZombMacroObjectValue,
    Array: ZombMacroArrayValue,
    Expr: ZombMacroDeclExprValue,
    ExprArgs: std.ArrayList(DeclExprArgType),
    ExprArg: DeclExprArgType,
    Key: []const u8,
    Empty: void, // the starting element -- for parsing
};

pub const ZombMacro = struct {
    /// This map is used to count the number of parameter uses in the macro value. After the macro
    /// has been fully parsed, we check to make sure each entry is greater than zero.
    params: ?std.StringArrayHashMap(u32) = null,

    /// The actual value of this macro.
    value: ZombMacroValue = undefined,

    /// A list of macro expression keys used inside this macro. Used for detecting recursion.
    macro_exprs: ?std.ArrayList([]const u8) = null,
};

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMap(ZombValue),

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

const StackBits = u128;
const stack_shift = 4;
pub const max_stack_size = @bitSizeOf(StackBits) / stack_shift; // add more stacks if we need more?

pub const Parser = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,

    input: []const u8 = undefined,

    tokenizer: Tokenizer,

    state: State = .Decl,
    state_machine: StateMachine = StateMachine{},

    zomb_value_stack: std.ArrayList(ZombStackType) = undefined,

    macro_ptr: ?*ZombMacro = null,
    zomb_macro_value_stack: std.ArrayList(ZombMacroStackType) = undefined,
    macro_map: std.StringArrayHashMap(ZombMacro) = undefined,

    token: ?Token = null,

    pub fn init(input_: []const u8, alloc_: *std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(alloc_),
            .input = input_,
            .tokenizer = Tokenizer.init(input_),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Self, allocator_: *std.mem.Allocator) !Zomb {
        // initialize some temporary memory we need for parsing
        self.zomb_value_stack = std.ArrayList(ZombStackType).init(&self.arena.allocator);
        self.zomb_macro_value_stack = std.ArrayList(ZombMacroStackType).init(&self.arena.allocator);
        self.macro_map = std.StringArrayHashMap(ZombMacro).init(&self.arena.allocator);

        // this arena will be given to the caller so they can clean up the memory we allocate for the ZOMB types
        var out_arena = std.heap.ArenaAllocator.init(allocator_);
        errdefer out_arena.deinit();

        // add the implicit top-level object to our type stack
        try self.zomb_value_stack.append(.{ .Value = .{ .Object = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator) } });

        // our macro stack always has an empty first element
        try self.zomb_macro_value_stack.append(ZombMacroStackType.Empty);

        var done = false;
        while (!done) {
            try self.log();
            try self.step(&out_arena);
            done = self.token != null;
        }

        if (self.zomb_value_stack.items.len > 1) {
            switch (self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1]) {
                .Expr => {
                    const value = try self.evaluateMacroExpr(&out_arena.allocator, self.zomb_value_stack.pop().Expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                },
                .ExprArgs => {
                    var args = self.zomb_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                    expr.*.args = args;
                    const value = try self.evaluateMacroExpr(&out_arena.allocator, self.zomb_value_stack.pop().Expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                },
                .Value => {},
                else => return error.UnexpectedStackTop,
            }
            try self.stackConsumeKvPair();
        }
        return Zomb{
            .arena = out_arena,
            .map = self.zomb_value_stack.pop().Value.Object,
        };
    }

    /// Process the current token based on the current state, transition to the
    /// next state, and update the current token if necessary.
    ///
    /// NOTE: Any time you see a `return` in this function, it means we do not
    ///       want to transition to the next state and we also want to keep the
    ///       current token.
    pub fn step(self: *Self, out_arena_: *std.heap.ArenaAllocator) !void {
        // comments are ignored everywhere - make sure to get the next token as well
        if (self.token == null or self.token.?.token_type == .Comment) {
            self.token = try self.tokenizer.next();
            return;
        }
        // get the token slice for convenience
        const token_slice = try self.token.?.slice(self.input);
        var keep_token = false;
        // process the current token based on our current state
        switch (self.state_machine.state) {
            .Decl => {
                // TODO: try NOT to have this "lagging" consume
                if (self.macro_ptr) |macro_ptr| {
                    macro_ptr.*.value = self.zomb_macro_value_stack.pop().List;
                    if (macro_ptr.*.params) |params| {
                        var iter = params.iterator();
                        while (iter.next()) |entry| {
                            if (entry.value_ptr.* == 0) {
                                // TODO: log which parameter was not used
                                return error.UnusedMacroParameter;
                            }
                        }
                    }
                } else if (self.zomb_value_stack.items.len > 1) {
                    try self.stackConsumeKvPair();
                }
                self.macro_ptr = null; // don't free memory - this was just a pointer to memory we're managing elsewhere
                keep_token = true;
            },
            .ObjectBegin => {
                // var obj = if (self.macro_ptr) |_| {
                //     .{ .Val = .{ .Object = std.StringArrayHashMap(ConcatList).init(&self.arena.allocator) } }
                // } else {
                //     .{ .Val = .{ .Value = .{ .Object = std.StringArrayHashMap(ZValue).init(&out_arena_.allocator) } } }
                // };
                // try self.stack.append(obj);
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(.{ .Object = .{ .Object = ZombMacroValueMap.init(&self.arena.allocator) } });
                } else {
                    try self.zomb_value_stack.append(.{ .Value = .{ .Object = std.StringArrayHashMap(ZombValue).init(&out_arena_.allocator) } });
                }
            },
            .Key => {
                // self.stack.append(.{ .Key = token_slice });
                const key = .{ .Key = token_slice };
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(key);
                } else {
                    try self.zomb_value_stack.append(key);
                }
            },
            .Equals => {
                // try self.stack.append(.{ .List = std.ArrayList(ConcatItem).init(&self.arena.allocator) });
            },
            .ConsumeObjectEntry => {
                // const concat_list = self.stack.pop().Val.List;
                // const key = self.stack.pop().Key;
                if (self.macro_ptr) |_| {
                    // var obj_ptr = &self.stack.items[self.stack.items.len - 1].Val.Object;
                    // try obj_ptr.*.put(key, concat_list);
                    const val = self.zomb_macro_value_stack.pop().List;
                    const key = self.zomb_macro_value_stack.pop().Key;
                    var object_ptr = try self.macroStackTop();
                    try object_ptr.*.Object.Object.put(key, val);
                } else {
                    // TODO: convert concat_list to ZombValue using the out_arena_ allocator
                    // defer concat_list.deinit(); // don't need to keep the concat list for non-macro values
                    // const val = try reduceToZValue(concat_list, &out_arena_.allocator);
                    // var obj_ptr = &self.stack.items[self.stack.items.len - 1].Val.Value.Object;
                    // try obj_ptr.*.put(key, val);
                    try self.stackConsumeKvPair();
                }
                keep_token = true;
            },
            .ObjectEnd => switch (self.token.?.token_type) {
                .String => keep_token = true,
                .CloseCurly => {
                    // TODO: update for single stack design
                    if (self.macro_ptr) |_| {
                        // TODO: the object on the top of the stack needs to be placed into the concat list
                        // const object = self.stack.pop().Val.Object;
                        // var concat_list = &self.stack.items[self.stack.items.len - 1].Val.List;
                        // try concat_list.*.append(object);
                        const object = self.zomb_macro_value_stack.pop().Object;
                        var list_ptr = try self.macroStackTop();
                        try list_ptr.*.List.ObjectList.append(object);
                    }
                    else {
                        // TODO: we don't need the parse value type any more
                        // const object = self.stack.pop().Val;
                        // _ = object;
                    }
                },
                else => {},
            },

            // Arrays
            .ArrayBegin => {
                // TODO: store the current allocator (i.e. we shouldn't need to check for self.macro_ptr all the time)
                // var alloc_ptr = if (self.macro_ptr) |_| {
                //     &self.arena.allocator
                // } else {
                //     &out_arena_.allocator
                // };
                // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                // try concat_list.append(.{ .Value = .{ .Array = std.ArrayList(ZValue).init(alloc_ptr) } });
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(.{ .Array = .{ .Array = ZombMacroValueArray.init(&self.arena.allocator) } });
                } else {
                    try self.zomb_value_stack.append(.{ .Value = .{ .Array = std.ArrayList(ZombValue).init(&out_arena_.allocator) } });
                }
            },
            .ConsumeArrayItem => {
                // TODO: update for single stack design
                if (self.macro_ptr) |_| {
                    const val = self.zomb_macro_value_stack.pop();
                    var array_ptr = try self.macroStackTop();
                    try array_ptr.*.Array.Array.append(val.List);
                } else {
                    const val = self.zomb_value_stack.pop().Value;
                    var array = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Value.Array;
                    try array.append(val);
                }
                keep_token = true;
            },
            .ArrayEnd => switch (self.token.?.token_type) {
                .CloseSquare => {
                    // TODO: update for single stack design
                    if (self.macro_ptr) |_| {
                        const array = self.zomb_macro_value_stack.pop().Array;
                        var list_ptr = try self.macroStackTop();
                        try list_ptr.*.List.ArrayList.append(array);
                    }
                },
                else => keep_token = true,
            },

            .Value => switch (self.token.?.token_type) {
                // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                .String, .RawString => {
                    // try concat_list.append(.{ .Value = .{ .String = token_slice } });
                    if (self.macro_ptr) |_| {
                        // top of the stack should be a String
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) {
                                .StringList => |*strings| try strings.append(.{ .String = token_slice }),
                                .ParameterList => |params| {
                                    // create a new string list
                                    var string_list = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) };
                                    // copy the params to the new string list and get rid of the old param list
                                    for (params.items) |p| try string_list.StringList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    // save the new string list
                                    try self.zomb_macro_value_stack.append(.{ .List = string_list });
                                    return;
                                },
                                else => return error.UnexpectedStringValueMacroStackType,
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedStringValueMacroStackType,
                        }
                    } else {
                        var top = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1];
                        switch (top.*) {
                            .Value => |*elem| switch (elem.*) {
                                .String => |*str| try str.appendSlice(token_slice),
                                .Array => {
                                    try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena_.allocator) } });
                                    return;
                                },
                                else => return error.UnexpectedStackValue,
                            },
                            .Key, .ExprArgs => {
                                try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena_.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedStackValue,
                        }
                    }
                },
                .MacroParamKey => {
                    if (self.macro_ptr) |macro_ptr| {
                        if (macro_ptr.*.params.?.getPtr(token_slice)) |p| {
                            p.* += 1; // count the usage of this parameter - TODO: is there a bug here? also can't we just use a boolean?
                        } else {
                            return error.InvalidParameterUse;
                        }
                        // try concat_list.append(.{ .Param = token_slice });
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) { // TODO: this might need some work -- I think there's a bug here...
                                .ObjectList => |*objects| try objects.append(.{ .Parameter = token_slice }),
                                .ArrayList => |*arrays| try arrays.append(.{ .Parameter = token_slice }),
                                .StringList => |*strings| try strings.append(.{ .Parameter = token_slice }),
                                .ExprList => |*exprs| try exprs.append(.{ .Parameter = token_slice }),
                                .ParameterList => |*params| try params.append(token_slice),
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ParameterList = std.ArrayList([]const u8).init(&self.arena.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedMacroParamKeyValueMacroStackType,
                        }
                    } else {
                        return error.MacroParamKeyUsedOutsideMacroDecl;
                    }
                },
                .MacroKey => {
                    // TODO: nothing to add to the stack, just keep the token
                    if (self.macro_ptr) |_| {
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) {
                                .ParameterList => |params| {
                                    var expr_list = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) };
                                    for (params.items) |p| try expr_list.ExprList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    try self.zomb_macro_value_stack.append(.{ .List = expr_list });
                                },
                                else => {},
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) } });
                            },
                            else => return error.UnexpectedMacroStackTop,
                        }
                    }
                    keep_token = true;
                },
                .OpenCurly => {
                    // TODO: nothing to add to the stack, just keep the token
                    if (self.macro_ptr) |_| {
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |list_type| switch (list_type) {
                                .ObjectList => {},
                                .ParameterList => |params| {
                                    var object_list = .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) };
                                    for (params.items) |p| try object_list.ObjectList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    try self.zomb_macro_value_stack.append(.{ .List = object_list });
                                },
                                else => return error.UnexpectedMacroStackList,
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) } });
                            },
                            else => return error.UnexpectedMacroStackTop,
                        }
                    }
                    keep_token = true;
                },
                .OpenSquare => {
                    // TODO: nothing to add to the stack, just keep the token
                    if (self.macro_ptr) |_| {
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |list_type| switch (list_type) {
                                .ArrayList => {},
                                .ParameterList => |params| {
                                    var array_list = .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) };
                                    for (params.items) |p| try array_list.ArrayList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    try self.zomb_macro_value_stack.append(.{ .List = array_list });
                                },
                                else => return error.UnexpectedMacroStackList,
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) } });
                            },
                            else => return error.UnexpectedMacroStackTop,
                        }
                    }
                    keep_token = true;
                },
                .CloseSquare => keep_token = true, // empty array
                else => {},
            },
            .ValueConcat => if (self.token.?.token_type != .Plus) {
                keep_token = true;
            },

            // Macro Declaration
            .MacroDeclKey => { // TODO: combine this with the Key state?
                var res = try self.macro_map.getOrPut(token_slice);
                if (res.found_existing) return error.DuplicateMacroName;
                res.value_ptr.* = ZombMacro{};
                self.macro_ptr = res.value_ptr;
            },
            .MacroDeclOptionalParams => if (self.token.?.token_type == .OpenParen) {
                self.macro_ptr.?.*.params = std.StringArrayHashMap(u32).init(&self.arena.allocator);
            },
            .MacroDeclParams => switch (self.token.?.token_type) {
                .String => {
                    var res = try self.macro_ptr.?.*.params.?.getOrPut(token_slice);
                    if (res.found_existing) return error.DuplicateMacroParamName;
                    res.value_ptr.* = 0;
                },
                .CloseParen => if (self.macro_ptr.?.*.params.?.count() == 0) {
                    return error.EmptyMacroDeclParams;
                },
                else => {}, // state machine will catch unexpected token errors
            },

            // Macro Expression
            .MacroExprKey => {
                // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                // try concat_list.append(.{ .Expr = .{ .key = token_slice } });
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(.{ .Expr = .{ .Expr = ZombMacroDeclExpr{ .key = token_slice } } });
                } else {
                    try self.zomb_value_stack.append(.{ .Expr = ZombMacroExpr{ .key = token_slice } });
                }
            },
            .MacroExprOptionalArgs => keep_token = true,
            .MacroExprOptionalAccessors => {
                if (self.token.?.token_type == .MacroAccessor) {
                    // var expr = &self.stack.items[self.stack.items.len - 1].Expr;
                    // if (expr.*.accessors == null) {
                    //     expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                    // }
                    if (self.macro_ptr) |_| {
                        var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr.Expr;
                        if (expr.*.accessors == null) {
                            expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                        }
                    } else {
                        var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                        if (expr.*.accessors == null) {
                            expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                        }
                    }
                }
                keep_token = true;
            },
            .MacroExprAccessors => switch (self.token.?.token_type) {
                .MacroAccessor => {
                    // var expr = &self.stack.items[self.stack.items.len - 1].Expr;
                    // try expr.*.accessors.?.append(token_slice);
                    if (self.macro_ptr) |_| {
                        var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr.Expr;
                        try expr.*.accessors.?.append(token_slice);
                    } else {
                        var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                        try expr.*.accessors.?.append(token_slice);
                    }
                },
                else => keep_token = true,
            },
            .ConsumeMacroExprArgs => {
                // TODO: update for single stack design
                // TODO: update for expression batching
                // var isBatch = false;
                if (self.macro_ptr) |_| {
                    var args = self.zomb_macro_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr;
                    expr.*.Expr.args = args;
                    // TODO: iterate through args - if `?` is found, this is a batch
                } else {
                    var args = self.zomb_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                    expr.*.args = args;
                    // TODO: iterate through args - if `?` is found, this is a batch
                }
                // TODO: if `isBatch == true` go to new stage to wait for `%`
                keep_token = true;
            },
            .MacroExprEval => {
                // var expr = self.stack.pop().Expr;
                if (self.macro_ptr) |_| {
                    // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                    // try concat_list.append(expr);
                    var expr = self.zomb_macro_value_stack.pop().Expr;
                    var list = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].List.ExprList;
                    try list.append(expr);
                } else {
                    // var value = try self.evaluateMacroExpr(&out_arena_.allocator, expr);
                    // try self.stack.append(.{ .Value = value });
                    var expr = self.zomb_value_stack.pop().Expr;
                    var value = try self.evaluateMacroExpr(&out_arena_.allocator, expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                }
                keep_token = true;
            },

            // Macro Expression Arguments
            .MacroExprArgsBegin => {
                // try self.stack.append(.{ .ExprArgList = std.ArrayList(ExprArgType).init(&self.arena.allocator) });
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(.{ .ExprArgs = std.ArrayList(DeclExprArgType).init(&self.arena.allocator) });
                } else {
                    try self.zomb_value_stack.append(.{ .ExprArgs = std.ArrayList(ExprArgType).init(&self.arena.allocator) });
                }
            },
            .ConsumeMacroExprArg => {
                // const arg = self.stack.pop().ExprArg;
                // var arg_list = &self.stack.items[self.stack.items.len - 1].ExprArgList;
                // try arg_list.append(arg);
                if (self.macro_ptr) |_| {
                    const val = self.zomb_macro_value_stack.pop().ExprArg;
                    var args = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].ExprArgs;
                    try args.append(val);
                } else {
                    const arg = self.zomb_value_stack.pop().ExprArg;
                    var args = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].ExprArgs;
                    try args.append(arg);
                }
                keep_token = true;
            },
            .MacroExprArgsEnd => if (self.token.?.token_type != .CloseParen) {
                keep_token = true;
            },
        }
        // transition to the next state
        try self.state_machine.transition(self.token.?.token_type);
        // get a new token if necessary - we must do this _after_ the state machine transition
        if (!keep_token) {
            self.token = try self.tokenizer.next();
        }
    }

    //=============
    // Macro Stacks

    fn macroStackTop(self: Self) !*ZombMacroStackType {
        const len = self.zomb_macro_value_stack.items.len;
        if (len == 0) {
            return error.MacroStackEmpty;
        }
        return &self.zomb_macro_value_stack.items[len - 1];
    }

    //================================
    // ZombValue Consumption Functions

    fn stackConsumeKvPair(self: *Self) !void {
        const val = self.zomb_value_stack.pop().Value;
        const key = self.zomb_value_stack.pop().Key;
        var object = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Value.Object;
        try object.put(key, val);
    }

    fn evaluateMacroExpr(self: *Self, alloc_: *std.mem.Allocator, expr_: ZombMacroExpr) !ZombValue {
        const macro = self.macro_map.get(expr_.key) orelse return error.KeyNotFound;
        var value = try macro.value.toZombValue(alloc_,
            if (macro.params) |p| p.keys() else null,
            if (expr_.args) |a| a.items else null,
            self.macro_map,
            if (expr_.accessors) |acc| acc.items else null);
        // if (expr_.accessors) |accessors| {
        //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
        //     value = try value.access(accessors.items);
        // }
        return value;
    }

    // TODO: This is for prototyping only -- remove before release
    pub fn log(self: Self) !void {
        if (self.token == null) {
            return;
        }
        self.state_machine.log();
        std.debug.print(
            \\----[Token]----
            \\Token = {} | {s} | {}
        , .{
            if (self.token) |t| t.token_type else .None,
            if (self.token) |t| try t.slice(self.input) else "",
            if (self.token) |t| t.line else 0,
        });
        std.debug.print(
            \\----[Parse Stack]----
            , .{}
        );
        // for (self.stack.items) |stack_elem| {
        //     switch (stack_elem) {
        //         .List => |list| {
        //             for (list) |item| {
        //                 switch (item) {
        //                     .MVal => |m| switch (m) {
        //                         .Object => |obj| {
        //                             // TODO: iterate the object entries and print them out
        //                         },
        //                         .Array => |arr| {
        //                             // TODO: iterate the array items and print them out
        //                         },
        //                         .String => |str|
        //                     },
        //                 }
        //             }
        //         }
        //     }
        // }
        std.debug.print("\n\n", .{});
    }
};

//==============================================================================
//
//
//
// Testing
//==============================================================================

const testing = std.testing;

const StringReader = @import("string_reader.zig").StringReader;
const StringParser = Parser(StringReader, 32);

fn parseTestInput(input_: []const u8) !Zomb {
    var parser = Parser.init(input_, testing.allocator);
    defer parser.deinit();

    return try parser.parse(testing.allocator);
}

fn doZombValueStringTest(expected_: []const u8, actual_: ZombValue) !void {
    switch (actual_) {
        .String => |str| try testing.expectEqualStrings(expected_, str.items),
        else => return error.UnexpectedValue,
    }
}

test "bare string value" {
    const input = "key = value";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty quoted string value" {
    const input = "key = \"\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("", entry.value_ptr.*);
}

test "quoted string value" {
    const input = "key = \"value\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty raw string value" {
    const input = "key = \\\\";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("", entry.value_ptr.*);
}

test "one line raw string value" {
    const input = "key = \\\\value";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "two line raw string value" {
    const input =
        \\key = \\one
        \\      \\two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one\ntwo", entry.value_ptr.*);
}

test "raw string value with empty newline in the middle" {
    const input =
        \\key = \\one
        \\      \\
        \\      \\two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one\n\ntwo", entry.value_ptr.*);
}

test "bare string concatenation" {
    const input = "key = one + two + three";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("onetwothree", entry.value_ptr.*);
}

test "quoted string concatenation" {
    const input =
        \\key = "one " + "two " + "three"
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one two three", entry.value_ptr.*);
}

test "raw string concatenation" {
    const input =
        \\key = \\part one
        \\      \\
        \\    + \\part two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("part one\npart two", entry.value_ptr.*);
}

test "general string concatenation" {
    const input =
        \\key = bare_string + "quoted string" + \\raw
        \\                                      \\string
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("bare_stringquoted stringraw\nstring", entry.value_ptr.*);
}

test "quoted key" {
    const input =
        \\"quoted key" = value
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("quoted key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty object value" {
    const input = "key = {}";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            try testing.expectEqual(@as(usize, 0), obj.count());
        },
        else => return error.UnexpectedValue,
    }
}

test "basic object value" {
    const input =
        \\key = {
        \\    a = hello
        \\    b = goodbye
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello", entry_a.value_ptr.*);

            const entry_b = obj.getEntry("b") orelse return error.KeyNotFound;
            try doZombValueStringTest("goodbye", entry_b.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

test "nested object value" {
    const input =
        \\key = {
        \\    a = {
        \\        b = value
        \\    }
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj_a| {
            const entry_a = obj_a.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Object => |obj_b| {
                    const entry_b = obj_b.getEntry("b") orelse return error.KeyNotFound;
                    try doZombValueStringTest("value", entry_b.value_ptr.*);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: object + object concatenation

test "empty array value" {
    const input = "key = []";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 0), arr.items.len);
        },
        else => return error.UnexpectedValue,
    }
}

test "basic array value" {
    const input = "key = [ a b c ]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try doZombValueStringTest("a", arr.items[0]);
            try doZombValueStringTest("b", arr.items[1]);
            try doZombValueStringTest("c", arr.items[2]);
        },
        else => return error.UnexpectedValue,
    }
}

test "nested array value" {
    const input =
        \\key = [
        \\    [ a b c ]
        \\]
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Array => |arr_inner| {
                    try testing.expectEqual(@as(usize, 3), arr_inner.items.len);
                    try doZombValueStringTest("a", arr_inner.items[0]);
                    try doZombValueStringTest("b", arr_inner.items[1]);
                    try doZombValueStringTest("c", arr_inner.items[2]);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: array + array concatenation

test "array in an object" {
    const input =
        \\key = {
        \\    a = [ 1 2 3 ]
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Array => |arr| {
                    try testing.expectEqual(@as(usize, 3), arr.items.len);
                    try doZombValueStringTest("1", arr.items[0]);
                    try doZombValueStringTest("2", arr.items[1]);
                    try doZombValueStringTest("3", arr.items[2]);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "object in an array" {
    const input = "key = [ { a = b c = d } ]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Object => |obj| {
                    const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
                    try doZombValueStringTest("b", entry_a.value_ptr.*);
                    const entry_c = obj.getEntry("c") orelse return error.KeyNotFound;
                    try doZombValueStringTest("d", entry_c.value_ptr.*);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "empty array in object" {
    const input = "key = { a = [] }";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Array => |arr| try testing.expectEqual(@as(usize, 0), arr.items.len),
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "empty object in array" {
    const input = "key = [{}]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Object => |obj| {
                    try testing.expectEqual(@as(usize, 0), obj.count());
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: empty Zomb.map

test "macro - bare string value" {
    const input =
        \\$key = hello
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - object value" {
    const input =
        \\$key = {
        \\    a = hello
        \\}
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello", entry_a.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

test "macro - array value" {
    const input =
        \\$key = [ a b c ]
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try doZombValueStringTest("a", arr.items[0]);
            try doZombValueStringTest("b", arr.items[1]);
            try doZombValueStringTest("c", arr.items[2]);
        },
        else => return error.UnexpectedValue,
    }
}

test "macro - one level object accessor" {
    const input =
        \\$key = {
        \\    a = hello
        \\}
        \\hi = $key.a
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - one level array accessor" {
    const input =
        \\$key = [ hello goodbye okay ]
        \\hi = $key.1
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("goodbye", entry.value_ptr.*);
}

test "macro - object in object accessor" {
    const input =
        \\$key = {
        \\    a = {
        \\        b = hello } }
        \\hi = $key.a.b
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - array in array accessor" {
    const input =
        \\$key = [ a [ b ] ]
        \\hi = $key.1.0
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("b", entry.value_ptr.*);
}

test "macro - macro expression in macro declaration" {
    const input =
        \\$color(alpha, omega) = {
        \\    black = #000000 + %alpha
        \\    red = #ff0000 + %alpha + %omega
        \\}
        \\$colorize(scope, alpha) = {
        \\    scope = %scope
        \\    color = $color(%alpha, $color(X, X).red).black
        \\}
        \\key = $colorize("hello world", 0F)
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const scope_entry = obj.getEntry("scope") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello world", scope_entry.value_ptr.*);

            const color_entry = obj.getEntry("color") orelse return error.KeyNotFound;
            try doZombValueStringTest("#0000000F", color_entry.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

// test "macro batching" {
//     const input =
//         \\$color = {
//         \\    black = #000000
//         \\    red = #ff0000
//         \\}
//         \\$colorize(scope, color, alpha) = {
//         \\    scope = %scope
//         \\    settings = { foreground = %color + %alpha }
//         \\}
//         \\
//         \\tokenColors =
//         \\    $colorize(?, $color.black, ?) % [
//         \\        [ "editor.background" 55 ]
//         \\        [ "editor.border"     66 ]
//         \\    ] +
//         \\    $colorize(?, $color.red, ?) % [
//         \\        [ "editor.foreground"      7f ]
//         \\        [ "editor.highlightBorder" ff ]
//         \\    ]
//     ;
//     const z = try parseTestInput(input);
//     defer z.deinit();
// }
